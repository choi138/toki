import Foundation
import TokiDurableStorage
import TokiSyncProtocol

struct AgentRuntimeState: Codable, Equatable {
    var latestSequence: UInt64 = 0
    var lastSuccessfulSyncAt: Date?
    var lastAttemptAt: Date?
    var lastError: String?
    var lastUploadedContentDigest: String?
    var lastSourceSignature: String?
}

struct AgentStateStore {
    let paths: AgentPaths

    func load() throws -> AgentRuntimeState {
        guard paths.pathExistsIncludingSymbolicLink(paths.runtimeStateURL) else {
            return AgentRuntimeState()
        }
        let values = try paths.runtimeStateURL.resourceValues(
            forKeys: [.fileSizeKey, .isRegularFileKey, .isSymbolicLinkKey])
        guard values.isRegularFile == true,
              values.isSymbolicLink != true,
              let fileSize = values.fileSize,
              fileSize <= TokiSyncLimits.maximumConfigurationFileBytes else {
            throw AgentStateStoreError.invalidState
        }
        do {
            let data = try Data(contentsOf: paths.runtimeStateURL)
            guard data.count <= TokiSyncLimits.maximumConfigurationFileBytes else {
                throw AgentStateStoreError.invalidState
            }
            let state = try TokiSyncCoding.makeDecoder().decode(AgentRuntimeState.self, from: data)
            try Self.validate(state)
            return state
        } catch {
            throw AgentStateStoreError.invalidState
        }
    }

    func save(_ state: AgentRuntimeState) throws {
        try Self.validate(state)
        try paths.prepare()
        let data = try TokiSyncCoding.makeEncoder().encode(state)
        try paths.writePrivate(data, to: paths.runtimeStateURL)
    }

    func reset() throws {
        try DurableFileIO.removeIfPresent(paths.runtimeStateURL)
    }

    private static func validate(_ state: AgentRuntimeState) throws {
        let dates = [state.lastSuccessfulSyncAt, state.lastAttemptAt].compactMap { $0 }
        guard dates.allSatisfy(\.timeIntervalSince1970.isFinite),
              state.lastError.map({ $0.utf8.count <= 300 }) ?? true,
              state.lastUploadedContentDigest.map(SnapshotCipher.isSHA256Digest) ?? true,
              state.lastSourceSignature.map(SnapshotCipher.isSHA256Digest) ?? true,
              state.lastSourceSignature == nil || state.lastUploadedContentDigest != nil,
              state.lastUploadedContentDigest == nil || state.latestSequence > 0 else {
            throw AgentStateStoreError.invalidState
        }
    }
}

struct AgentSpool {
    static let maximumPendingEnvelopes = 4

    let paths: AgentPaths

    func pendingEnvelopes() throws -> [(url: URL, envelope: EncryptedUsageEnvelope)] {
        let urls = try pendingEnvelopeURLs()
        guard urls.count <= Self.maximumPendingEnvelopes else {
            throw AgentSpoolError.tooManyPendingEnvelopes
        }

        return try urls.map { url in
            let values = try url.resourceValues(
                forKeys: [.fileSizeKey, .isRegularFileKey, .isSymbolicLinkKey])
            guard values.isRegularFile == true,
                  values.isSymbolicLink != true,
                  let fileSize = values.fileSize,
                  fileSize <= TokiSyncLimits.maximumEnvelopeBytes else {
                throw AgentSpoolError.envelopeTooLarge(fileSize: values.fileSize)
            }
            let data = try Data(contentsOf: url)
            guard data.count <= TokiSyncLimits.maximumEnvelopeBytes else {
                throw AgentSpoolError.envelopeTooLarge(fileSize: data.count)
            }
            let envelope = try TokiSyncCoding.makeDecoder().decode(EncryptedUsageEnvelope.self, from: data)
            guard envelope.schemaVersion == TokiSyncProtocolVersion.current,
                  envelope.sequence > 0,
                  !envelope.payload.isEmpty,
                  envelope.payload.utf8.count <= TokiSyncLimits.maximumEnvelopeBytes,
                  Data(base64Encoded: envelope.payload) != nil,
                  envelope.generatedAt.timeIntervalSince1970.isFinite,
                  TokiSyncValidation.isSafeDeviceID(envelope.deviceID),
                  url.lastPathComponent == String(format: "%020llu.json", envelope.sequence) else {
                throw AgentSpoolError.invalidEnvelope
            }
            return (url, envelope)
        }
    }

    func enqueue(_ envelope: EncryptedUsageEnvelope) throws -> URL {
        let data = try TokiSyncCoding.makeEncoder().encode(envelope)
        guard data.count <= TokiSyncLimits.maximumEnvelopeBytes else {
            throw AgentSpoolError.envelopeTooLarge(fileSize: data.count)
        }
        let name = String(format: "%020llu.json", envelope.sequence)
        let url = paths.spoolDirectory.appendingPathComponent(name)
        let pendingURLs = try pendingEnvelopeURLs()
        let replacesExistingEnvelope = pendingURLs.contains {
            $0.standardizedFileURL == url.standardizedFileURL
        }
        guard replacesExistingEnvelope || pendingURLs.count < Self.maximumPendingEnvelopes else {
            throw AgentSpoolError.tooManyPendingEnvelopes
        }
        try paths.writePrivate(data, to: url)
        return url
    }

    func remove(
        _ url: URL,
        remover: (URL) throws -> Void = DurableFileIO.removeIfPresent) throws {
        guard url.deletingLastPathComponent().standardizedFileURL == paths.spoolDirectory.standardizedFileURL else {
            throw AgentSpoolError.invalidPath
        }
        do {
            try remover(url)
        } catch DurableFileIOError.removalCommittedDirectorySyncFailed {
            // A later enqueue synchronizes this directory before a newer sequence
            // can overtake the removed envelope; otherwise a retry is idempotent.
        }
    }

    func clear() throws {
        try paths.prepare()
        let urls = try FileManager.default.contentsOfDirectory(
            at: paths.spoolDirectory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles])
            .filter { $0.pathExtension == "json" }
        for url in urls {
            try remove(url)
        }
    }

    private func pendingEnvelopeURLs() throws -> [URL] {
        try paths.prepare()
        return try FileManager.default.contentsOfDirectory(
            at: paths.spoolDirectory,
            includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey, .isSymbolicLinkKey],
            options: [.skipsHiddenFiles])
            .filter { $0.pathExtension == "json" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }
}

enum AgentSpoolError: LocalizedError {
    case envelopeTooLarge(fileSize: Int?)
    case tooManyPendingEnvelopes
    case invalidEnvelope
    case invalidPath

    var errorDescription: String? {
        switch self {
        case let .envelopeTooLarge(fileSize):
            if let fileSize {
                "The encrypted snapshot is \(fileSize) bytes, exceeding the 8 MiB safety limit. Reduce retention."
            } else {
                "The encrypted snapshot exceeds the 8 MiB safety limit. Reduce retention."
            }
        case .tooManyPendingEnvelopes:
            "The Agent spool contains too many pending snapshots."
        case .invalidEnvelope:
            "The Agent spool contains an invalid encrypted snapshot."
        case .invalidPath:
            "Refused to remove a file outside the Toki Agent spool."
        }
    }
}

enum AgentStateStoreError: LocalizedError {
    case invalidState

    var errorDescription: String? {
        "The Agent state is invalid. Refusing to reset its upload sequence; re-pair the device to recover."
    }
}
