import Foundation
import TokiDurableStorage
import TokiSyncProtocol
import TokiUsageCore

protocol RemoteSnapshotCaching {
    func load() throws -> RemoteSnapshotCacheEntry?
    func save(_ entry: RemoteSnapshotCacheEntry, changedDeviceIDs: Set<String>) throws
    func remove(deviceID: String) throws
    func clear() throws
}

extension RemoteSnapshotCaching {
    func save(_ entry: RemoteSnapshotCacheEntry) throws {
        try save(entry, changedDeviceIDs: Set(entry.envelopes.map(\.deviceID)))
    }
}

struct RemoteSnapshotCacheEntry: Codable, Equatable {
    let envelopes: [EncryptedUsageEnvelope]
    let manifest: [RemoteDeviceSummary]
    let manifestEntityTag: String?
    let fetchedAt: Date
    let snapshotCacheIdentifier: String?

    init(
        envelopes: [EncryptedUsageEnvelope],
        manifest: [RemoteDeviceSummary],
        manifestEntityTag: String? = nil,
        fetchedAt: Date = Date(),
        snapshotCacheIdentifier: String? = nil) {
        self.envelopes = envelopes
        self.manifest = manifest
        self.manifestEntityTag = manifestEntityTag
        self.fetchedAt = fetchedAt
        self.snapshotCacheIdentifier = snapshotCacheIdentifier
    }
}

final class RemoteSnapshotCache: RemoteSnapshotCaching {
    private static let maximumLegacyCacheBytes = TokiSyncLimits.maximumSnapshotResponseBytes +
        TokiSyncLimits.maximumManagementResponseBytes + 1024 * 1024
    private static let maximumMetadataBytes = TokiSyncLimits.maximumManagementResponseBytes + 1024 * 1024
    private static let maximumEnvelopeDocumentBytes = TokiSyncLimits.maximumSingleSnapshotResponseBytes
    private static let lock = NSLock()

    let url: URL
    let envelopeDirectoryURL: URL

    init(url: URL = RemoteSnapshotCache.defaultURL()) {
        self.url = url
        envelopeDirectoryURL = url.deletingPathExtension().appendingPathExtension("d")
    }

    func load() throws -> RemoteSnapshotCacheEntry? {
        Self.lock.lock()
        defer { Self.lock.unlock() }
        try removeStaleTemporaryFiles()
        return try loadEntry()
    }

    func save(_ entry: RemoteSnapshotCacheEntry, changedDeviceIDs: Set<String>) throws {
        Self.lock.lock()
        defer { Self.lock.unlock() }
        try removeStaleTemporaryFiles()
        let validated = try RemoteSnapshotCacheValidation.validated(entry)
        try write(validated, changedDeviceIDs: changedDeviceIDs)
    }

    func remove(deviceID: String) throws {
        guard TokiSyncValidation.isSafeDeviceID(deviceID) else {
            throw RemoteSnapshotCacheError.invalidCache
        }
        Self.lock.lock()
        defer { Self.lock.unlock() }
        try removeStaleTemporaryFiles()

        guard let entry = try loadEntry() else {
            try removeEnvelopeFiles(deviceID: deviceID)
            return
        }
        let remainingEnvelopes = entry.envelopes.filter { $0.deviceID != deviceID }
        let remainingManifest = entry.manifest.filter { $0.id != deviceID }
        if remainingEnvelopes.isEmpty, remainingManifest.isEmpty {
            try removeFileIfPresent()
        } else {
            let updated = RemoteSnapshotCacheEntry(
                envelopes: remainingEnvelopes,
                manifest: remainingManifest,
                manifestEntityTag: nil,
                fetchedAt: entry.fetchedAt,
                snapshotCacheIdentifier: entry.snapshotCacheIdentifier)
            try write(updated, changedDeviceIDs: [deviceID])
        }
    }

    func clear() throws {
        Self.lock.lock()
        defer { Self.lock.unlock() }
        try removeStaleTemporaryFiles()
        try removeFileIfPresent()
    }
}

