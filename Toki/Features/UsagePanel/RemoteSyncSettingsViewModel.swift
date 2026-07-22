import AppKit
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
    private let pairingBundleClipboard: PairingBundleClipboard
    private let onRemoteSyncChange: () -> Void

    init(
        store: any RemoteSyncConfigurationStoring = RemoteSyncConfigurationStore(),
        client: any RemoteHubClientProtocol = RemoteHubClient(),
        cache: any RemoteSnapshotCaching = RemoteSnapshotCache(),
        anchorStore: any RemoteSnapshotAnchorStoring = RemoteSnapshotAnchorStore(),
        lifecycleCoordinator: RemoteSyncLifecycleCoordinator = .shared,
        pairingBundleClipboard: PairingBundleClipboard? = nil,
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
            try lifecycleCoordinator.mutate {
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
            onRemoteSyncChange()
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
                let encryptionKey = SnapshotCipher.generateKey()
                try lifecycleCoordinator.mutate {
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
                    try lifecycleCoordinator.mutate {
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
            try lifecycleCoordinator.mutate {
                try anchorStore.copyAnchors(
                    from: currentConfiguration.snapshotCacheIdentifier,
                    to: updatedConfiguration.snapshotCacheIdentifier)
                try store.save(updatedConfiguration)
            }
            ownerToken = ""
            updateDevices(fetchedDevices)
            onRemoteSyncChange()
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
            try await client.revokeDevice(id: device.id, configuration: configuration)
            try lifecycleCoordinator.mutate {
                try anchorStore.remove(
                    deviceID: device.id,
                    originIdentifier: configuration.snapshotCacheIdentifier)
                try cache.remove(deviceID: device.id)
                try store.deleteEncryptionKey(for: device.id)
            }
            devices.removeAll { $0.id == device.id }
            deviceIDsWithEncryptionKeys.remove(device.id)
            onRemoteSyncChange()
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
            onRemoteSyncChange()
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
            onRemoteSyncChange()
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
            onRemoteSyncChange()
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
        try await client.revokeDevice(id: deviceID, configuration: configuration)
    }

    func clearLocalState() throws {
        try lifecycleCoordinator.mutate {
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

@MainActor
final class PairingBundleClipboard {
    private let pasteboard: NSPasteboard
    private let retentionNanoseconds: UInt64
    private var clearTask: Task<Void, Never>?
    private var copiedPasteboardChangeCount: Int?

    init(
        pasteboard: NSPasteboard = .general,
        retentionNanoseconds: UInt64 = 60 * 1_000_000_000) {
        self.pasteboard = pasteboard
        self.retentionNanoseconds = retentionNanoseconds
    }

    func copy(_ bundle: String) throws {
        clearTask?.cancel()
        clearIfUnchanged()
        pasteboard.declareTypes([.string, .tokiConcealed, .tokiTransient], owner: nil)
        guard pasteboard.setString(bundle, forType: .string) else {
            throw RemoteSyncSettingsError.clipboardWriteFailed
        }
        _ = pasteboard.setData(Data(), forType: .tokiConcealed)
        _ = pasteboard.setData(Data(), forType: .tokiTransient)
        let expectedChangeCount = pasteboard.changeCount
        copiedPasteboardChangeCount = expectedChangeCount
        let pasteboard = pasteboard
        let retentionNanoseconds = retentionNanoseconds
        clearTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: retentionNanoseconds)
            guard !Task.isCancelled else { return }
            self?.copiedPasteboardChangeCount = nil
            guard pasteboard.changeCount == expectedChangeCount else { return }
            pasteboard.clearContents()
        }
    }

    private func clearIfUnchanged() {
        defer { copiedPasteboardChangeCount = nil }
        guard let expectedChangeCount = copiedPasteboardChangeCount,
              pasteboard.changeCount == expectedChangeCount else {
            return
        }
        pasteboard.clearContents()
    }
}

private extension NSPasteboard.PasteboardType {
    static let tokiConcealed = Self("org.nspasteboard.ConcealedType")
    static let tokiTransient = Self("org.nspasteboard.TransientType")
}
