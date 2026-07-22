import Darwin
import Foundation
import TokiDurableStorage
import TokiSyncProtocol
import TokiUsageCore

protocol RemoteSnapshotAnchorStoring {
    func validateAndSave(_ envelopes: [EncryptedUsageEnvelope]) throws
    func remove(deviceID: String) throws
    func clear() throws
}

final class RemoteSnapshotAnchorStore: RemoteSnapshotAnchorStoring {
    private static let maximumAnchorCount = 1024

    let url: URL
    private let lockURL: URL
    private let legacyCacheURL: URL

    init(
        url: URL = RemoteSnapshotAnchorStore.defaultURL(),
        legacyCacheURL: URL = RemoteSnapshotCache.defaultURL()) {
        self.url = url
        lockURL = url.appendingPathExtension("lock")
        self.legacyCacheURL = legacyCacheURL
    }

    func validateAndSave(_ envelopes: [EncryptedUsageEnvelope]) throws {
        try withExclusiveLock {
            var anchors = try loadAnchors()
            let candidates = try RemoteSnapshotProgress.anchors(for: envelopes)
            try RemoteSnapshotProgress.validate(candidateAnchors: candidates, against: anchors)
            let previousAnchors = anchors
            anchors.merge(candidates) { _, candidate in candidate }
            guard anchors.count <= Self.maximumAnchorCount else {
                throw RemoteSnapshotAnchorStoreError.tooManyAnchors
            }
            guard !anchors.isEmpty, anchors != previousAnchors else { return }
            try write(anchors)
        }
    }

    func remove(deviceID: String) throws {
        guard TokiSyncValidation.isSafeDeviceID(deviceID) else {
            throw RemoteSnapshotAnchorStoreError.invalidAnchorStore
        }
        try withExclusiveLock {
            var anchors = try loadAnchors()
            anchors.removeValue(forKey: deviceID)
            if anchors.isEmpty {
                try DurableFileIO.removeIfPresent(url)
            } else {
                try write(anchors)
            }
        }
    }

    func clear() throws {
        try withExclusiveLock {
            try DurableFileIO.removeIfPresent(url)
        }
    }

    private func loadAnchors() throws -> [String: RemoteSnapshotAnchor] {
        if pathExistsIncludingSymbolicLink(url) {
            let data = try boundedData(at: url, maximumBytes: TokiSyncLimits.maximumRegistryBytes)
            do {
                let document = try TokiSyncCoding.makeDecoder().decode(RemoteSnapshotAnchorDocument.self, from: data)
                try RemoteSnapshotProgress.validateStoredAnchors(document.anchors)
                guard document.anchors.count <= Self.maximumAnchorCount else {
                    throw RemoteSnapshotAnchorStoreError.tooManyAnchors
                }
                return document.anchors
            } catch let error as RemoteSnapshotAnchorStoreError {
                throw error
            } catch {
                throw RemoteSnapshotAnchorStoreError.invalidAnchorStore
            }
        }
        let legacyAnchors = try loadLegacyAnchors()
        if !legacyAnchors.isEmpty {
            try write(legacyAnchors)
        }
        return legacyAnchors
    }

    private func loadLegacyAnchors() throws -> [String: RemoteSnapshotAnchor] {
        guard pathExistsIncludingSymbolicLink(legacyCacheURL) else { return [:] }
        let data = try boundedData(
            at: legacyCacheURL,
            maximumBytes: TokiSyncLimits.maximumSnapshotResponseBytes)
        if let legacy = try? TokiSyncCoding.makeDecoder().decode(LegacyAnchorDocument.self, from: data),
           let anchors = legacy.anchors {
            try RemoteSnapshotProgress.validateStoredAnchors(anchors)
            guard anchors.count <= Self.maximumAnchorCount else {
                throw RemoteSnapshotAnchorStoreError.tooManyAnchors
            }
            return anchors
        }

        do {
            guard let legacyEntry = try RemoteSnapshotCache(url: legacyCacheURL).load() else {
                throw RemoteSnapshotAnchorStoreError.invalidAnchorStore
            }
            let anchors = try RemoteSnapshotProgress.anchors(for: legacyEntry.envelopes)
            guard anchors.count <= Self.maximumAnchorCount else {
                throw RemoteSnapshotAnchorStoreError.tooManyAnchors
            }
            return anchors
        } catch let error as RemoteSnapshotAnchorStoreError {
            throw error
        } catch {
            throw RemoteSnapshotAnchorStoreError.invalidAnchorStore
        }
    }

