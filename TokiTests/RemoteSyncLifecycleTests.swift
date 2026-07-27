import AppKit
import Foundation
import TokiSyncProtocol
import TokiUsageCore
import XCTest
@testable import Toki

final class RemoteSyncLifecycleTests: XCTestCase {
    func test_oldReadTicketIsRejectedAfterStateChange() throws {
        let coordinator = RemoteSyncLifecycleCoordinator()
        let ticket = coordinator.beginRead()

        coordinator.invalidateReadTickets()

        XCTAssertThrowsError(try coordinator.validate(ticket)) { error in
            guard let lifecycleError = error as? RemoteSyncLifecycleError,
                  case .stateChanged = lifecycleError else {
                return XCTFail("Expected stateChanged, got \(error)")
            }
        }
    }

    func test_callerCanReenterLifecycleAfterInvalidatingReadTickets() throws {
        let coordinator = RemoteSyncLifecycleCoordinator()

        coordinator.invalidateReadTickets()
        let ticket = coordinator.beginRead()

        XCTAssertNoThrow(try coordinator.validate(ticket))
    }

    @MainActor
    func test_connectInvalidatesExistingReadTicketAfterSavingConfiguration() async throws {
        let fixture = try makeFixture()
        let coordinator = RemoteSyncLifecycleCoordinator()
        let viewModel = RemoteSyncSettingsViewModel(
            store: InMemoryRemoteSyncConfigurationStore(configuration: nil),
            client: StubRemoteHubClient(devicesResult: .success([])),
            cache: InMemoryRemoteSnapshotCache(),
            anchorStore: InMemoryRemoteSnapshotAnchorStore(),
            lifecycleCoordinator: coordinator)
        viewModel.hubURLText = fixture.configuration.hubURL.absoluteString
        viewModel.ownerToken = fixture.configuration.ownerToken
        let ticket = coordinator.beginRead()

        await viewModel.connect()

        XCTAssertThrowsError(try coordinator.validate(ticket)) { error in
            guard let lifecycleError = error as? RemoteSyncLifecycleError,
                  case .stateChanged = lifecycleError else {
                return XCTFail("Expected stateChanged, got \(error)")
            }
        }
        XCTAssertFalse(viewModel.hasError)
    }
}

extension RemoteSyncLifecycleTests {
    @MainActor
    func test_pairingQueuesReplacementRefreshAfterInvalidatingActiveRead() async throws {
        let fixture = try makeFixture()
        let coordinator = RemoteSyncLifecycleCoordinator()
        let gate = AsyncTestGate()
        let client = GatedRemoteHubClient(
            gate: gate,
            createDeviceResponse: CreateRemoteDeviceResponse(
                deviceID: "paired-device",
                deviceName: "paired-agent",
                uploadToken: String(repeating: "u", count: 32)))
        let store = ObservingRemoteSyncConfigurationStore(
            configuration: fixture.configuration,
            encryptionKeys: [fixture.device.id: fixture.encryptionKey])
        let reader = RemoteUsageReader(
            configurationProvider: store,
            client: client,
            cache: InMemoryRemoteSnapshotCache(),
            anchorStore: InMemoryRemoteSnapshotAnchorStore(),
            lifecycleCoordinator: coordinator)
        var remoteSyncChangeCount = 0
        let pasteboard = PairingBundlePasteboardSpy()
        let viewModel = RemoteSyncSettingsViewModel(
            store: store,
            client: client,
            cache: InMemoryRemoteSnapshotCache(),
            anchorStore: InMemoryRemoteSnapshotAnchorStore(),
            lifecycleCoordinator: coordinator,
            pairingBundleClipboard: PairingBundleClipboard(pasteboard: pasteboard),
            onRemoteSyncChange: { remoteSyncChangeCount += 1 })
        viewModel.deviceName = "paired-agent"
        viewModel.retentionDaysText = "30"
        viewModel.syncIntervalMinutesText = "15"
        let refreshTask = Task {
            try await reader.readUsage(from: fixture.start, to: fixture.end)
        }
        defer { Task { await gate.release() } }

        await gate.waitUntilBlocked()
        await viewModel.createPairingBundle()

        XCTAssertEqual(remoteSyncChangeCount, 1)
        XCTAssertTrue(store.hasEncryptionKey(for: "paired-device"))
        await gate.release()
        await assertLifecycleChanged(refreshTask)
        XCTAssertFalse(viewModel.hasError)
    }

