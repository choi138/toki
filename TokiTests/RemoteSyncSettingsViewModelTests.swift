import Foundation
import XCTest
@testable import Toki

extension RemoteUsageReaderTests {
    @MainActor
    func test_connectClearsDisconnectedLocalStateBeforeSavingHubConfiguration() async throws {
        let fixture = try makeFixture()
        let store = InMemoryRemoteSyncConfigurationStore(configuration: nil)
        try store.saveEncryptionKey(fixture.encryptionKey, for: fixture.envelope.deviceID)
        let cache = InMemoryRemoteSnapshotCache(entry: fixture.cacheEntry())
        let anchorStore = InMemoryRemoteSnapshotAnchorStore(envelopes: [fixture.envelope])
        var remoteSyncChangeCount = 0
        let viewModel = RemoteSyncSettingsViewModel(
            store: store,
            client: StubRemoteHubClient(devicesResult: .success([])),
            cache: cache,
            anchorStore: anchorStore,
            onRemoteSyncChange: { remoteSyncChangeCount += 1 })
        viewModel.hubURLText = fixture.configuration.hubURL.absoluteString
        viewModel.ownerToken = fixture.configuration.ownerToken

        await viewModel.connect()

        XCTAssertEqual(try store.load(), fixture.configuration)
        XCTAssertEqual(store.clearCallCount, 1)
        XCTAssertNil(try cache.load())
        XCTAssertEqual(anchorStore.clearCallCount, 1)
        XCTAssertFalse(store.hasEncryptionKey(for: fixture.envelope.deviceID))
        XCTAssertTrue(viewModel.isConnected)
        XCTAssertFalse(viewModel.hasError)
        XCTAssertEqual(remoteSyncChangeCount, 1)
    }

    @MainActor
    func test_connectPreservesReplayStateWhenCredentialClearFails() async throws {
        let fixture = try makeFixture()
        let store = ClearFailingRemoteSyncConfigurationStore(
            configuration: nil,
            encryptionKeys: [fixture.envelope.deviceID: fixture.encryptionKey])
        let cacheEntry = fixture.cacheEntry()
        let cache = InMemoryRemoteSnapshotCache(entry: cacheEntry)
        let anchorStore = InMemoryRemoteSnapshotAnchorStore(envelopes: [fixture.envelope])
        let viewModel = RemoteSyncSettingsViewModel(
            store: store,
            client: StubRemoteHubClient(devicesResult: .success([])),
            cache: cache,
            anchorStore: anchorStore)
        viewModel.hubURLText = fixture.configuration.hubURL.absoluteString
        viewModel.ownerToken = fixture.configuration.ownerToken

        await viewModel.connect()

        XCTAssertEqual(store.clearCallCount, 1)
        XCTAssertNil(try store.load())
        XCTAssertTrue(store.hasEncryptionKey(for: fixture.envelope.deviceID))
        XCTAssertEqual(try cache.load(), cacheEntry)
        XCTAssertEqual(cache.clearCallCount, 0)
        XCTAssertEqual(anchorStore.clearCallCount, 0)
        XCTAssertFalse(viewModel.isConnected)
        XCTAssertTrue(viewModel.hasError)
    }

    @MainActor
    func test_disconnectFetchesDevicesBeforeClearingCredentials() async throws {
        let fixture = try makeFixture()
        let device = fixture.device()
        let store = InMemoryRemoteSyncConfigurationStore(configuration: fixture.configuration)
        let anchorStore = InMemoryRemoteSnapshotAnchorStore()
        let viewModel = RemoteSyncSettingsViewModel(
            store: store,
            client: StubRemoteHubClient(devicesResult: .success([device])),
            cache: InMemoryRemoteSnapshotCache(),
            anchorStore: anchorStore)

        await viewModel.disconnect()

        XCTAssertEqual(store.clearCallCount, 0)
        XCTAssertEqual(anchorStore.clearCallCount, 0)
        XCTAssertTrue(viewModel.isConnected)
        XCTAssertEqual(viewModel.devices, [device])
        XCTAssertTrue(viewModel.hasError)
    }

    @MainActor
    func test_disconnectClearsCredentialsAndReplayAnchorsAfterHubConfirmsNoDevices() async throws {
        let fixture = try makeFixture()
        let store = InMemoryRemoteSyncConfigurationStore(configuration: fixture.configuration)
        let anchorStore = InMemoryRemoteSnapshotAnchorStore(envelopes: [fixture.envelope])
        var remoteSyncChangeCount = 0
        let viewModel = RemoteSyncSettingsViewModel(
            store: store,
            client: StubRemoteHubClient(devicesResult: .success([])),
            cache: InMemoryRemoteSnapshotCache(),
            anchorStore: anchorStore,
            onRemoteSyncChange: { remoteSyncChangeCount += 1 })

        await viewModel.disconnect()

        XCTAssertEqual(store.clearCallCount, 1)
        XCTAssertEqual(anchorStore.clearCallCount, 1)
        XCTAssertFalse(viewModel.isConnected)
        XCTAssertFalse(viewModel.hasError)
        XCTAssertEqual(remoteSyncChangeCount, 1)
    }

