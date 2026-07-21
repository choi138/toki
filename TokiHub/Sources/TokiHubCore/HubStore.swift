import Foundation
import TokiDurableStorage
import TokiSyncProtocol

actor HubStore {
    private let registryURL: URL
    private let snapshotsDirectory: URL
    private let storageLock: HubStorageLock
    private var registry: HubRegistry

    init(directory: URL) throws {
        registryURL = directory.appendingPathComponent("devices.json")
        snapshotsDirectory = directory.appendingPathComponent("snapshots")

        try Self.createPrivateDirectory(directory)
        try Self.createPrivateDirectory(snapshotsDirectory)
        storageLock = try HubStorageLock.acquire(directory: directory)
        try Self.removeStaleTemporaryFiles(in: directory) { $0 == "devices.json" }
        try Self.removeStaleTemporaryFiles(in: directory.appendingPathComponent("snapshots")) { destinationName in
            guard destinationName.hasSuffix(".json") else { return false }
            return TokiSyncValidation.isSafeDeviceID(String(destinationName.dropLast(5)))
        }
        if Self.pathExistsIncludingSymbolicLink(registryURL) {
            let values = try registryURL.resourceValues(
                forKeys: [.fileSizeKey, .isRegularFileKey, .isSymbolicLinkKey])
            guard values.isRegularFile == true,
                  values.isSymbolicLink != true,
                  let fileSize = values.fileSize,
                  fileSize <= TokiSyncLimits.maximumRegistryBytes else {
                throw HubStoreError.corruptedStorage
            }
            let data = try Data(contentsOf: registryURL)
            guard !data.isEmpty,
                  data.count <= TokiSyncLimits.maximumRegistryBytes else {
                throw HubStoreError.corruptedStorage
            }
            var decoded = try TokiSyncCoding.makeDecoder().decode(HubRegistry.self, from: data)
            let originalDeviceCount = decoded.devices.count
            decoded.devices = decoded.devices.filter { $0.value.revokedAt == nil }
            try Self.validateRegistry(decoded)
            let recovery = try Self.recoverStorage(
                registry: decoded,
                snapshotsDirectory: snapshotsDirectory)
            registry = recovery.registry
            if recovery.changed || decoded.devices.count != originalDeviceCount {
                let registryOutcome = try Self.writeRegistry(registry, to: registryURL)
                try Self.requireSynchronized(registryOutcome)
            }
        } else {
            registry = HubRegistry()
            try Self.requireNoSnapshotsWithoutRegistry(snapshotsDirectory)
        }
    }
}

enum HubFileMutationOutcome: Equatable {
    case synchronized
    case committedButUnconfirmed
}

extension HubStore {
    func createDevice(
        name: String,
        syncIntervalSeconds: Int = TokiSyncLimits.defaultSyncIntervalSeconds,
        now: Date = Date()) throws -> CreateRemoteDeviceResponse {
        guard registry.devices.count < TokiSyncLimits.maximumDevices else {
            throw HubStoreError.tooManyDevices
        }
        guard let normalizedName = TokiSyncValidation.normalizedDeviceName(name) else {
            throw HubStoreError.invalidDeviceName
        }
        guard (TokiSyncLimits.minimumSyncIntervalSeconds...TokiSyncLimits.maximumSyncIntervalSeconds)
            .contains(syncIntervalSeconds) else {
            throw HubStoreError.invalidSyncInterval
        }
        guard Self.isSafeStoredTimestamp(now) else {
            throw HubStoreError.invalidTimestamp
        }

        let deviceID = UUID().uuidString.lowercased()
        let uploadToken = "toki_w_\(SnapshotCipher.randomToken())"
        let record = HubDeviceRecord(
            id: deviceID,
            name: normalizedName,
            uploadTokenDigest: SnapshotCipher.digest(uploadToken),
            createdAt: now,
            revokedAt: nil,
            lastSeenAt: nil,
            latestSequence: nil,
            syncIntervalSeconds: syncIntervalSeconds)
        registry.devices[deviceID] = record
        let registryOutcome: HubFileMutationOutcome
        do {
            registryOutcome = try persistRegistry()
        } catch {
            registry.devices.removeValue(forKey: deviceID)
            throw error
        }
        try Self.requireSynchronized(registryOutcome)
        return CreateRemoteDeviceResponse(
            deviceID: deviceID,
            deviceName: normalizedName,
            uploadToken: uploadToken)
    }

    func authorizeDevice(_ deviceID: String, uploadToken: String) throws {
        _ = try authenticatedDevice(deviceID, uploadToken: uploadToken)
    }