    @MainActor
    func test_pairingDoesNotQueueReplacementRefreshWhenClipboardWriteFails() async throws {
        let fixture = try makeFixture()
        let client = GatedRemoteHubClient(
            gate: AsyncTestGate(),
            createDeviceResponse: CreateRemoteDeviceResponse(
                deviceID: "paired-device",
                deviceName: "paired-agent",
                uploadToken: String(repeating: "u", count: 32)))
        let store = ObservingRemoteSyncConfigurationStore(
            configuration: fixture.configuration,
            encryptionKeys: [:])
        var remoteSyncChangeCount = 0
        let pasteboard = PairingBundlePasteboardSpy(privacyMarkersSucceed: false)
        let viewModel = RemoteSyncSettingsViewModel(
            store: store,
            client: client,
            cache: InMemoryRemoteSnapshotCache(),
            anchorStore: InMemoryRemoteSnapshotAnchorStore(),
            pairingBundleClipboard: PairingBundleClipboard(pasteboard: pasteboard),
            onRemoteSyncChange: { remoteSyncChangeCount += 1 })
        viewModel.deviceName = "paired-agent"
        viewModel.retentionDaysText = "30"
        viewModel.syncIntervalMinutesText = "15"

        await viewModel.createPairingBundle()

        XCTAssertEqual(remoteSyncChangeCount, 0)
        XCTAssertFalse(store.hasEncryptionKey(for: "paired-device"))
        XCTAssertTrue(viewModel.hasError)
    }

    @MainActor
    func test_disconnectInvalidatesReadTicketBeforeClearingLocalState() async throws {
        let fixture = try makeFixture()
        let coordinator = RemoteSyncLifecycleCoordinator()
        let ticket = coordinator.beginRead()
        var observedInvalidatedTicket = false
        let store = ObservingRemoteSyncConfigurationStore(
            configuration: fixture.configuration,
            encryptionKeys: [fixture.device.id: fixture.encryptionKey],
            willClear: {
                do {
                    try coordinator.validate(ticket)
                    XCTFail("Expected the read ticket to be invalid before local cleanup")
                } catch {
                    observedInvalidatedTicket = true
                }
            })
        let viewModel = RemoteSyncSettingsViewModel(
            store: store,
            client: StubRemoteHubClient(devicesResult: .success([])),
            cache: InMemoryRemoteSnapshotCache(entry: fixture.cacheEntry),
            anchorStore: InMemoryRemoteSnapshotAnchorStore(envelopes: [fixture.envelope]),
            lifecycleCoordinator: coordinator)

        await viewModel.disconnect()

        XCTAssertTrue(observedInvalidatedTicket)
        XCTAssertFalse(viewModel.hasError)
    }

    @MainActor
    func test_revokePreventsBlockedRefreshFromRestoringDeviceState() async throws {
        let fixture = try makeFixture()
        let coordinator = RemoteSyncLifecycleCoordinator()
        let store = ObservingRemoteSyncConfigurationStore(
            configuration: fixture.configuration,
            encryptionKeys: [fixture.device.id: fixture.encryptionKey])
        let cache = InMemoryRemoteSnapshotCache()
        let anchorStore = InMemoryRemoteSnapshotAnchorStore(envelopes: [fixture.envelope])
        let gate = AsyncTestGate()
        let client = GatedRemoteHubClient(gate: gate)
        let reader = RemoteUsageReader(
            configurationProvider: store,
            client: client,
            cache: cache,
            anchorStore: anchorStore,
            lifecycleCoordinator: coordinator)
        let viewModel = RemoteSyncSettingsViewModel(
            store: store,
            client: client,
            cache: cache,
            anchorStore: anchorStore,
            lifecycleCoordinator: coordinator)
        let refreshTask = Task {
            try await reader.readUsage(from: fixture.start, to: fixture.end)
        }
        defer { Task { await gate.release() } }

        await gate.waitUntilBlocked()
        await viewModel.revoke(fixture.device)
        await gate.release()

        await assertLifecycleChanged(refreshTask)
        XCTAssertNil(try cache.load())
        XCTAssertEqual(anchorStore.removedDeviceIDs, [fixture.device.id])
        XCTAssertFalse(store.hasEncryptionKey(for: fixture.device.id))
    }

