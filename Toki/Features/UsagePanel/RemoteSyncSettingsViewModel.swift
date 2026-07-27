import Combine
import Foundation
import TokiSyncProtocol

@MainActor
final class RemoteSyncSettingsViewModel: ObservableObject {
    @Published var hubURLText = ""
    @Published var ownerToken = ""
    @Published var deviceName = ""
    @Published var retentionDaysText = String(TokiSyncLimits.defaultRetentionDays)
    @Published var syncIntervalMinutesText = String(TokiSyncLimits.defaultSyncIntervalSeconds / 60)
    @Published private(set) var isConnected = false
    @Published private(set) var connectedHost: String?
    @Published private(set) var devices: [RemoteDeviceSummary] = []
    @Published private(set) var deviceIDsWithEncryptionKeys: Set<String> = []
    @Published private(set) var isBusy = false
    @Published private(set) var statusMessage: String?
    @Published private(set) var hasError = false
    @Published private(set) var needsLocalCredentialRecovery = false

    private let store: any RemoteSyncConfigurationStoring
    private let client: any RemoteHubClientProtocol
    private let cache: any RemoteSnapshotCaching
    private let anchorStore: any RemoteSnapshotAnchorStoring
    private let lifecycleCoordinator: RemoteSyncLifecycleCoordinator
    private let pairingBundleClipboard: any PairingBundleCopying
    private let onRemoteSyncChange: () -> Void

    init(
        store: any RemoteSyncConfigurationStoring = RemoteSyncConfigurationStore(),
        client: any RemoteHubClientProtocol = RemoteHubClient(),
        cache: any RemoteSnapshotCaching = RemoteSnapshotCache(),
        anchorStore: any RemoteSnapshotAnchorStoring = RemoteSnapshotAnchorStore(),
        lifecycleCoordinator: RemoteSyncLifecycleCoordinator = .shared,
        pairingBundleClipboard: (any PairingBundleCopying)? = nil,
        onRemoteSyncChange: @escaping () -> Void = {}) {
        self.store = store
        self.client = client
        self.cache = cache
        self.anchorStore = anchorStore
        self.lifecycleCoordinator = lifecycleCoordinator
        self.pairingBundleClipboard = pairingBundleClipboard ?? PairingBundleClipboard()
        self.onRemoteSyncChange = onRemoteSyncChange
        reload()
    }

    func reload() {
        do {
            guard let configuration = try store.load() else {
                resetConnectionState()
                needsLocalCredentialRecovery = false
                return
            }
            isConnected = true
            connectedHost = configuration.hubURL.host
            hubURLText = configuration.hubURL.absoluteString
            needsLocalCredentialRecovery = false
            updateDevices(devices)
        } catch {
            resetConnectionState()
            needsLocalCredentialRecovery = true
            publish(error)
        }
    }
}

extension RemoteSyncSettingsViewModel {
    func connect() async {
        guard !isConnected, !isBusy else { return }
        isBusy = true
        defer { isBusy = false }
        clearStatus()

        do {
            guard let hubURL = URL(string: hubURLText.trimmingCharacters(in: .whitespacesAndNewlines)) else {
                throw RemoteSyncSettingsError.invalidURL
            }
            let configuration = try RemoteHubConfiguration(
                hubURL: hubURL,
                ownerToken: ownerToken)
            let fetchedDevices = try await client.fetchDevices(configuration: configuration)
            try performLocalStateChange {
                try cache.clear()
                try anchorStore.clear()
                try store.clear()
                try store.save(configuration)
            }
            ownerToken = ""
            isConnected = true
            connectedHost = configuration.hubURL.host
            needsLocalCredentialRecovery = false
            updateDevices(fetchedDevices)
            if deviceIDsWithEncryptionKeys.count != devices.count {
                publish(message: "Connected. Revoke and pair devices whose encryption key is unavailable.")
            } else {
                publish(message: "Connected. Per-device snapshot keys are stored in Keychain.")
            }
        } catch {
            reload()
            publish(error)
        }
    }