private extension RemoteSnapshotCache {
    private func loadEntry() throws -> RemoteSnapshotCacheEntry? {
        guard pathExistsIncludingSymbolicLink(url) else { return nil }
        let values = try url.resourceValues(forKeys: [.contentModificationDateKey])
        let data = try boundedData(at: url, maximumBytes: Self.maximumLegacyCacheBytes)

        do {
            let metadata = try TokiSyncCoding.makeDecoder().decode(RemoteSnapshotMetadataDocument.self, from: data)
            return try loadSplitEntry(metadata)
        } catch {
            do {
                let legacy = try TokiSyncCoding.makeDecoder()
                    .decode(LegacyCombinedCacheDocument.self, from: data)
                return try RemoteSnapshotCacheValidation.validated(legacy.entry)
            } catch let cacheError as RemoteSnapshotCacheError {
                throw cacheError
            } catch let readerError as RemoteUsageReaderError {
                throw readerError
            } catch {
                do {
                    let legacy = try TokiSyncCoding.makeDecoder()
                        .decode(LegacyRemoteSnapshotCacheDocument.self, from: data)
                    let envelopes = try RemoteSnapshotProgress.validated(legacy.snapshots)
                    let manifest = envelopes.map { envelope in
                        RemoteDeviceSummary(
                            id: envelope.deviceID,
                            name: envelope.deviceID,
                            createdAt: envelope.generatedAt,
                            lastSeenAt: envelope.generatedAt,
                            latestSequence: envelope.sequence)
                    }
                    let entry = RemoteSnapshotCacheEntry(
                        envelopes: envelopes,
                        manifest: manifest,
                        fetchedAt: values.contentModificationDate ?? Date.distantPast)
                    return try RemoteSnapshotCacheValidation.validated(entry)
                } catch let cacheError as RemoteSnapshotCacheError {
                    throw cacheError
                } catch let readerError as RemoteUsageReaderError {
                    throw readerError
                } catch {
                    throw RemoteSnapshotCacheError.invalidCache
                }
            }
        }
    }

    private func loadSplitEntry(_ metadata: RemoteSnapshotMetadataDocument) throws -> RemoteSnapshotCacheEntry {
        let manifest = try RemoteSnapshotManifestValidation.validated(metadata.manifest)
        var envelopes: [EncryptedUsageEnvelope] = []
        var payloadBudget = RemoteSnapshotPayloadBudget(
            maximumBytes: TokiSyncLimits.maximumStoredSnapshotBytes)
        for device in manifest {
            guard let sequence = device.latestSequence else { continue }
            let envelopeURL = envelopeURL(deviceID: device.id, sequence: sequence)
            let data = try boundedData(at: envelopeURL, maximumBytes: Self.maximumEnvelopeDocumentBytes)
            let document = try TokiSyncCoding.makeDecoder().decode(RemoteSnapshotEnvelopeDocument.self, from: data)
            guard document.envelope.deviceID == device.id,
                  document.envelope.sequence == sequence else {
                throw RemoteSnapshotCacheError.invalidCache
            }
            try payloadBudget.consume(document.envelope)
            envelopes.append(document.envelope)
        }
        return try RemoteSnapshotCacheValidation.validated(RemoteSnapshotCacheEntry(
            envelopes: envelopes,
            manifest: manifest,
            manifestEntityTag: metadata.manifestEntityTag,
            fetchedAt: metadata.fetchedAt,
            snapshotCacheIdentifier: metadata.snapshotCacheIdentifier))
    }

    private func write(_ entry: RemoteSnapshotCacheEntry, changedDeviceIDs: Set<String>) throws {
        guard changedDeviceIDs.allSatisfy(TokiSyncValidation.isSafeDeviceID) else {
            throw RemoteSnapshotCacheError.invalidCache
        }
        try DurableFileIO.preparePrivateDirectory(url.deletingLastPathComponent())
        // This directory belongs exclusively to the split cache. Validate it
        // before committing any replacement so an unknown or special file
        // fails closed without partially updating otherwise valid metadata.
        _ = try validatedEnvelopeFiles()
        let envelopesByDevice = Dictionary(uniqueKeysWithValues: entry.envelopes.map { ($0.deviceID, $0) })
        for envelope in entry.envelopes {
            let envelopeURL = envelopeURL(deviceID: envelope.deviceID, sequence: envelope.sequence)
            let envelopeExists = pathExistsIncludingSymbolicLink(envelopeURL)
            if envelopeExists {
                let values = try envelopeURL.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
                guard values.isRegularFile == true,
                      values.isSymbolicLink != true else {
                    throw RemoteSnapshotCacheError.invalidCache
                }
            }
            if changedDeviceIDs.contains(envelope.deviceID) || !envelopeExists {
                let document = RemoteSnapshotEnvelopeDocument(envelope: envelope)
                let data = try TokiSyncCoding.makeEncoder().encode(document)
                guard data.count <= Self.maximumEnvelopeDocumentBytes else {
                    throw RemoteHubClientError.responseTooLarge
                }
                try DurableFileIO.writePrivate(data, to: envelopeURL)
            }
        }

        let metadata = RemoteSnapshotMetadataDocument(entry: entry)
        let metadataData = try TokiSyncCoding.makeEncoder().encode(metadata)
        guard metadataData.count <= Self.maximumMetadataBytes else {
            throw RemoteHubClientError.responseTooLarge
        }
        try DurableFileIO.writePrivate(metadataData, to: url)
        try removeObsoleteEnvelopeFiles(keeping: Set(envelopesByDevice.values.map {
            envelopeURL(deviceID: $0.deviceID, sequence: $0.sequence).lastPathComponent
        }))
    }
}

