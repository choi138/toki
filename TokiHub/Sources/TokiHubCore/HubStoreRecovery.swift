import Foundation
import TokiSyncProtocol

extension HubStore {
    static func validateRegistry(_ registry: HubRegistry) throws {
        guard registry.devices.count <= TokiSyncLimits.maximumDevices else {
            throw HubStoreError.corruptedStorage
        }
        let hexadecimal = CharacterSet(charactersIn: "0123456789abcdef")
        for (deviceID, device) in registry.devices {
            guard deviceID == device.id,
                  TokiSyncValidation.isSafeDeviceID(deviceID),
                  TokiSyncValidation.normalizedDeviceName(device.name) == device.name,
                  device.uploadTokenDigest.count == 64,
                  device.uploadTokenDigest.unicodeScalars.allSatisfy(hexadecimal.contains),
                  isSafeStoredTimestamp(device.createdAt),
                  device.lastSeenAt.map(isSafeStoredTimestamp) != false,
                  device.latestSequence != 0,
                  (device.latestSequence == nil) == (device.lastSeenAt == nil),
                  (TokiSyncLimits.minimumSyncIntervalSeconds...TokiSyncLimits.maximumSyncIntervalSeconds)
                  .contains(device.syncIntervalSeconds) else {
                throw HubStoreError.corruptedStorage
            }
        }
    }

    static func isSameEnvelope(
        _ lhs: EncryptedUsageEnvelope,
        _ rhs: EncryptedUsageEnvelope) -> Bool {
        guard let lhsMilliseconds = millisecondsSince1970(lhs.generatedAt),
              let rhsMilliseconds = millisecondsSince1970(rhs.generatedAt) else {
            return false
        }
        return lhs.schemaVersion == rhs.schemaVersion &&
            lhs.deviceID == rhs.deviceID &&
            lhs.sequence == rhs.sequence &&
            lhs.payload == rhs.payload &&
            lhsMilliseconds == rhsMilliseconds
    }

    static func recoverStorage(
        registry: HubRegistry,
        snapshotsDirectory: URL,
        now: Date = Date()) throws -> (registry: HubRegistry, changed: Bool) {
        var recoveredRegistry = registry
        var changed = false
        let activeDeviceIDs = Set(registry.devices.keys)
        try removeOrphanedSnapshots(
            activeDeviceIDs: activeDeviceIDs,
            snapshotsDirectory: snapshotsDirectory)

        for (deviceID, var device) in recoveredRegistry.devices {
            let url = snapshotsDirectory.appendingPathComponent("\(deviceID).json")
            guard pathExistsIncludingSymbolicLink(url) else {
                guard device.latestSequence == nil else {
                    throw HubStoreError.corruptedStorage
                }
                continue
            }
            guard let data = try snapshotDataIfPresent(at: url) else {
                throw HubStoreError.corruptedStorage
            }
            let envelope = try decodeStoredEnvelope(data, expectedDeviceID: deviceID)
            if let latestSequence = device.latestSequence {
                guard envelope.sequence >= latestSequence else {
                    throw HubStoreError.corruptedStorage
                }
                guard envelope.sequence > latestSequence else { continue }
            }

            device.latestSequence = envelope.sequence
            let modifiedAt = try url.resourceValues(forKeys: [.contentModificationDateKey])
                .contentModificationDate
            device.lastSeenAt = modifiedAt.map(isSafeStoredTimestamp) == true
                ? modifiedAt
                : envelope.generatedAt
            recoveredRegistry.devices[deviceID] = device
            changed = true
        }

        try validateRegistry(recoveredRegistry)
        guard isSafeStoredTimestamp(now) else {
            throw HubStoreError.corruptedStorage
        }
        return (recoveredRegistry, changed)
    }