    @MainActor
    func test_disconnectPreventsBlockedRefreshFromRestoringClearedState() async throws {
        let fixture = try makeFixture()
        let coordinator = RemoteSyncLifecycleCoordinator()
        let store = ObservingRemoteSyncConfigurationStore(
            configuration: fixture.configuration,
            encryptionKeys: [fixture.device.id: fixture.encryptionKey])
        let cache = InMemoryRemoteSnapshotCache()
        let anchorStore = InMemoryRemoteSnapshotAnchorStore(envelopes: [fixture.envelope])
        let gate = AsyncTestGate()
        let client = GatedRemoteHubClient(gate: gate)
        let reader = RemoteUsageReader(
            configurationProvider: store,
            client: client,
            cache: cache,
            anchorStore: anchorStore,
            lifecycleCoordinator: coordinator)
        let viewModel = RemoteSyncSettingsViewModel(
            store: store,
            client: client,
            cache: cache,
            anchorStore: anchorStore,
            lifecycleCoordinator: coordinator)
        let refreshTask = Task {
            try await reader.readUsage(from: fixture.start, to: fixture.end)
        }
        defer { Task { await gate.release() } }

        await gate.waitUntilBlocked()
        await viewModel.disconnect()
        await gate.release()

        await assertLifecycleChanged(refreshTask)
        XCTAssertNil(try cache.load())
        XCTAssertNil(try store.load())
        XCTAssertEqual(anchorStore.clearCallCount, 1)
        XCTAssertFalse(store.hasEncryptionKey(for: fixture.device.id))
    }
}

private extension RemoteSyncLifecycleTests {
    struct Fixture {
        let configuration: RemoteHubConfiguration
        let device: RemoteDeviceSummary
        let envelope: EncryptedUsageEnvelope
        let encryptionKey: String
        let start: Date
        let end: Date

        var cacheEntry: RemoteSnapshotCacheEntry {
            RemoteSnapshotCacheEntry(
                envelopes: [envelope],
                manifest: [device],
                snapshotCacheIdentifier: configuration.snapshotCacheIdentifier)
        }
    }

    func makeFixture() throws -> Fixture {
        let start = Date(timeIntervalSince1970: 1_750_000_000)
        let end = start.addingTimeInterval(3600)
        let encryptionKey = SnapshotCipher.generateKey()
        let configuration = try RemoteHubConfiguration(
            hubURL: XCTUnwrap(URL(string: "https://hub.example.test")),
            ownerToken: String(repeating: "o", count: 32))
        let snapshot = RemoteUsageSnapshot(
            device: RemoteDeviceDescriptor(id: "device-1", name: "build-server", platform: "linux"),
            generatedAt: start.addingTimeInterval(120),
            coveredFrom: start,
            coveredTo: end,
            tokenEvents: [],
            activityEvents: [])
        let envelope = try SnapshotCipher.seal(snapshot, sequence: 1, key: encryptionKey)
        let device = RemoteDeviceSummary(
            id: envelope.deviceID,
            name: "build-server",
            createdAt: start,
            lastSeenAt: Date(),
            latestSequence: envelope.sequence)
        return Fixture(
            configuration: configuration,
            device: device,
            envelope: envelope,
            encryptionKey: encryptionKey,
            start: start,
            end: end)
    }

    @MainActor
    func assertLifecycleChanged(
        _ task: Task<RawTokenUsage, Error>,
        file: StaticString = #filePath,
        line: UInt = #line) async {
        do {
            _ = try await task.value
            XCTFail("Expected stale refresh to fail", file: file, line: line)
        } catch {
            guard let lifecycleError = error as? RemoteSyncLifecycleError,
                  case .stateChanged = lifecycleError else {
                return XCTFail("Expected stateChanged, got \(error)", file: file, line: line)
            }
        }
    }
}