    func createPairingBundle() async {
        guard !isBusy else { return }
        isBusy = true
        defer { isBusy = false }
        clearStatus()

        do {
            guard let configuration = try store.load() else {
                throw RemoteSyncSettingsError.notConnected
            }
            let name = deviceName.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty else { throw RemoteSyncSettingsError.missingDeviceName }
            guard let retentionDays = Int(retentionDaysText),
                  (TokiSyncLimits.minimumRetentionDays...TokiSyncLimits.maximumRetentionDays)
                  .contains(retentionDays) else {
                throw RemoteSyncSettingsError.invalidRetention
            }
            let minimumSyncIntervalMinutes = TokiSyncLimits.minimumSyncIntervalSeconds / 60
            let maximumSyncIntervalMinutes = TokiSyncLimits.maximumSyncIntervalSeconds / 60
            guard let syncIntervalMinutes = Int(syncIntervalMinutesText),
                  (minimumSyncIntervalMinutes...maximumSyncIntervalMinutes).contains(syncIntervalMinutes) else {
                throw RemoteSyncSettingsError.invalidSyncInterval
            }
            let syncIntervalSeconds = syncIntervalMinutes * 60
            let device = try await client.createDevice(
                name: name,
                syncIntervalSeconds: syncIntervalSeconds,
                configuration: configuration)
            upsertProvisionalDevice(device)
            do {
                var didInvalidateReadTickets = false
                defer {
                    if didInvalidateReadTickets {
                        onRemoteSyncChange()
                    }
                }
                do {
                    let encryptionKey = SnapshotCipher.generateKey()
                    didInvalidateReadTickets = true
                    try performLocalStateChange(notifyingRemoteSyncChange: false) {
                        try store.saveEncryptionKey(encryptionKey, for: device.deviceID)
                    }
                    deviceIDsWithEncryptionKeys.insert(device.deviceID)
                    let bundle = AgentPairingBundle(
                        hubURL: configuration.hubURL,
                        deviceID: device.deviceID,
                        deviceName: device.deviceName,
                        uploadToken: device.uploadToken,
                        encryptionKey: encryptionKey,
                        retentionDays: retentionDays,
                        syncIntervalSeconds: syncIntervalSeconds)
                    try pairingBundleClipboard.copy(TokiSyncCoding.encodeBundle(bundle))
                } catch let pairingError {
                    do {
                        try await revokeRemotelyIfPresent(deviceID: device.deviceID, configuration: configuration)
                        didInvalidateReadTickets = true
                        try performLocalStateChange(notifyingRemoteSyncChange: false) {
                            try anchorStore.remove(
                                deviceID: device.deviceID,
                                originIdentifier: configuration.snapshotCacheIdentifier)
                            try cache.remove(deviceID: device.deviceID)
                            try store.deleteEncryptionKey(for: device.deviceID)
                        }
                        devices.removeAll { $0.id == device.deviceID }
                        deviceIDsWithEncryptionKeys.remove(device.deviceID)
                    } catch {
                        throw RemoteSyncSettingsError.pairingCleanupRequired
                    }
                    throw pairingError
                }
            }
            deviceName = ""
            do {
                try await updateDevices(client.fetchDevices(configuration: configuration))
                publish(message: "Agent pairing bundle copied. It will be cleared from the clipboard in 60 seconds.")
            } catch {
                publish(
                    message: "Pairing bundle copied. Device list refresh failed; use Refresh instead of pairing again.")
            }
        } catch {
            publish(error)
        }
    }

    func updateOwnerToken() async {
        guard !isBusy else { return }
        isBusy = true
        defer { isBusy = false }
        clearStatus()

        do {
            guard let currentConfiguration = try store.load() else {
                throw RemoteSyncSettingsError.notConnected
            }
            let updatedConfiguration = try RemoteHubConfiguration(
                hubURL: currentConfiguration.hubURL,
                ownerToken: ownerToken)
            let fetchedDevices = try await client.fetchDevices(configuration: updatedConfiguration)
            try performLocalStateChange {
                try anchorStore.copyAnchors(
                    from: currentConfiguration.legacySnapshotCacheIdentifier,
                    to: updatedConfiguration.snapshotCacheIdentifier)
                try anchorStore.copyAnchors(
                    from: currentConfiguration.snapshotCacheIdentifier,
                    to: updatedConfiguration.snapshotCacheIdentifier)
                try store.save(updatedConfiguration)
            }
            ownerToken = ""
            updateDevices(fetchedDevices)
            publish(message: "Hub owner token updated.")
        } catch {
            publish(error)
        }
    }

    func refreshDevices() async {
        guard isConnected, !isBusy else { return }
        isBusy = true
        defer { isBusy = false }
        clearStatus()
        do {
            guard let configuration = try store.load() else {
                throw RemoteSyncSettingsError.notConnected
            }
            try await updateDevices(client.fetchDevices(configuration: configuration))
        } catch {
            publish(error)
        }
    }