    private static func removeOrphanedSnapshots(
        activeDeviceIDs: Set<String>,
        snapshotsDirectory: URL) throws {
        var hasUnconfirmedRemoval = false
        let urls = try FileManager.default.contentsOfDirectory(
            at: snapshotsDirectory,
            includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey],
            options: [.skipsHiddenFiles])
        for url in urls where url.pathExtension == "json" {
            let deviceID = url.deletingPathExtension().lastPathComponent
            let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            guard TokiSyncValidation.isSafeDeviceID(deviceID),
                  values.isRegularFile == true,
                  values.isSymbolicLink != true else {
                throw HubStoreError.corruptedStorage
            }
            guard !activeDeviceIDs.contains(deviceID) else { continue }
            do {
                let outcome = try removePrivateFileIfPresent(url)
                hasUnconfirmedRemoval = hasUnconfirmedRemoval || outcome == .committedButUnconfirmed
            } catch {
                throw HubStoreError.corruptedStorage
            }
        }
        if hasUnconfirmedRemoval {
            try confirmDirectory(snapshotsDirectory)
        }
    }

    static func requireNoSnapshotsWithoutRegistry(_ snapshotsDirectory: URL) throws {
        let urls = try FileManager.default.contentsOfDirectory(
            at: snapshotsDirectory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles])
        guard !urls.contains(where: { $0.pathExtension == "json" }) else {
            // A valid registry is the authority for deciding whether a
            // snapshot is orphaned. Without it, preserve the ciphertext and
            // require operator recovery instead of deleting data implicitly.
            throw HubStoreError.corruptedStorage
        }
    }

    static func decodeStoredEnvelope(
        _ data: Data,
        expectedDeviceID: String) throws -> EncryptedUsageEnvelope {
        do {
            let envelope = try TokiSyncCoding.makeDecoder().decode(EncryptedUsageEnvelope.self, from: data)
            guard envelope.schemaVersion == TokiSyncProtocolVersion.current,
                  envelope.deviceID == expectedDeviceID,
                  envelope.sequence > 0,
                  !envelope.payload.isEmpty,
                  envelope.payload.utf8.count <= TokiSyncLimits.maximumEnvelopeBytes,
                  Data(base64Encoded: envelope.payload) != nil,
                  isSafeStoredTimestamp(envelope.generatedAt) else {
                throw HubStoreError.corruptedStorage
            }
            return envelope
        } catch let error as HubStoreError {
            throw error
        } catch {
            throw HubStoreError.corruptedStorage
        }
    }

    static func snapshotDataIfPresent(at url: URL) throws -> Data? {
        guard pathExistsIncludingSymbolicLink(url) else { return nil }
        let values = try url.resourceValues(
            forKeys: [.fileSizeKey, .isRegularFileKey, .isSymbolicLinkKey])
        guard values.isRegularFile == true,
              values.isSymbolicLink != true,
              let fileSize = values.fileSize,
              fileSize > 0,
              fileSize <= TokiSyncLimits.maximumEnvelopeBytes else {
            throw HubStoreError.corruptedStorage
        }
        let data = try Data(contentsOf: url)
        guard !data.isEmpty,
              data.count <= TokiSyncLimits.maximumEnvelopeBytes else {
            throw HubStoreError.corruptedStorage
        }
        return data
    }

    static func isSafeStoredTimestamp(_ date: Date) -> Bool {
        guard millisecondsSince1970(date) != nil else { return false }
        let seconds = date.timeIntervalSince1970
        return seconds >= 946_684_800 && seconds <= 32_503_680_000
    }

    static func millisecondsSince1970(_ date: Date) -> Int64? {
        let milliseconds = date.timeIntervalSince1970 * 1000
        guard milliseconds.isFinite,
              milliseconds >= Double(Int64.min),
              milliseconds < Double(Int64.max) else {
            return nil
        }
        return Int64(milliseconds.rounded(.down))
    }

    static func createPrivateDirectory(_ url: URL) throws {
        try FileManager.default.createDirectory(
            at: url,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: NSNumber(value: 0o700)])
        let values = try url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard values.isDirectory == true,
              values.isSymbolicLink != true else {
            throw HubStoreError.corruptedStorage
        }
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: 0o700)],
            ofItemAtPath: url.path)
    }

    static func removeStaleTemporaryFiles(
        in directory: URL,
        destinationNameIsAllowed: (String) -> Bool) throws {
        let urls = try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey])
        var hasUnconfirmedRemoval = false
        for url in urls {
            guard let destinationName = durableTemporaryDestinationName(url.lastPathComponent),
                  destinationNameIsAllowed(destinationName) else {
                continue
            }
            let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            guard values.isRegularFile == true,
                  values.isSymbolicLink != true else {
                throw HubStoreError.corruptedStorage
            }
            let outcome = try removePrivateFileIfPresent(url)
            hasUnconfirmedRemoval = hasUnconfirmedRemoval || outcome == .committedButUnconfirmed
        }
        if hasUnconfirmedRemoval {
            try confirmDirectory(directory)
        }
    }

    static func pathExistsIncludingSymbolicLink(_ url: URL) -> Bool {
        FileManager.default.fileExists(atPath: url.path)
            || (try? FileManager.default.destinationOfSymbolicLink(atPath: url.path)) != nil
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