private final class ObservingRemoteSyncConfigurationStore: RemoteSyncConfigurationStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var configuration: RemoteHubConfiguration?
    private var encryptionKeys: [String: String]
    private let willClear: (() -> Void)?

    init(
        configuration: RemoteHubConfiguration?,
        encryptionKeys: [String: String],
        willClear: (() -> Void)? = nil) {
        self.configuration = configuration
        self.encryptionKeys = encryptionKeys
        self.willClear = willClear
    }

    func load() throws -> RemoteHubConfiguration? {
        withLock { configuration }
    }

    func save(_ configuration: RemoteHubConfiguration) throws {
        withLock { self.configuration = configuration }
    }

    func encryptionKey(for deviceID: String) throws -> String? {
        withLock { encryptionKeys[deviceID] }
    }

    func saveEncryptionKey(_ encryptionKey: String, for deviceID: String) throws {
        withLock { encryptionKeys[deviceID] = encryptionKey }
    }

    func deleteEncryptionKey(for deviceID: String) throws {
        _ = withLock { encryptionKeys.removeValue(forKey: deviceID) }
    }

    func hasEncryptionKey(for deviceID: String) -> Bool {
        withLock { encryptionKeys[deviceID] != nil }
    }

    func clear() throws {
        willClear?()
        withLock {
            configuration = nil
            encryptionKeys = [:]
        }
    }

    private func withLock<Value>(_ operation: () -> Value) -> Value {
        lock.lock()
        defer { lock.unlock() }
        return operation()
    }
}

private actor AsyncTestGate {
    private var isOpen = false
    private var isBlocked = false
    private var blockedContinuation: CheckedContinuation<Void, Never>?
    private var entryContinuations: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        await withTaskCancellationHandler {
            guard !isOpen else { return }
            isBlocked = true
            let waitingForEntry = entryContinuations
            entryContinuations = []
            waitingForEntry.forEach { $0.resume() }
            await withCheckedContinuation { continuation in
                blockedContinuation = continuation
            }
        } onCancel: {
            Task { await self.release() }
        }
    }

    func waitUntilBlocked() async {
        guard !isBlocked else { return }
        await withCheckedContinuation { continuation in
            entryContinuations.append(continuation)
        }
    }

    func release() {
        guard !isOpen else { return }
        isOpen = true
        blockedContinuation?.resume()
        blockedContinuation = nil
        let waitingForEntry = entryContinuations
        entryContinuations = []
        waitingForEntry.forEach { $0.resume() }
    }
}

private final class GatedRemoteHubClient: RemoteHubClientProtocol {
    private let gate: AsyncTestGate
    private let createDeviceResponse: CreateRemoteDeviceResponse?

    init(gate: AsyncTestGate, createDeviceResponse: CreateRemoteDeviceResponse? = nil) {
        self.gate = gate
        self.createDeviceResponse = createDeviceResponse
    }

    func fetchSnapshotManifest(
        configuration _: RemoteHubConfiguration,
        ifNoneMatch _: String?) async throws -> RemoteConditionalResult<[RemoteDeviceSummary]> {
        await gate.wait()
        return .modified([], entityTag: "gated-manifest")
    }

    func fetchSnapshot(
        configuration _: RemoteHubConfiguration,
        deviceID _: String) async throws -> EncryptedUsageEnvelope {
        throw TestError.unexpectedCall
    }

    func createDevice(
        name _: String,
        syncIntervalSeconds _: Int,
        configuration _: RemoteHubConfiguration) async throws -> CreateRemoteDeviceResponse {
        guard let createDeviceResponse else { throw TestError.unexpectedCall }
        return createDeviceResponse
    }

    func fetchDevices(configuration _: RemoteHubConfiguration) async throws -> [RemoteDeviceSummary] {
        []
    }

    func revokeDevice(id _: String, configuration _: RemoteHubConfiguration) async throws {}
}

@MainActor
private final class PairingBundlePasteboardSpy: PairingBundlePasteboard {
    private(set) var changeCount = 0
    private var values: [NSPasteboard.PasteboardType: String] = [:]
    private let privacyMarkersSucceed: Bool

    init(privacyMarkersSucceed: Bool = true) {
        self.privacyMarkersSucceed = privacyMarkersSucceed
    }

    func prepareForPairingBundle() {
        values = [:]
        changeCount += 1
    }

    func setPairingBundle(_ bundle: String) -> Bool {
        values[.string] = bundle
        changeCount += 1
        return true
    }

    func setPrivacyMarker(_ type: NSPasteboard.PasteboardType) -> Bool {
        guard privacyMarkersSucceed else { return false }
        values[type] = ""
        changeCount += 1
        return true
    }

    func clearPairingBundle() {
        values = [:]
        changeCount += 1
    }
}
