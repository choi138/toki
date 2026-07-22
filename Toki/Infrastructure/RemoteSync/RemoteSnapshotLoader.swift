import Foundation
import TokiSyncProtocol

actor RemoteSnapshotLoader {
    private static let cacheFreshness: TimeInterval = 30
    private static let offlineCacheMaximumAge: TimeInterval = 48 * 60 * 60
    private static let maximumConcurrentDeviceFetches = 4

    private let configurationProvider: any RemoteSyncConfigurationProviding
    private let client: any RemoteHubClientProtocol
    private let cache: any RemoteSnapshotCaching
    private let anchorStore: any RemoteSnapshotAnchorStoring
    private let lifecycleCoordinator: RemoteSyncLifecycleCoordinator
    private var loadedConfiguration: RemoteHubConfiguration?
    private var loadedState: LoadedRemoteSnapshotState?
    private var inFlightConfiguration: RemoteHubConfiguration?
    private var inFlightTask: Task<[RemoteUsageSnapshot], Error>?

    init(
        configurationProvider: any RemoteSyncConfigurationProviding,
        client: any RemoteHubClientProtocol,
        cache: any RemoteSnapshotCaching,
        anchorStore: any RemoteSnapshotAnchorStoring,
        lifecycleCoordinator: RemoteSyncLifecycleCoordinator) {
        self.configurationProvider = configurationProvider
        self.client = client
        self.cache = cache
        self.anchorStore = anchorStore
        self.lifecycleCoordinator = lifecycleCoordinator
    }

    func loadSnapshots(configuration: RemoteHubConfiguration) async throws -> [RemoteUsageSnapshot] {
        if let task = inFlightTask {
            if inFlightConfiguration == configuration {
                return try await task.value
            }
            _ = try? await task.value
            return try await loadSnapshots(configuration: configuration)
        }

        let task = Task { try await performLoad(configuration: configuration, now: Date()) }
        inFlightConfiguration = configuration
        inFlightTask = task
        do {
            let snapshots = try await task.value
            inFlightConfiguration = nil
            inFlightTask = nil
            return snapshots
        } catch {
            inFlightConfiguration = nil
            inFlightTask = nil
            throw error
        }
    }
}

private extension RemoteSnapshotLoader {
    struct LoadedRemoteSnapshotState {
        let entry: RemoteSnapshotCacheEntry
        let snapshotsByDevice: [String: RemoteUsageSnapshot]
        let encryptionKeysByDevice: [String: String]
        let lastCheckedAt: Date
        let usedOfflineFallback: Bool
        let lifecycleTicket: RemoteSyncLifecycleCoordinator.ReadTicket

        var snapshots: [RemoteUsageSnapshot] {
            snapshotsByDevice.values.sorted { $0.device.id < $1.device.id }
        }

        var isComplete: Bool {
            let envelopeDeviceIDs = Set(entry.envelopes.map(\.deviceID))
            return Set(snapshotsByDevice.keys) == envelopeDeviceIDs
                && Set(encryptionKeysByDevice.keys) == envelopeDeviceIDs
        }
    }