    func heartbeat(
        deviceID: String,
        uploadToken: String,
        latestSequence: UInt64,
        now: Date = Date()) throws {
        var device = try authenticatedDevice(deviceID, uploadToken: uploadToken)
        guard Self.isSafeStoredTimestamp(now) else {
            throw HubStoreError.invalidTimestamp
        }
        guard latestSequence > 0, device.latestSequence == latestSequence else {
            throw HubStoreError.sequenceConflict
        }
        let previousDevice = device
        device.lastSeenAt = now
        registry.devices[deviceID] = device
        let registryOutcome: HubFileMutationOutcome
        do {
            registryOutcome = try persistRegistry()
        } catch {
            registry.devices[deviceID] = previousDevice
            throw error
        }
        try Self.requireSynchronized(registryOutcome)
    }

    func store(
        _ envelope: EncryptedUsageEnvelope,
        deviceID: String,
        uploadToken: String,
        now: Date = Date()) throws {
        var device = try authenticatedDevice(deviceID, uploadToken: uploadToken)
        guard Self.isSafeStoredTimestamp(now) else {
            throw HubStoreError.invalidTimestamp
        }
        guard envelope.schemaVersion == TokiSyncProtocolVersion.current else {
            throw HubStoreError.unsupportedVersion
        }
        guard envelope.deviceID == deviceID else {
            throw HubStoreError.deviceMismatch
        }
        guard envelope.sequence > 0,
              !envelope.payload.isEmpty,
              envelope.payload.utf8.count <= TokiSyncLimits.maximumEnvelopeBytes,
              Data(base64Encoded: envelope.payload) != nil else {
            throw HubStoreError.payloadTooLarge
        }
        guard envelope.generatedAt.timeIntervalSince1970.isFinite,
              envelope.generatedAt <= now.addingTimeInterval(86400),
              envelope.generatedAt >= Date(timeIntervalSince1970: 946_684_800) else {
            throw HubStoreError.invalidTimestamp
        }

        if let latestSequence = device.latestSequence {
            if envelope.sequence < latestSequence {
                throw HubStoreError.staleSequence
            }
            if envelope.sequence == latestSequence {
                guard let existingEnvelope = try existingEnvelope(for: device),
                      Self.isSameEnvelope(existingEnvelope, envelope) else {
                    throw HubStoreError.sequenceConflict
                }
                try Self.confirmDirectory(snapshotsDirectory)
                let previousDevice = device
                device.lastSeenAt = now
                registry.devices[deviceID] = device
                let registryOutcome: HubFileMutationOutcome
                do {
                    registryOutcome = try persistRegistry()
                } catch {
                    registry.devices[deviceID] = previousDevice
                    throw error
                }
                try Self.requireSynchronized(registryOutcome)
                return
            }
        }

        let encodedEnvelope = try TokiSyncCoding.makeEncoder().encode(envelope)
        guard encodedEnvelope.count <= TokiSyncLimits.maximumEnvelopeBytes else {
            throw HubStoreError.payloadTooLarge
        }
        let storedBytes = try storedSnapshotBytes(excluding: deviceID)
        guard storedBytes <= TokiSyncLimits.maximumStoredSnapshotBytes - encodedEnvelope.count else {
            throw HubStoreError.storageQuotaExceeded
        }

        let snapshotURL = snapshotURL(for: deviceID)
        let previousSnapshot = try Self.snapshotDataIfPresent(at: snapshotURL)
        let previousDevice = device
        let snapshotOutcome = try Self.writePrivate(encodedEnvelope, to: snapshotURL)
        try Self.confirmCommittedMutation(snapshotOutcome, in: snapshotsDirectory)
        device.latestSequence = envelope.sequence
        device.lastSeenAt = now
        registry.devices[deviceID] = device
        let registryOutcome: HubFileMutationOutcome
        do {
            registryOutcome = try persistRegistry()
        } catch {
            registry.devices[deviceID] = previousDevice
            if let previousSnapshot {
                _ = try? Self.writePrivate(previousSnapshot, to: snapshotURL)
            } else {
                _ = try? Self.removePrivateFileIfPresent(snapshotURL)
            }
            throw error
        }
        try Self.requireSynchronized(registryOutcome)
    }

    func snapshots() throws -> [EncryptedUsageEnvelope] {
        try registry.devices.values
            .filter { $0.latestSequence != nil }
            .map { device in
                guard let envelope = try existingEnvelope(for: device) else {
                    throw HubStoreError.corruptedStorage
                }
                return envelope
            }
            .sorted { $0.deviceID < $1.deviceID }
    }

