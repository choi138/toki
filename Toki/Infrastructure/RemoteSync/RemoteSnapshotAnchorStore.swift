import Darwin
import Foundation
import TokiDurableStorage
import TokiSyncProtocol
import TokiUsageCore

protocol RemoteSnapshotAnchorStoring {
    func validateAndSave(
        _ envelopes: [EncryptedUsageEnvelope],
        originIdentifier: String) throws
    func copyAnchors(
        from sourceOriginIdentifier: String,
        to destinationOriginIdentifier: String) throws
    func remove(deviceID: String, originIdentifier: String) throws
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

    func validateAndSave(
        _ envelopes: [EncryptedUsageEnvelope],
        originIdentifier: String) throws {
        guard SnapshotCipher.isSHA256Digest(originIdentifier) else {
            throw RemoteSnapshotAnchorStoreError.invalidAnchorStore
        }
        try withExclusiveLock {
            var loadResult = try loadAnchorPartitions(migratingTo: originIdentifier)
            var anchors = loadResult.partitions[originIdentifier] ?? [:]
            let candidates = try RemoteSnapshotProgress.anchors(for: envelopes)
            try RemoteSnapshotProgress.validate(candidateAnchors: candidates, against: anchors)
            let previousPartitions = loadResult.partitions
            anchors.merge(candidates) { _, candidate in candidate }
            if !anchors.isEmpty {
                loadResult.partitions[originIdentifier] = anchors
            }
            try validate(loadResult.partitions)
            guard loadResult.requiresWrite || loadResult.partitions != previousPartitions else { return }
            try write(loadResult.partitions)
        }
    }

    func copyAnchors(
        from sourceOriginIdentifier: String,
        to destinationOriginIdentifier: String) throws {
        guard SnapshotCipher.isSHA256Digest(sourceOriginIdentifier),
              SnapshotCipher.isSHA256Digest(destinationOriginIdentifier) else {
            throw RemoteSnapshotAnchorStoreError.invalidAnchorStore
        }
        guard sourceOriginIdentifier != destinationOriginIdentifier else { return }

        try withExclusiveLock {
            var loadResult = try loadAnchorPartitions(migratingTo: sourceOriginIdentifier)
            let previousPartitions = loadResult.partitions
            let sourceAnchors = loadResult.partitions[sourceOriginIdentifier] ?? [:]
            var destinationAnchors = loadResult.partitions[destinationOriginIdentifier] ?? [:]

            for (deviceID, sourceAnchor) in sourceAnchors {
                guard let destinationAnchor = destinationAnchors[deviceID] else {
                    destinationAnchors[deviceID] = sourceAnchor
                    continue
                }
                if sourceAnchor.sequence > destinationAnchor.sequence {
                    destinationAnchors[deviceID] = sourceAnchor
                } else if sourceAnchor.sequence == destinationAnchor.sequence,
                          sourceAnchor.envelopeDigest != destinationAnchor.envelopeDigest {
                    throw RemoteUsageReaderError.conflictingSnapshots
                }
            }
            if !destinationAnchors.isEmpty {
                loadResult.partitions[destinationOriginIdentifier] = destinationAnchors
            }
            try validate(loadResult.partitions)
            guard loadResult.requiresWrite || loadResult.partitions != previousPartitions else { return }
            try write(loadResult.partitions)
        }
    }

    func remove(deviceID: String, originIdentifier: String) throws {
        guard TokiSyncValidation.isSafeDeviceID(deviceID),
              SnapshotCipher.isSHA256Digest(originIdentifier) else {
            throw RemoteSnapshotAnchorStoreError.invalidAnchorStore
        }
        try withExclusiveLock {
            var loadResult = try loadAnchorPartitions(migratingTo: originIdentifier)
            let previousPartitions = loadResult.partitions
            var anchors = loadResult.partitions[originIdentifier] ?? [:]
            anchors.removeValue(forKey: deviceID)
            loadResult.partitions[originIdentifier] = anchors.isEmpty ? nil : anchors
            if loadResult.partitions.isEmpty {
                try DurableFileIO.removeIfPresent(url)
            } else if loadResult.requiresWrite || loadResult.partitions != previousPartitions {
                try write(loadResult.partitions)
            }
        }
    }

    func clear() throws {
        try withExclusiveLock {
            try DurableFileIO.removeIfPresent(url)
        }
    }
}