    private func performLoad(
        configuration: RemoteHubConfiguration,
        now: Date) async throws -> [RemoteUsageSnapshot] {
        let lifecycleTicket = lifecycleCoordinator.beginRead()
        if loadedConfiguration != configuration || loadedState?.lifecycleTicket != lifecycleTicket {
            loadedConfiguration = configuration
            loadedState = nil
        }

        if let loadedState, try canReuse(loadedState, now: now) {
            try lifecycleCoordinator.validate(lifecycleTicket)
            return loadedState.snapshots
        }

        let cachedState: LoadedRemoteSnapshotState?
        if let loadedState {
            cachedState = loadedState
        } else {
            cachedState = try loadCachedState(
                configuration: configuration,
                lifecycleTicket: lifecycleTicket)
            loadedState = cachedState
        }
        if let cachedState,
           cachedState.isComplete,
           now.timeIntervalSince(cachedState.entry.fetchedAt) >= 0,
           now.timeIntervalSince(cachedState.entry.fetchedAt) <= Self.cacheFreshness {
            try RemoteDeviceFreshness.validate(cachedState.entry.manifest, now: now)
            let reused = LoadedRemoteSnapshotState(
                entry: cachedState.entry,
                snapshotsByDevice: cachedState.snapshotsByDevice,
                encryptionKeysByDevice: cachedState.encryptionKeysByDevice,
                lastCheckedAt: now,
                usedOfflineFallback: false,
                lifecycleTicket: lifecycleTicket)
            try lifecycleCoordinator.validate(lifecycleTicket)
            loadedState = reused
            return reused.snapshots
        }

        do {
            let refreshed = try await fetchState(
                configuration: configuration,
                cachedState: cachedState,
                lifecycleTicket: lifecycleTicket,
                now: now)
            loadedState = refreshed
            return refreshed.snapshots
        } catch let error where Self.allowsCachedFallback(error) {
            if let cachedState, cachedState.isComplete {
                let age = now.timeIntervalSince(cachedState.entry.fetchedAt)
                if age >= 0, age <= Self.offlineCacheMaximumAge {
                    let fallback = LoadedRemoteSnapshotState(
                        entry: cachedState.entry,
                        snapshotsByDevice: cachedState.snapshotsByDevice,
                        encryptionKeysByDevice: cachedState.encryptionKeysByDevice,
                        lastCheckedAt: now,
                        usedOfflineFallback: true,
                        lifecycleTicket: lifecycleTicket)
                    try lifecycleCoordinator.validate(lifecycleTicket)
                    loadedState = fallback
                    return fallback.snapshots
                }
            }
            throw error
        }
    }

    private func canReuse(_ state: LoadedRemoteSnapshotState, now: Date) throws -> Bool {
        guard state.isComplete else { return false }
        let checkedAge = now.timeIntervalSince(state.lastCheckedAt)
        guard checkedAge >= 0, checkedAge <= Self.cacheFreshness else { return false }
        if state.usedOfflineFallback {
            let cacheAge = now.timeIntervalSince(state.entry.fetchedAt)
            guard cacheAge >= 0, cacheAge <= Self.offlineCacheMaximumAge else { return false }
            return true
        }
        try RemoteDeviceFreshness.validate(state.entry.manifest, now: now)
        return true
    }

    private func loadCachedState(
        configuration: RemoteHubConfiguration,
        lifecycleTicket: RemoteSyncLifecycleCoordinator.ReadTicket) throws -> LoadedRemoteSnapshotState? {
        let entry: RemoteSnapshotCacheEntry?
        do {
            entry = try cache.load()
        } catch {
            return nil
        }
        guard let entry else { return nil }
        guard entry.snapshotCacheIdentifier == configuration.snapshotCacheIdentifier else {
            try lifecycleCoordinator.commit(lifecycleTicket) {
                guard try configurationProvider.load() == configuration else {
                    throw RemoteSyncLifecycleError.stateChanged
                }
                try cache.clear()
            }
            return nil
        }
        let authenticated = try authenticate(entry.envelopes, skippingMissingKeys: true)
        let authenticatedDeviceIDs = Set(authenticated.encryptionKeysByDevice.keys)
        let authenticatedEnvelopes = entry.envelopes.filter {
            authenticatedDeviceIDs.contains($0.deviceID)
        }
        do {
            try lifecycleCoordinator.commit(lifecycleTicket) {
                try validateCommitState(
                    configuration: configuration,
                    encryptionKeysByDevice: authenticated.encryptionKeysByDevice,
                    envelopeDeviceIDs: authenticatedDeviceIDs)
                if !authenticatedEnvelopes.isEmpty {
                    try anchorStore.validateAndSave(authenticatedEnvelopes)
                }
            }
        } catch RemoteUsageReaderError.staleSnapshot {
            try discardReplayInconsistentCache(lifecycleTicket: lifecycleTicket)
            return nil
        } catch RemoteUsageReaderError.conflictingSnapshots {
            try discardReplayInconsistentCache(lifecycleTicket: lifecycleTicket)
            return nil
        }
        return LoadedRemoteSnapshotState(
            entry: entry,
            snapshotsByDevice: Dictionary(uniqueKeysWithValues: authenticated.snapshots.map { ($0.device.id, $0) }),
            encryptionKeysByDevice: authenticated.encryptionKeysByDevice,
            lastCheckedAt: entry.fetchedAt,
            usedOfflineFallback: false,
            lifecycleTicket: lifecycleTicket)
    }

