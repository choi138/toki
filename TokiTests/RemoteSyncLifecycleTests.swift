import Foundation
import TokiSyncProtocol
import TokiUsageCore
import XCTest
@testable import Toki

final class RemoteSyncLifecycleTests: XCTestCase {
    func test_oldReadTicketCannotCommitAfterMutation() throws {
        let coordinator = RemoteSyncLifecycleCoordinator()
        let ticket = coordinator.beginRead()
        var didCommit = false

        try coordinator.mutate {}

        XCTAssertThrowsError(try coordinator.commit(ticket) {
            didCommit = true
        }) { error in
            guard let lifecycleError = error as? RemoteSyncLifecycleError,
                  case .stateChanged = lifecycleError else {
                return XCTFail("Expected stateChanged, got \(error)")
            }
        }
        XCTAssertFalse(didCommit)
    }

    @MainActor
    func test_revokePreventsBlockedRefreshFromRestoringDeviceState() async throws {
        let fixture = try makeFixture()
        let coordinator = RemoteSyncLifecycleCoordinator()
        let store = BlockingRemoteSyncConfigurationStore(
            configuration: fixture.configuration,
            encryptionKeys: [fixture.device.id: fixture.encryptionKey])
        let cache = InMemoryRemoteSnapshotCache(entry: fixture.cacheEntry)
        let anchorStore = InMemoryRemoteSnapshotAnchorStore(envelopes: [fixture.envelope])
        let client = StubRemoteHubClient(devicesResult: .success([]))
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
        defer { store.resumeEncryptionKeyRead() }

        let didStartEncryptionKeyRead = await store.waitForEncryptionKeyRead()
        XCTAssertTrue(didStartEncryptionKeyRead)
        await viewModel.revoke(fixture.device)
        store.resumeEncryptionKeyRead()

        await assertLifecycleChanged(refreshTask)
        XCTAssertNil(try cache.load())
        XCTAssertEqual(anchorStore.removedDeviceIDs, [fixture.device.id])
        XCTAssertFalse(store.hasEncryptionKey(for: fixture.device.id))
    }

    @MainActor
    func test_disconnectPreventsBlockedRefreshFromRestoringClearedState() async throws {
        let fixture = try makeFixture()
        let coordinator = RemoteSyncLifecycleCoordinator()
        let store = BlockingRemoteSyncConfigurationStore(
            configuration: fixture.configuration,
            encryptionKeys: [fixture.device.id: fixture.encryptionKey])
        let cache = InMemoryRemoteSnapshotCache(entry: fixture.cacheEntry)
        let anchorStore = InMemoryRemoteSnapshotAnchorStore(envelopes: [fixture.envelope])
        let client = StubRemoteHubClient(devicesResult: .success([]))
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
        defer { store.resumeEncryptionKeyRead() }

        let didStartEncryptionKeyRead = await store.waitForEncryptionKeyRead()
        XCTAssertTrue(didStartEncryptionKeyRead)
        await viewModel.disconnect()
        store.resumeEncryptionKeyRead()

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

private final class BlockingRemoteSyncConfigurationStore: RemoteSyncConfigurationStoring, @unchecked Sendable {
    private let lock = NSLock()
    private let encryptionKeyReadResume = DispatchSemaphore(value: 0)
    private var configuration: RemoteHubConfiguration?
    private var encryptionKeys: [String: String]
    private var shouldBlockEncryptionKeyRead = true
    private var didStartEncryptionKeyRead = false

    init(configuration: RemoteHubConfiguration?, encryptionKeys: [String: String]) {
        self.configuration = configuration
        self.encryptionKeys = encryptionKeys
    }

    func load() throws -> RemoteHubConfiguration? {
        withLock { configuration }
    }

    func save(_ configuration: RemoteHubConfiguration) throws {
        withLock { self.configuration = configuration }
    }

    func encryptionKey(for deviceID: String) throws -> String? {
        let (value, shouldBlock) = withLock {
            let shouldBlock = shouldBlockEncryptionKeyRead
            shouldBlockEncryptionKeyRead = false
            didStartEncryptionKeyRead = shouldBlock
            return (encryptionKeys[deviceID], shouldBlock)
        }
        if shouldBlock {
            encryptionKeyReadResume.wait()
        }
        return value
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
        withLock {
            configuration = nil
            encryptionKeys = [:]
        }
    }

    func waitForEncryptionKeyRead() async -> Bool {
        for _ in 0..<200 {
            if withLock({ didStartEncryptionKeyRead }) {
                return true
            }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        return withLock { didStartEncryptionKeyRead }
    }

    func resumeEncryptionKeyRead() {
        encryptionKeyReadResume.signal()
    }

    private func withLock<Value>(_ operation: () -> Value) -> Value {
        lock.lock()
        defer { lock.unlock() }
        return operation()
    }
}