private extension RemoteSnapshotAnchorStore {
    private func loadAnchorPartitions(
        migratingTo originIdentifier: String) throws -> (
        partitions: [String: [String: RemoteSnapshotAnchor]],
        requiresWrite: Bool) {
        if pathExistsIncludingSymbolicLink(url) {
            let data = try boundedData(at: url, maximumBytes: TokiSyncLimits.maximumRegistryBytes)
            if let document = try? TokiSyncCoding.makeDecoder().decode(
                RemoteSnapshotAnchorDocument.self,
                from: data) {
                try validate(document.anchorsByOrigin)
                return (document.anchorsByOrigin, false)
            }
            guard let legacy = try? TokiSyncCoding.makeDecoder().decode(LegacyAnchorDocument.self, from: data),
                  legacy.anchorVersion == nil || legacy.anchorVersion == 1,
                  let anchors = legacy.anchors else {
                throw RemoteSnapshotAnchorStoreError.invalidAnchorStore
            }
            try RemoteSnapshotProgress.validateStoredAnchors(anchors)
            let migrationOrigin = try cachedOriginIdentifier() ?? originIdentifier
            let partitions = anchors.isEmpty ? [:] : [migrationOrigin: anchors]
            try validate(partitions)
            return (partitions, true)
        }
        let partitions = try loadLegacyAnchorPartitions(migratingTo: originIdentifier)
        try validate(partitions)
        return (partitions, !partitions.isEmpty)
    }

    private func loadLegacyAnchorPartitions(
        migratingTo originIdentifier: String) throws -> [String: [String: RemoteSnapshotAnchor]] {
        guard pathExistsIncludingSymbolicLink(legacyCacheURL) else { return [:] }
        let data = try boundedData(
            at: legacyCacheURL,
            maximumBytes: TokiSyncLimits.maximumSnapshotResponseBytes)
        if let legacy = try? TokiSyncCoding.makeDecoder().decode(LegacyAnchorDocument.self, from: data),
           legacy.anchorVersion == nil || legacy.anchorVersion == 1,
           let anchors = legacy.anchors {
            try RemoteSnapshotProgress.validateStoredAnchors(anchors)
            return anchors.isEmpty ? [:] : [originIdentifier: anchors]
        }

        do {
            guard let legacyEntry = try RemoteSnapshotCache(url: legacyCacheURL).load() else {
                throw RemoteSnapshotAnchorStoreError.invalidAnchorStore
            }
            let anchors = try RemoteSnapshotProgress.anchors(for: legacyEntry.envelopes)
            let cacheIdentifier = legacyEntry.snapshotCacheIdentifier ?? originIdentifier
            guard SnapshotCipher.isSHA256Digest(cacheIdentifier) else {
                throw RemoteSnapshotAnchorStoreError.invalidAnchorStore
            }
            return anchors.isEmpty ? [:] : [cacheIdentifier: anchors]
        } catch let error as RemoteSnapshotAnchorStoreError {
            throw error
        } catch {
            throw RemoteSnapshotAnchorStoreError.invalidAnchorStore
        }
    }

    private func cachedOriginIdentifier() throws -> String? {
        guard pathExistsIncludingSymbolicLink(legacyCacheURL),
              let entry = try? RemoteSnapshotCache(url: legacyCacheURL).load(),
              let cacheIdentifier = entry.snapshotCacheIdentifier else {
            return nil
        }
        guard SnapshotCipher.isSHA256Digest(cacheIdentifier) else {
            throw RemoteSnapshotAnchorStoreError.invalidAnchorStore
        }
        return cacheIdentifier
    }

    private func validate(_ partitions: [String: [String: RemoteSnapshotAnchor]]) throws {
        guard partitions.count <= Self.maximumAnchorCount else {
            throw RemoteSnapshotAnchorStoreError.tooManyAnchors
        }
        var totalAnchorCount = 0
        for (originIdentifier, anchors) in partitions {
            guard SnapshotCipher.isSHA256Digest(originIdentifier) else {
                throw RemoteSnapshotAnchorStoreError.invalidAnchorStore
            }
            try RemoteSnapshotProgress.validateStoredAnchors(anchors)
            totalAnchorCount += anchors.count
            guard totalAnchorCount <= Self.maximumAnchorCount else {
                throw RemoteSnapshotAnchorStoreError.tooManyAnchors
            }
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

    private func write(_ partitions: [String: [String: RemoteSnapshotAnchor]]) throws {
        let data = try TokiSyncCoding.makeEncoder().encode(
            RemoteSnapshotAnchorDocument(anchorsByOrigin: partitions))
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
    private static let currentVersion = 2

    let anchorVersion: Int
    let anchorsByOrigin: [String: [String: RemoteSnapshotAnchor]]

    init(anchorsByOrigin: [String: [String: RemoteSnapshotAnchor]]) {
        anchorVersion = Self.currentVersion
        self.anchorsByOrigin = anchorsByOrigin
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        anchorVersion = try container.decode(Int.self, forKey: .anchorVersion)
        guard anchorVersion == Self.currentVersion else {
            throw RemoteSnapshotAnchorStoreError.invalidAnchorStore
        }
        anchorsByOrigin = try container.decode(
            [String: [String: RemoteSnapshotAnchor]].self,
            forKey: .anchorsByOrigin)
    }
}

private struct LegacyAnchorDocument: Codable {
    let anchorVersion: Int?
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