    private func discardReplayInconsistentCache(
        lifecycleTicket: RemoteSyncLifecycleCoordinator.ReadTicket) throws {
        try lifecycleCoordinator.commit(lifecycleTicket) {
            try cache.clear()
        }
    }

    private func fetchState(
        configuration: RemoteHubConfiguration,
        cachedState: LoadedRemoteSnapshotState?,
        lifecycleTicket: RemoteSyncLifecycleCoordinator.ReadTicket,
        now: Date) async throws -> LoadedRemoteSnapshotState {
        let cachedEntry = cachedState?.entry
        let manifestResult = try await fetchManifest(
            configuration: configuration,
            cachedEntry: cachedEntry,
            now: now)
        let manifest = manifestResult.devices
        let cachedEnvelopes = Dictionary(uniqueKeysWithValues: (cachedEntry?.envelopes ?? []).map {
            ($0.deviceID, $0)
        })
        let desiredSequences = Dictionary(uniqueKeysWithValues: manifest.compactMap { device in
            device.latestSequence.map { (device.id, $0) }
        })
        let changedDeviceIDs = Set(desiredSequences.compactMap { deviceID, sequence in
            cachedEnvelopes[deviceID]?.sequence == sequence ? nil : deviceID
        })
        let removedDeviceIDs = Set(cachedEnvelopes.keys).subtracting(desiredSequences.keys)
        let retainedEnvelopes = cachedEnvelopes.values.filter { envelope in
            desiredSequences[envelope.deviceID] != nil && !changedDeviceIDs.contains(envelope.deviceID)
        }
        var retainedPayloadBudget = RemoteSnapshotPayloadBudget(
            maximumBytes: TokiSyncLimits.maximumStoredSnapshotBytes)
        for envelope in retainedEnvelopes {
            try retainedPayloadBudget.consume(envelope)
        }
        let fetchedEnvelopes = try await fetchChangedEnvelopes(
            configuration: configuration,
            desiredSequences: desiredSequences,
            changedDeviceIDs: changedDeviceIDs,
            maximumPayloadBytes: retainedPayloadBudget.remainingBytes)

        let fetchedSequences = Dictionary(uniqueKeysWithValues: fetchedEnvelopes.map { ($0.deviceID, $0.sequence) })
        let reconciliation = reconcileManifest(manifest, fetchedSequences: fetchedSequences)

        let envelopesByDevice = reconcileEnvelopes(
            cachedEnvelopes: cachedEnvelopes,
            removedDeviceIDs: removedDeviceIDs,
            fetchedEnvelopes: fetchedEnvelopes)
        let entry = try RemoteSnapshotCacheValidation.validated(RemoteSnapshotCacheEntry(
            envelopes: Array(envelopesByDevice.values),
            manifest: reconciliation.manifest,
            manifestEntityTag: reconciliation.didAdvance ? nil : manifestResult.entityTag,
            fetchedAt: now,
            snapshotCacheIdentifier: configuration.snapshotCacheIdentifier), now: now)
        try RemoteDeviceFreshness.validate(entry.manifest, now: now)

        let authenticatedChanges = try authenticate(fetchedEnvelopes)
        var encryptionKeysByDevice = cachedState?.encryptionKeysByDevice ?? [:]
        for deviceID in removedDeviceIDs {
            encryptionKeysByDevice.removeValue(forKey: deviceID)
        }
        encryptionKeysByDevice.merge(authenticatedChanges.encryptionKeysByDevice) { _, changed in changed }
        let envelopeDeviceIDs = Set(entry.envelopes.map(\.deviceID))
        guard Set(encryptionKeysByDevice.keys) == envelopeDeviceIDs else {
            throw RemoteUsageReaderError.missingDeviceKey
        }
        try lifecycleCoordinator.commit(lifecycleTicket) {
            try validateCommitState(
                configuration: configuration,
                encryptionKeysByDevice: encryptionKeysByDevice,
                envelopeDeviceIDs: envelopeDeviceIDs)
            if !fetchedEnvelopes.isEmpty {
                try anchorStore.validateAndSave(fetchedEnvelopes)
            }
            try cache.save(entry, changedDeviceIDs: changedDeviceIDs.union(removedDeviceIDs))
        }

        var snapshotsByDevice = cachedState?.snapshotsByDevice ?? [:]
        for deviceID in removedDeviceIDs {
            snapshotsByDevice.removeValue(forKey: deviceID)
        }
        for snapshot in authenticatedChanges.snapshots {
            snapshotsByDevice[snapshot.device.id] = snapshot
        }
        guard Set(snapshotsByDevice.keys) == Set(envelopesByDevice.keys) else {
            throw RemoteHubClientError.invalidPayload
        }
        return LoadedRemoteSnapshotState(
            entry: entry,
            snapshotsByDevice: snapshotsByDevice,
            encryptionKeysByDevice: encryptionKeysByDevice,
            lastCheckedAt: now,
            usedOfflineFallback: false,
            lifecycleTicket: lifecycleTicket)
    }