    func snapshot(deviceID: String) throws -> EncryptedUsageEnvelope {
        guard TokiSyncValidation.isSafeDeviceID(deviceID),
              let device = registry.devices[deviceID],
              device.latestSequence != nil,
              let envelope = try existingEnvelope(for: device) else {
            throw HubStoreError.deviceNotFound
        }
        return envelope
    }

    func devices() -> [RemoteDeviceSummary] {
        registry.devices.values
            .map { device in
                RemoteDeviceSummary(
                    id: device.id,
                    name: device.name,
                    createdAt: device.createdAt,
                    lastSeenAt: device.lastSeenAt,
                    latestSequence: device.latestSequence,
                    syncIntervalSeconds: device.syncIntervalSeconds)
            }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    func snapshotVersionTag() -> String {
        let version = registry.devices.values
            .filter { $0.latestSequence != nil }
            .sorted { $0.id < $1.id }
            .map { "\($0.id):\($0.latestSequence ?? 0)" }
            .joined(separator: "\n")
        return SnapshotCipher.digest(version)
    }

    func manifestVersionTag() -> String {
        let version = registry.devices.values
            .sorted { $0.id < $1.id }
            .map { device in
                let lastSeen = device.lastSeenAt.flatMap(Self.millisecondsSince1970) ?? -1
                return "\(device.id):\(device.latestSequence ?? 0):\(lastSeen):\(device.syncIntervalSeconds)"
            }
            .joined(separator: "\n")
        return SnapshotCipher.digest(version)
    }

    func revokeDevice(_ deviceID: String) throws {
        guard TokiSyncValidation.isSafeDeviceID(deviceID) else {
            throw HubStoreError.deviceNotFound
        }
        guard let device = registry.devices.removeValue(forKey: deviceID) else {
            let registryOutcome = try persistRegistry()
            try Self.requireSynchronized(registryOutcome)
            let snapshotOutcome = try removeSnapshotIfPresent(for: deviceID)
            try Self.requireSynchronized(snapshotOutcome)
            return
        }
        let registryOutcome: HubFileMutationOutcome
        do {
            registryOutcome = try persistRegistry()
        } catch {
            registry.devices[deviceID] = device
            throw error
        }
        guard registryOutcome == .synchronized else {
            throw HubStoreError.storageDurabilityUnconfirmed
        }
        let snapshotOutcome = try removeSnapshotIfPresent(for: deviceID)
        try Self.requireSynchronized(snapshotOutcome)
    }
}

extension HubStore {
    private func authenticatedDevice(_ deviceID: String, uploadToken: String) throws -> HubDeviceRecord {
        guard TokiSyncValidation.isSafeDeviceID(deviceID),
              TokiSyncValidation.isSafeCredential(uploadToken),
              let device = registry.devices[deviceID] else {
            throw HubStoreError.unauthorized
        }
        let suppliedDigest = SnapshotCipher.digest(uploadToken)
        guard SnapshotCipher.constantTimeEqual(suppliedDigest, device.uploadTokenDigest) else {
            throw HubStoreError.unauthorized
        }
        return device
    }

    private func existingEnvelope(for device: HubDeviceRecord) throws -> EncryptedUsageEnvelope? {
        let url = snapshotURL(for: device.id)
        guard let data = try Self.snapshotDataIfPresent(at: url) else { return nil }
        do {
            let envelope = try Self.decodeStoredEnvelope(data, expectedDeviceID: device.id)
            guard envelope.sequence == device.latestSequence else {
                throw HubStoreError.corruptedStorage
            }
            return envelope
        } catch let error as HubStoreError {
            throw error
        } catch {
            throw HubStoreError.corruptedStorage
        }
    }

    private func storedSnapshotBytes(excluding deviceID: String) throws -> Int {
        try registry.devices.values.reduce(into: 0) { result, device in
            guard device.id != deviceID, device.latestSequence != nil else { return }
            guard let fileSize = try snapshotFileSizeIfPresent(at: snapshotURL(for: device.id)) else {
                throw HubStoreError.corruptedStorage
            }
            guard result <= TokiSyncLimits.maximumStoredSnapshotBytes - fileSize else {
                throw HubStoreError.storageQuotaExceeded
            }
            result += fileSize
        }
    }

    private func snapshotFileSizeIfPresent(at url: URL) throws -> Int? {
        guard Self.pathExistsIncludingSymbolicLink(url) else { return nil }
        let values = try url.resourceValues(
            forKeys: [.fileSizeKey, .isRegularFileKey, .isSymbolicLinkKey])
        guard values.isRegularFile == true,
              values.isSymbolicLink != true,
              let fileSize = values.fileSize,
              fileSize > 0,
              fileSize <= TokiSyncLimits.maximumEnvelopeBytes else {
            throw HubStoreError.corruptedStorage
        }
        return fileSize
    }