    func revoke(_ device: RemoteDeviceSummary) async {
        guard !isBusy else { return }
        isBusy = true
        defer { isBusy = false }
        clearStatus()

        do {
            guard let configuration = try store.load() else {
                throw RemoteSyncSettingsError.notConnected
            }
            try await revokeRemotelyIfPresent(deviceID: device.id, configuration: configuration)
            try performLocalStateChange {
                try anchorStore.remove(
                    deviceID: device.id,
                    originIdentifier: configuration.snapshotCacheIdentifier)
                try cache.remove(deviceID: device.id)
                try store.deleteEncryptionKey(for: device.id)
            }
            devices.removeAll { $0.id == device.id }
            deviceIDsWithEncryptionKeys.remove(device.id)
            do {
                try await updateDevices(client.fetchDevices(configuration: configuration))
                publish(message: "Revoked \(device.name).")
            } catch {
                publish(message: "Revoked \(device.name), but the device list could not refresh. Use Refresh.")
            }
        } catch {
            publish(error)
        }
    }
}

extension RemoteSyncSettingsViewModel {
    func disconnect() async {
        guard !isBusy else { return }
        isBusy = true
        defer { isBusy = false }
        clearStatus()

        do {
            guard let configuration = try store.load() else {
                throw RemoteSyncSettingsError.notConnected
            }
            let fetchedDevices = try await client.fetchDevices(configuration: configuration)
            updateDevices(fetchedDevices)
            guard fetchedDevices.isEmpty else {
                throw RemoteSyncSettingsError.revokeDevicesBeforeDisconnect
            }
            try clearLocalState()
            resetConnectionState()
            needsLocalCredentialRecovery = false
            ownerToken = ""
            publish(message: "Disconnected and removed local remote-sync credentials.")
        } catch {
            reload()
            publish(error)
        }
    }

    func disconnectLocally() async {
        guard isConnected, !isBusy else { return }
        isBusy = true
        defer { isBusy = false }
        clearStatus()

        do {
            try clearLocalState()
            resetConnectionState()
            needsLocalCredentialRecovery = false
            hubURLText = ""
            ownerToken = ""
            publish(message: "Removed local remote-sync credentials. Remote Hub devices were not revoked.")
        } catch {
            reload()
            publish(error)
        }
    }

    func clearInvalidLocalState() async {
        guard needsLocalCredentialRecovery, !isBusy else { return }
        isBusy = true
        defer { isBusy = false }
        clearStatus()

        do {
            try clearLocalState()
            resetConnectionState()
            needsLocalCredentialRecovery = false
            hubURLText = ""
            ownerToken = ""
            publish(message: "Cleared invalid local remote-sync credentials and cache.")
        } catch {
            reload()
            publish(error)
        }
    }
}

extension RemoteSyncSettingsViewModel {
    func hasEncryptionKey(for device: RemoteDeviceSummary) -> Bool {
        deviceIDsWithEncryptionKeys.contains(device.id)
    }
}

private extension RemoteSyncSettingsViewModel {
    func updateDevices(_ devices: [RemoteDeviceSummary]) {
        var keyDeviceIDs: Set<String> = []
        for device in devices where store.hasEncryptionKey(for: device.id) {
            keyDeviceIDs.insert(device.id)
        }
        self.devices = devices
        deviceIDsWithEncryptionKeys = keyDeviceIDs
    }

    func resetConnectionState() {
        isConnected = false
        connectedHost = nil
        devices = []
        deviceIDsWithEncryptionKeys = []
    }

    func upsertProvisionalDevice(_ device: CreateRemoteDeviceResponse) {
        devices.removeAll { $0.id == device.deviceID }
        devices.append(RemoteDeviceSummary(
            id: device.deviceID,
            name: device.deviceName,
            createdAt: Date(),
            lastSeenAt: nil,
            latestSequence: nil,
            syncIntervalSeconds: Int(syncIntervalMinutesText).map { $0 * 60 }
                ?? TokiSyncLimits.defaultSyncIntervalSeconds))
        devices.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    func revokeRemotelyIfPresent(
        deviceID: String,
        configuration: RemoteHubConfiguration) async throws {
        do {
            try await client.revokeDevice(id: deviceID, configuration: configuration)
        } catch let error as RemoteHubClientError {
            guard case .httpStatus(404) = error else { throw error }
        }
    }

    func performLocalStateChange(
        notifyingRemoteSyncChange: Bool = true,
        _ change: () throws -> Void) rethrows {
        defer {
            if notifyingRemoteSyncChange {
                onRemoteSyncChange()
            }
        }
        try lifecycleCoordinator.withInvalidatingMutation(change)
    }

    func clearLocalState() throws {
        try performLocalStateChange {
            try cache.clear()
            try anchorStore.clear()
            try store.clear()
        }
    }

    func clearStatus() {
        statusMessage = nil
        hasError = false
    }

    func publish(message: String) {
        statusMessage = message
        hasError = false
    }

    func publish(_ error: Error) {
        statusMessage = (error as? LocalizedError)?.errorDescription ?? "Remote sync failed."
        hasError = true
    }
}