    @MainActor
    func test_disconnectPreservesReplayStateWhenCredentialClearFails() async throws {
        let fixture = try makeFixture()
        let store = ClearFailingRemoteSyncConfigurationStore(
            configuration: fixture.configuration,
            encryptionKeys: [fixture.envelope.deviceID: fixture.encryptionKey])
        let cacheEntry = fixture.cacheEntry()
        let cache = InMemoryRemoteSnapshotCache(entry: cacheEntry)
        let anchorStore = InMemoryRemoteSnapshotAnchorStore(envelopes: [fixture.envelope])
        let viewModel = RemoteSyncSettingsViewModel(
            store: store,
            client: StubRemoteHubClient(devicesResult: .success([])),
            cache: cache,
            anchorStore: anchorStore)

        await viewModel.disconnect()

        XCTAssertEqual(store.clearCallCount, 1)
        XCTAssertEqual(try store.load(), fixture.configuration)
        XCTAssertTrue(store.hasEncryptionKey(for: fixture.envelope.deviceID))
        XCTAssertEqual(try cache.load(), cacheEntry)
        XCTAssertEqual(cache.clearCallCount, 0)
        XCTAssertEqual(anchorStore.clearCallCount, 0)
        XCTAssertTrue(viewModel.isConnected)
        XCTAssertTrue(viewModel.hasError)
    }

    @MainActor
    func test_disconnectReloadsConnectionStateWhenPostCredentialCleanupFails() async throws {
        let fixture = try makeFixture()
        let store = InMemoryRemoteSyncConfigurationStore(configuration: fixture.configuration)
        let cache = InMemoryRemoteSnapshotCache(
            entry: fixture.cacheEntry(),
            clearError: TestError.temporaryCacheFailure)
        let anchorStore = InMemoryRemoteSnapshotAnchorStore(envelopes: [fixture.envelope])
        let viewModel = RemoteSyncSettingsViewModel(
            store: store,
            client: StubRemoteHubClient(devicesResult: .success([])),
            cache: cache,
            anchorStore: anchorStore)

        await viewModel.disconnect()

        XCTAssertNil(try store.load())
        XCTAssertEqual(cache.clearCallCount, 1)
        XCTAssertEqual(anchorStore.clearCallCount, 0)
        XCTAssertFalse(viewModel.isConnected)
        XCTAssertNil(viewModel.connectedHost)
        XCTAssertTrue(viewModel.hasError)
    }

    @MainActor
    func test_revokeRemovesOnlyThatDevicesReplayAnchor() async throws {
        let fixture = try makeFixture()
        let device = fixture.device()
        let store = InMemoryRemoteSyncConfigurationStore(configuration: fixture.configuration)
        try store.saveEncryptionKey(fixture.encryptionKey, for: device.id)
        let anchorStore = InMemoryRemoteSnapshotAnchorStore(envelopes: [fixture.envelope])
        let client = StubRemoteHubClient(devicesResult: .success([]))
        var remoteSyncChangeCount = 0
        let viewModel = RemoteSyncSettingsViewModel(
            store: store,
            client: client,
            cache: InMemoryRemoteSnapshotCache(entry: fixture.cacheEntry()),
            anchorStore: anchorStore,
            onRemoteSyncChange: { remoteSyncChangeCount += 1 })

        await viewModel.revoke(device)

        XCTAssertEqual(anchorStore.removedDeviceIDs, [device.id])
        XCTAssertEqual(client.revokedDeviceIDs, [device.id])
        XCTAssertFalse(store.hasEncryptionKey(for: device.id))
        XCTAssertFalse(viewModel.hasError)
        XCTAssertEqual(remoteSyncChangeCount, 1)
    }

    @MainActor
    func test_refreshDevicesCachesKeyAvailabilityAndClearsPreviousError() async throws {
        let fixture = try makeFixture()
        let device = fixture.device()
        let store = InMemoryRemoteSyncConfigurationStore(configuration: fixture.configuration)
        try store.saveEncryptionKey(fixture.encryptionKey, for: device.id)
        let client = StubRemoteHubClient(devicesResults: [
            .failure(TestError.temporaryCredentialFailure),
            .success([device]),
        ])
        let viewModel = RemoteSyncSettingsViewModel(
            store: store,
            client: client,
            cache: InMemoryRemoteSnapshotCache(),
            anchorStore: InMemoryRemoteSnapshotAnchorStore())

        await viewModel.refreshDevices()
        XCTAssertTrue(viewModel.hasError)

        await viewModel.refreshDevices()

        XCTAssertEqual(viewModel.devices, [device])
        XCTAssertFalse(viewModel.hasError)
        XCTAssertNil(viewModel.statusMessage)
        let keyReadCount = store.hasEncryptionKeyCallCount
        XCTAssertTrue(viewModel.hasEncryptionKey(for: device))
        XCTAssertTrue(viewModel.hasEncryptionKey(for: device))
        XCTAssertEqual(store.hasEncryptionKeyCallCount, keyReadCount)
    }

    @MainActor
    func test_invalidStoredCredentialsCanBeClearedWithoutHubAccess() async throws {
        let fixture = try makeFixture()
        let store = InMemoryRemoteSyncConfigurationStore(
            configuration: nil,
            loadError: TestError.temporaryCredentialFailure)
        let cache = InMemoryRemoteSnapshotCache(entry: fixture.cacheEntry())
        let anchorStore = InMemoryRemoteSnapshotAnchorStore(envelopes: [fixture.envelope])
        var remoteSyncChangeCount = 0
        let viewModel = RemoteSyncSettingsViewModel(
            store: store,
            client: StubRemoteHubClient(),
            cache: cache,
            anchorStore: anchorStore,
            onRemoteSyncChange: { remoteSyncChangeCount += 1 })

        XCTAssertTrue(viewModel.needsLocalCredentialRecovery)
        XCTAssertTrue(viewModel.hasError)

        await viewModel.clearInvalidLocalState()

        XCTAssertNil(try store.load())
        XCTAssertEqual(store.clearCallCount, 1)
        XCTAssertNil(try cache.load())
        XCTAssertEqual(anchorStore.clearCallCount, 1)
        XCTAssertFalse(viewModel.needsLocalCredentialRecovery)
        XCTAssertFalse(viewModel.hasError)
        XCTAssertEqual(remoteSyncChangeCount, 1)
    }
}