    private func boundedData(at fileURL: URL, maximumBytes: Int) throws -> Data {
        let values = try fileURL.resourceValues(
            forKeys: [.fileSizeKey, .isRegularFileKey, .isSymbolicLinkKey])
        guard values.isRegularFile == true,
              values.isSymbolicLink != true,
              let size = values.fileSize,
              size > 0,
              size <= maximumBytes else {
            throw RemoteSnapshotAnchorStoreError.invalidAnchorStore
        }
        let data = try Data(contentsOf: fileURL)
        guard !data.isEmpty,
              data.count <= maximumBytes else {
            throw RemoteSnapshotAnchorStoreError.invalidAnchorStore
        }
        return data
    }

    private func write(_ anchors: [String: RemoteSnapshotAnchor]) throws {
        let data = try TokiSyncCoding.makeEncoder().encode(RemoteSnapshotAnchorDocument(anchors: anchors))
        guard data.count <= TokiSyncLimits.maximumRegistryBytes else {
            throw RemoteSnapshotAnchorStoreError.tooManyAnchors
        }
        try DurableFileIO.writePrivate(data, to: url)
    }

    private func withExclusiveLock<Value>(_ operation: () throws -> Value) throws -> Value {
        let directory = lockURL.deletingLastPathComponent()
        try DurableFileIO.preparePrivateDirectory(directory)

        let descriptor = lockURL.path.withCString { path in
            Darwin.open(path, O_RDWR | O_CREAT | O_CLOEXEC | O_NOFOLLOW, mode_t(0o600))
        }
        guard descriptor >= 0 else {
            throw RemoteSnapshotAnchorStoreError.lockUnavailable
        }
        defer { _ = Darwin.close(descriptor) }
        var fileStatus = stat()
        guard Darwin.fstat(descriptor, &fileStatus) == 0,
              fileStatus.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG) else {
            throw RemoteSnapshotAnchorStoreError.lockUnavailable
        }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            throw RemoteSnapshotAnchorStoreError.lockUnavailable
        }
        defer { _ = flock(descriptor, LOCK_UN) }
        guard Darwin.fchmod(descriptor, mode_t(0o600)) == 0 else {
            throw RemoteSnapshotAnchorStoreError.lockUnavailable
        }
        try removeStaleTemporaryFile(in: directory)
        return try operation()
    }

    private func removeStaleTemporaryFile(in directory: URL) throws {
        let urls = try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey])
        for fileURL in urls {
            guard durableTemporaryDestinationName(fileURL.lastPathComponent) == url.lastPathComponent else {
                continue
            }
            let values = try fileURL.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            guard values.isRegularFile == true,
                  values.isSymbolicLink != true else {
                throw RemoteSnapshotAnchorStoreError.invalidAnchorStore
            }
            try DurableFileIO.removeIfPresent(fileURL)
        }
    }

    private func durableTemporaryDestinationName(_ temporaryName: String) -> String? {
        guard temporaryName.hasPrefix("."), temporaryName.hasSuffix(".tmp") else { return nil }
        let body = temporaryName.dropFirst().dropLast(4)
        guard let separator = body.lastIndex(of: ".") else { return nil }
        let destinationName = body[..<separator]
        let identifier = body[body.index(after: separator)...]
        guard !destinationName.isEmpty,
              UUID(uuidString: String(identifier)) != nil else {
            return nil
        }
        return String(destinationName)
    }

    private func pathExistsIncludingSymbolicLink(_ fileURL: URL) -> Bool {
        FileManager.default.fileExists(atPath: fileURL.path)
            || (try? FileManager.default.destinationOfSymbolicLink(atPath: fileURL.path)) != nil
    }

    static func defaultURL() -> URL {
        homeDir()
            .appendingPathComponent("Library/Application Support/Toki")
            .appendingPathComponent("remote-snapshot-anchors.json")
    }
}

private struct RemoteSnapshotAnchorDocument: Codable {
    private static let currentVersion = 1

    let anchorVersion: Int
    let anchors: [String: RemoteSnapshotAnchor]

    init(anchors: [String: RemoteSnapshotAnchor]) {
        anchorVersion = Self.currentVersion
        self.anchors = anchors
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        anchorVersion = try container.decode(Int.self, forKey: .anchorVersion)
        guard anchorVersion == Self.currentVersion else {
            throw RemoteSnapshotAnchorStoreError.invalidAnchorStore
        }
        anchors = try container.decode([String: RemoteSnapshotAnchor].self, forKey: .anchors)
    }
}

private struct LegacyAnchorDocument: Codable {
    let anchors: [String: RemoteSnapshotAnchor]?
}

enum RemoteSnapshotAnchorStoreError: LocalizedError {
    case invalidAnchorStore
    case tooManyAnchors
    case lockUnavailable

    var errorDescription: String? {
        switch self {
        case .invalidAnchorStore:
            "The remote snapshot replay-protection store is invalid. Refusing to accept remote data."
        case .tooManyAnchors:
            "The remote snapshot replay-protection store has too many device records."
        case .lockUnavailable:
            "The remote snapshot replay-protection store is busy or unavailable."
        }
    }
}