    private func removeSnapshotIfPresent(for deviceID: String) throws -> HubFileMutationOutcome {
        let url = snapshotURL(for: deviceID)
        guard Self.pathExistsIncludingSymbolicLink(url) else {
            try Self.confirmDirectory(snapshotsDirectory)
            return .synchronized
        }
        do {
            let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            guard values.isRegularFile == true,
                  values.isSymbolicLink != true else {
                throw HubStoreError.corruptedStorage
            }
            return try Self.removePrivateFileIfPresent(url)
        } catch {
            throw HubStoreError.corruptedStorage
        }
    }

    private func snapshotURL(for deviceID: String) -> URL {
        snapshotsDirectory.appendingPathComponent("\(deviceID).json")
    }

    private func persistRegistry() throws -> HubFileMutationOutcome {
        try Self.writeRegistry(registry, to: registryURL)
    }

    @discardableResult
    private static func writeRegistry(
        _ registry: HubRegistry,
        to registryURL: URL) throws -> HubFileMutationOutcome {
        let data = try TokiSyncCoding.makeEncoder().encode(registry)
        guard data.count <= TokiSyncLimits.maximumRegistryBytes else {
            throw HubStoreError.corruptedStorage
        }
        return try Self.writePrivate(data, to: registryURL)
    }

    @discardableResult
    static func writePrivate(
        _ data: Data,
        to url: URL,
        writer: (Data, URL) throws -> Void = { data, url in
            try DurableFileIO.writePrivate(data, to: url)
        }) throws -> HubFileMutationOutcome {
        do {
            try writer(data, url)
            return .synchronized
        } catch DurableFileIOError.replacementCommittedDirectorySyncFailed {
            return .committedButUnconfirmed
        }
    }

    @discardableResult
    static func removePrivateFileIfPresent(
        _ url: URL,
        remover: (URL) throws -> Void = DurableFileIO.removeIfPresent) throws -> HubFileMutationOutcome {
        do {
            try remover(url)
            return .synchronized
        } catch DurableFileIOError.removalCommittedDirectorySyncFailed {
            return .committedButUnconfirmed
        }
    }

    static func requireSynchronized(_ outcomes: HubFileMutationOutcome...) throws {
        guard outcomes.allSatisfy({ $0 == .synchronized }) else {
            throw HubStoreError.storageDurabilityUnconfirmed
        }
    }

    static func confirmCommittedMutation(
        _ outcome: HubFileMutationOutcome,
        in directory: URL,
        synchronizer: (URL) throws -> Void = DurableFileIO.synchronizeDirectory) throws {
        guard outcome == .committedButUnconfirmed else { return }
        do {
            try synchronizer(directory)
        } catch {
            throw HubStoreError.storageDurabilityUnconfirmed
        }
    }

    static func confirmDirectory(_ directory: URL) throws {
        do {
            try DurableFileIO.synchronizeDirectory(directory)
        } catch {
            throw HubStoreError.storageDurabilityUnconfirmed
        }
    }
}

struct HubRegistry: Codable {
    var devices: [String: HubDeviceRecord] = [:]
}

struct HubDeviceRecord: Codable {
    let id: String
    let name: String
    let uploadTokenDigest: String
    let createdAt: Date
    let revokedAt: Date?
    var lastSeenAt: Date?
    var latestSequence: UInt64?
    let syncIntervalSeconds: Int

    init(
        id: String,
        name: String,
        uploadTokenDigest: String,
        createdAt: Date,
        revokedAt: Date?,
        lastSeenAt: Date?,
        latestSequence: UInt64?,
        syncIntervalSeconds: Int) {
        self.id = id
        self.name = name
        self.uploadTokenDigest = uploadTokenDigest
        self.createdAt = createdAt
        self.revokedAt = revokedAt
        self.lastSeenAt = lastSeenAt
        self.latestSequence = latestSequence
        self.syncIntervalSeconds = syncIntervalSeconds
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        uploadTokenDigest = try container.decode(String.self, forKey: .uploadTokenDigest)
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        revokedAt = try container.decodeIfPresent(Date.self, forKey: .revokedAt)
        lastSeenAt = try container.decodeIfPresent(Date.self, forKey: .lastSeenAt)
        latestSequence = try container.decodeIfPresent(UInt64.self, forKey: .latestSequence)
        syncIntervalSeconds = try container.decodeIfPresent(Int.self, forKey: .syncIntervalSeconds)
            ?? TokiSyncLimits.defaultSyncIntervalSeconds
    }
}