    private func reconcileEnvelopes(
        cachedEnvelopes: [String: EncryptedUsageEnvelope],
        removedDeviceIDs: Set<String>,
        fetchedEnvelopes: [EncryptedUsageEnvelope]) -> [String: EncryptedUsageEnvelope] {
        var envelopesByDevice = cachedEnvelopes
        for deviceID in removedDeviceIDs {
            envelopesByDevice.removeValue(forKey: deviceID)
        }
        for envelope in fetchedEnvelopes {
            envelopesByDevice[envelope.deviceID] = envelope
        }
        return envelopesByDevice
    }

    private func reconcileManifest(
        _ manifest: [RemoteDeviceSummary],
        fetchedSequences: [String: UInt64]) -> (manifest: [RemoteDeviceSummary], didAdvance: Bool) {
        var didAdvance = false
        let reconciled = manifest.map { device in
            guard let fetchedSequence = fetchedSequences[device.id],
                  let manifestSequence = device.latestSequence,
                  fetchedSequence > manifestSequence else {
                return device
            }
            didAdvance = true
            return RemoteDeviceSummary(
                id: device.id,
                name: device.name,
                createdAt: device.createdAt,
                lastSeenAt: device.lastSeenAt,
                latestSequence: fetchedSequence,
                syncIntervalSeconds: device.syncIntervalSeconds)
        }
        return (reconciled, didAdvance)
    }

    private func fetchManifest(
        configuration: RemoteHubConfiguration,
        cachedEntry: RemoteSnapshotCacheEntry?,
        now: Date) async throws -> (devices: [RemoteDeviceSummary], entityTag: String) {
        let result = try await client.fetchSnapshotManifest(
            configuration: configuration,
            ifNoneMatch: cachedEntry?.manifestEntityTag)
        switch result {
        case let .modified(devices, entityTag):
            return try (RemoteSnapshotManifestValidation.validated(devices, now: now), entityTag)
        case let .notModified(entityTag):
            guard let cachedEntry,
                  cachedEntry.manifestEntityTag == entityTag else {
                throw RemoteHubClientError.invalidResponse
            }
            return (cachedEntry.manifest, entityTag)
        }
    }

