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
        var manifestSequences: [String: UInt64] = [:]
        for device in manifest {
            guard let sequence = device.latestSequence else { continue }
            guard manifestSequences.updateValue(sequence, forKey: device.id) == nil else {
                throw RemoteSnapshotCacheError.invalidCache
            }
        }
        guard envelopeSequences == manifestSequences else {
            throw RemoteSnapshotCacheError.invalidCache
        }
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