private extension RemoteSnapshotCache {
    private func removeEnvelopeFiles(deviceID: String) throws {
        let urls = try validatedEnvelopeFiles()
        let expectedPrefix = "\(deviceID)."
        let matchingURLs = urls.filter { $0.lastPathComponent.hasPrefix(expectedPrefix) }
        for fileURL in matchingURLs {
            try DurableFileIO.removeIfPresent(fileURL)
        }
        if matchingURLs.count == urls.count {
            try DurableFileIO.removeEmptyDirectoryIfPresent(envelopeDirectoryURL)
        }
    }

    private func removeObsoleteEnvelopeFiles(keeping expectedNames: Set<String>) throws {
        let urls = try validatedEnvelopeFiles()
        for fileURL in urls {
            guard !expectedNames.contains(fileURL.lastPathComponent) else { continue }
            try DurableFileIO.removeIfPresent(fileURL)
        }
        if expectedNames.isEmpty {
            try DurableFileIO.removeEmptyDirectoryIfPresent(envelopeDirectoryURL)
        }
    }

    private func validatedEnvelopeFiles() throws -> [URL] {
        guard pathExistsIncludingSymbolicLink(envelopeDirectoryURL) else { return [] }
        let directoryValues = try envelopeDirectoryURL.resourceValues(
            forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard directoryValues.isDirectory == true,
              directoryValues.isSymbolicLink != true else {
            throw RemoteSnapshotCacheError.invalidCache
        }
        let urls = try FileManager.default.contentsOfDirectory(
            at: envelopeDirectoryURL,
            includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey])
        for fileURL in urls {
            guard isEnvelopeFilename(fileURL.lastPathComponent) else {
                throw RemoteSnapshotCacheError.invalidCache
            }
            let values = try fileURL.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            guard values.isRegularFile == true,
                  values.isSymbolicLink != true else {
                throw RemoteSnapshotCacheError.invalidCache
            }
        }
        return urls
    }

    private func boundedData(at fileURL: URL, maximumBytes: Int) throws -> Data {
        let values = try fileURL.resourceValues(
            forKeys: [.fileSizeKey, .isRegularFileKey, .isSymbolicLinkKey])
        guard values.isRegularFile == true,
              values.isSymbolicLink != true,
              let fileSize = values.fileSize,
              fileSize > 0,
              fileSize <= maximumBytes else {
            throw RemoteHubClientError.responseTooLarge
        }
        let data = try Data(contentsOf: fileURL)
        guard !data.isEmpty, data.count <= maximumBytes else {
            throw RemoteHubClientError.responseTooLarge
        }
        return data
    }

    private func envelopeURL(deviceID: String, sequence: UInt64) -> URL {
        envelopeDirectoryURL.appendingPathComponent("\(deviceID).\(sequence).json")
    }

    private func removeFileIfPresent() throws {
        try DurableFileIO.removeIfPresent(url)
        try removeObsoleteEnvelopeFiles(keeping: [])
    }

    private func removeStaleTemporaryFiles() throws {
        let metadataDirectory = url.deletingLastPathComponent()
        if pathExistsIncludingSymbolicLink(metadataDirectory) {
            let values = try metadataDirectory.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            guard values.isDirectory == true,
                  values.isSymbolicLink != true else {
                throw RemoteSnapshotCacheError.invalidCache
            }
            try removeStaleTemporaryFiles(in: metadataDirectory) { destinationName in
                destinationName == url.lastPathComponent
            }
        }
        guard pathExistsIncludingSymbolicLink(envelopeDirectoryURL) else { return }
        let values = try envelopeDirectoryURL.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard values.isDirectory == true,
              values.isSymbolicLink != true else {
            throw RemoteSnapshotCacheError.invalidCache
        }
        try removeStaleTemporaryFiles(in: envelopeDirectoryURL, destinationNameIsAllowed: isEnvelopeFilename)
    }

