import Foundation
import TokiSyncProtocol

enum RemoteSnapshotCacheValidation {
    static func validated(_ entry: RemoteSnapshotCacheEntry, now: Date = Date()) throws -> RemoteSnapshotCacheEntry {
        let envelopes = try RemoteSnapshotProgress.validated(entry.envelopes)
        let manifest = try RemoteSnapshotManifestValidation.validated(entry.manifest, now: now)
        try validateConsistency(envelopes: envelopes, manifest: manifest)
        let payloadBytes = try envelopes.reduce(into: 0) { total, envelope in
            let count = envelope.payload.utf8.count
            guard total <= TokiSyncLimits.maximumStoredSnapshotBytes - count else {
                throw RemoteHubClientError.responseTooLarge
            }
            total += count
        }
        guard entry.fetchedAt.timeIntervalSince1970.isFinite,
              entry.fetchedAt >= Date(timeIntervalSince1970: 946_684_800),
              entry.fetchedAt <= now.addingTimeInterval(86400),
              payloadBytes <= TokiSyncLimits.maximumStoredSnapshotBytes,
              entry.manifestEntityTag.map(RemoteEntityTag.isValid) ?? true,
              entry.snapshotCacheIdentifier.map(SnapshotCipher.isSHA256Digest) ?? true else {
            throw RemoteSnapshotCacheError.invalidCache
        }
        return RemoteSnapshotCacheEntry(
            envelopes: envelopes,
            manifest: manifest,
            manifestEntityTag: entry.manifestEntityTag,
            fetchedAt: entry.fetchedAt,
            snapshotCacheIdentifier: entry.snapshotCacheIdentifier)
    }

    static func validateConsistency(
        envelopes: [EncryptedUsageEnvelope],
        manifest: [RemoteDeviceSummary]) throws {
        let envelopeSequences = Dictionary(uniqueKeysWithValues: envelopes.map { ($0.deviceID, $0.sequence) })
        let manifestSequences = Dictionary(uniqueKeysWithValues: manifest.compactMap { device in
            device.latestSequence.map { (device.id, $0) }
        })
        guard envelopeSequences == manifestSequences else {
            throw RemoteSnapshotCacheError.invalidCache
        }
    }
}

enum RemoteSnapshotManifestValidation {
    static func validated(
        _ devices: [RemoteDeviceSummary],
        now: Date = Date()) throws -> [RemoteDeviceSummary] {
        guard devices.count <= TokiSyncLimits.maximumDevices else {
            throw RemoteUsageReaderError.tooManyDevices
        }
        var deviceIDs = Set<String>()
        for device in devices {
            guard deviceIDs.insert(device.id).inserted,
                  TokiSyncValidation.isSafeDeviceID(device.id),
                  TokiSyncValidation.normalizedDeviceName(device.name) == device.name,
                  isSafeTimestamp(device.createdAt),
                  device.createdAt <= now.addingTimeInterval(86400),
                  device.lastSeenAt.map(isSafeTimestamp) != false,
                  device.lastSeenAt.map({ $0 <= now.addingTimeInterval(86400) }) != false,
                  device.latestSequence != 0,
                  (device.latestSequence == nil) == (device.lastSeenAt == nil),
                  (TokiSyncLimits.minimumSyncIntervalSeconds...TokiSyncLimits.maximumSyncIntervalSeconds)
                  .contains(device.syncIntervalSeconds) else {
                throw RemoteHubClientError.invalidPayload
            }
        }
        return devices.sorted { $0.id < $1.id }
    }

    private static func isSafeTimestamp(_ date: Date) -> Bool {
        let seconds = date.timeIntervalSince1970
        return seconds.isFinite && seconds >= 946_684_800 && seconds <= 32_503_680_000
    }
}

enum RemoteEntityTag {
    static func isValid(_ value: String) -> Bool {
        guard value.count == 66, value.first == "\"", value.last == "\"" else { return false }
        return SnapshotCipher.isSHA256Digest(String(value.dropFirst().dropLast()))
    }
}

enum RemoteSnapshotProgress {
    static func validated(_ envelopes: [EncryptedUsageEnvelope]) throws -> [EncryptedUsageEnvelope] {
        guard envelopes.count <= TokiSyncLimits.maximumDevices else {
            throw RemoteUsageReaderError.tooManyDevices
        }
        var deviceIDs = Set<String>()
        for envelope in envelopes {
            guard deviceIDs.insert(envelope.deviceID).inserted else {
                throw RemoteUsageReaderError.conflictingSnapshots
            }
            guard envelope.schemaVersion == TokiSyncProtocolVersion.current,
                  TokiSyncValidation.isSafeDeviceID(envelope.deviceID),
                  envelope.sequence > 0,
                  envelope.generatedAt.timeIntervalSince1970.isFinite,
                  !envelope.payload.isEmpty,
                  envelope.payload.utf8.count <= TokiSyncLimits.maximumEnvelopeBytes,
                  Data(base64Encoded: envelope.payload) != nil else {
                throw SnapshotCipherError.invalidEnvelope
            }
        }
        return envelopes.sorted { $0.deviceID < $1.deviceID }
    }

    static func anchors(
        for envelopes: [EncryptedUsageEnvelope]) throws -> [String: RemoteSnapshotAnchor] {
        try Dictionary(uniqueKeysWithValues: validated(envelopes).map { envelope in
            let encoded = try TokiSyncCoding.makeEncoder().encode(envelope)
            return (
                envelope.deviceID,
                RemoteSnapshotAnchor(
                    sequence: envelope.sequence,
                    envelopeDigest: SnapshotCipher.digest(encoded)))
        })
    }

    static func validate(
        candidateAnchors: [String: RemoteSnapshotAnchor],
        against previousAnchors: [String: RemoteSnapshotAnchor]) throws {
        for (deviceID, candidate) in candidateAnchors {
            guard let previous = previousAnchors[deviceID] else { continue }
            guard candidate.sequence >= previous.sequence else {
                throw RemoteUsageReaderError.staleSnapshot
            }
            if candidate.sequence == previous.sequence,
               candidate.envelopeDigest != previous.envelopeDigest {
                throw RemoteUsageReaderError.conflictingSnapshots
            }
        }
    }

    static func validateStoredAnchors(_ anchors: [String: RemoteSnapshotAnchor]) throws {
        for (deviceID, anchor) in anchors {
            guard TokiSyncValidation.isSafeDeviceID(deviceID),
                  anchor.sequence > 0,
                  SnapshotCipher.isSHA256Digest(anchor.envelopeDigest) else {
                throw RemoteSnapshotAnchorStoreError.invalidAnchorStore
            }
        }
    }
}