    private func fetchChangedEnvelopes(
        configuration: RemoteHubConfiguration,
        desiredSequences: [String: UInt64],
        changedDeviceIDs: Set<String>,
        maximumPayloadBytes: Int) async throws -> [EncryptedUsageEnvelope] {
        let client = client
        let sortedDeviceIDs = changedDeviceIDs.sorted()
        var fetched: [EncryptedUsageEnvelope] = []
        var payloadBudget = RemoteSnapshotPayloadBudget(maximumBytes: maximumPayloadBytes)
        for startIndex in stride(from: 0, to: sortedDeviceIDs.count, by: Self.maximumConcurrentDeviceFetches) {
            let endIndex = min(startIndex + Self.maximumConcurrentDeviceFetches, sortedDeviceIDs.count)
            let batch = Array(sortedDeviceIDs[startIndex..<endIndex])
            let batchEnvelopes = try await withThrowingTaskGroup(of: EncryptedUsageEnvelope.self) { group in
                for deviceID in batch {
                    group.addTask {
                        try await client.fetchSnapshot(configuration: configuration, deviceID: deviceID)
                    }
                }
                var values: [EncryptedUsageEnvelope] = []
                for try await envelope in group {
                    guard let desiredSequence = desiredSequences[envelope.deviceID],
                          envelope.sequence >= desiredSequence else {
                        group.cancelAll()
                        throw RemoteHubClientError.invalidPayload
                    }
                    do {
                        try payloadBudget.consume(envelope)
                    } catch {
                        group.cancelAll()
                        throw error
                    }
                    values.append(envelope)
                }
                return values
            }
            fetched.append(contentsOf: batchEnvelopes)
        }
        let validated = try RemoteSnapshotProgress.validated(fetched)
        guard Set(validated.map(\.deviceID)) == changedDeviceIDs else {
            throw RemoteHubClientError.invalidPayload
        }
        return validated
    }

    private func authenticate(
        _ envelopes: [EncryptedUsageEnvelope],
        skippingMissingKeys: Bool = false) throws -> AuthenticatedRemoteSnapshots {
        var encryptionKeysByDevice: [String: String] = [:]
        var snapshots: [RemoteUsageSnapshot] = []
        for envelope in try RemoteSnapshotProgress.validated(envelopes) {
            guard let encryptionKey = try configurationProvider.encryptionKey(for: envelope.deviceID) else {
                if skippingMissingKeys { continue }
                throw RemoteUsageReaderError.missingDeviceKey
            }
            encryptionKeysByDevice[envelope.deviceID] = encryptionKey
            try snapshots.append(SnapshotCipher.open(envelope, key: encryptionKey))
        }
        return AuthenticatedRemoteSnapshots(
            snapshots: snapshots,
            encryptionKeysByDevice: encryptionKeysByDevice)
    }

    private func validateCommitState(
        configuration: RemoteHubConfiguration,
        encryptionKeysByDevice: [String: String],
        envelopeDeviceIDs: Set<String>) throws {
        guard try configurationProvider.load() == configuration,
              Set(encryptionKeysByDevice.keys) == envelopeDeviceIDs else {
            throw RemoteSyncLifecycleError.stateChanged
        }
        for (deviceID, encryptionKey) in encryptionKeysByDevice {
            guard try configurationProvider.encryptionKey(for: deviceID) == encryptionKey else {
                throw RemoteSyncLifecycleError.stateChanged
            }
        }
    }

    private static func allowsCachedFallback(_ error: Error) -> Bool {
        if let clientError = error as? RemoteHubClientError {
            return clientError.allowsCachedFallback
        }
        guard let urlError = error as? URLError else { return false }
        switch urlError.code {
        case .timedOut,
             .cannotFindHost,
             .cannotConnectToHost,
             .networkConnectionLost,
             .dnsLookupFailed,
             .resourceUnavailable,
             .notConnectedToInternet,
             .internationalRoamingOff,
             .callIsActive,
             .dataNotAllowed:
            return true
        default:
            return false
        }
    }
}

private struct AuthenticatedRemoteSnapshots {
    let snapshots: [RemoteUsageSnapshot]
    let encryptionKeysByDevice: [String: String]
}