    private func removeStaleTemporaryFiles(
        in directory: URL,
        destinationNameIsAllowed: (String) -> Bool) throws {
        let urls = try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey])
        for fileURL in urls {
            guard let destinationName = durableTemporaryDestinationName(fileURL.lastPathComponent),
                  destinationNameIsAllowed(destinationName) else {
                continue
            }
            let values = try fileURL.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            guard values.isRegularFile == true,
                  values.isSymbolicLink != true else {
                throw RemoteSnapshotCacheError.invalidCache
            }
            try DurableFileIO.removeIfPresent(fileURL)
        }
    }

    private func isEnvelopeFilename(_ name: String) -> Bool {
        let components = name.split(separator: ".", omittingEmptySubsequences: false)
        guard components.count == 3,
              components[2] == "json",
              TokiSyncValidation.isSafeDeviceID(String(components[0])),
              let sequence = UInt64(components[1]),
              sequence > 0,
              String(sequence) == String(components[1]) else {
            return false
        }
        return true
    }

    private func pathExistsIncludingSymbolicLink(_ fileURL: URL) -> Bool {
        FileManager.default.fileExists(atPath: fileURL.path)
            || (try? FileManager.default.destinationOfSymbolicLink(atPath: fileURL.path)) != nil
    }
}

extension RemoteSnapshotCache {
    static func defaultURL() -> URL {
        homeDir()
            .appendingPathComponent("Library/Application Support/Toki")
            .appendingPathComponent("remote-snapshots.json")
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

private struct RemoteSnapshotMetadataDocument: Codable {
    private static let currentVersion = 3

    let cacheVersion: Int
    let manifest: [RemoteDeviceSummary]
    let manifestEntityTag: String?
    let fetchedAt: Date
    let snapshotCacheIdentifier: String?

    init(entry: RemoteSnapshotCacheEntry) {
        cacheVersion = Self.currentVersion
        manifest = entry.manifest
        manifestEntityTag = entry.manifestEntityTag
        fetchedAt = entry.fetchedAt
        snapshotCacheIdentifier = entry.snapshotCacheIdentifier
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        cacheVersion = try container.decode(Int.self, forKey: .cacheVersion)
        guard cacheVersion == Self.currentVersion else {
            throw RemoteSnapshotCacheError.invalidCache
        }
        manifest = try container.decode([RemoteDeviceSummary].self, forKey: .manifest)
        manifestEntityTag = try container.decodeIfPresent(String.self, forKey: .manifestEntityTag)
        fetchedAt = try container.decode(Date.self, forKey: .fetchedAt)
        snapshotCacheIdentifier = try container.decodeIfPresent(String.self, forKey: .snapshotCacheIdentifier)
    }
}

private struct RemoteSnapshotEnvelopeDocument: Codable {
    private static let currentVersion = 1

    let envelopeVersion: Int
    let envelope: EncryptedUsageEnvelope

    init(envelope: EncryptedUsageEnvelope) {
        envelopeVersion = Self.currentVersion
        self.envelope = envelope
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        envelopeVersion = try container.decode(Int.self, forKey: .envelopeVersion)
        guard envelopeVersion == Self.currentVersion else {
            throw RemoteSnapshotCacheError.invalidCache
        }
        envelope = try container.decode(EncryptedUsageEnvelope.self, forKey: .envelope)
    }
}

private struct LegacyCombinedCacheDocument: Codable {
    private static let supportedVersion = 2

    let cacheVersion: Int
    let entry: RemoteSnapshotCacheEntry

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        cacheVersion = try container.decode(Int.self, forKey: .cacheVersion)
        guard cacheVersion == Self.supportedVersion else {
            throw RemoteSnapshotCacheError.invalidCache
        }
        entry = try container.decode(RemoteSnapshotCacheEntry.self, forKey: .entry)
    }
}

private struct LegacyRemoteSnapshotCacheDocument: Codable {
    let snapshots: [EncryptedUsageEnvelope]
}

enum RemoteSnapshotCacheError: LocalizedError {
    case invalidCache

    var errorDescription: String? {
        "The encrypted remote snapshot cache is invalid."
    }
}
