import Foundation
import TokiSyncProtocol
import XCTest
@testable import Toki

extension RemoteUsageReaderTests {
    func test_unchangedManifestSkipsCiphertextDownload() async throws {
        let fixture = try makeFixture()
        let manifestTag = entityTag("a")
        let entry = fixture.cacheEntry(
            fetchedAt: Date().addingTimeInterval(-60),
            manifestEntityTag: manifestTag)
        let cache = InMemoryRemoteSnapshotCache(entry: entry)
        let client = StubRemoteHubClient(
            manifestResult: .success(.notModified(entityTag: manifestTag)))
        let reader = fixture.makeReader(client: client, cache: cache)

        let usage = try await reader.readUsage(from: fixture.start, to: fixture.end)

        XCTAssertEqual(usage.totalTokens, 16)
        XCTAssertEqual(client.fetchManifestCallCount, 1)
        XCTAssertEqual(client.fetchSnapshotCallCount, 0)
        XCTAssertEqual(client.lastManifestEntityTag, manifestTag)
    }

    func test_concurrentReadsShareOneHubFetch() async throws {
        let fixture = try makeFixture()
        let client = fixture.makeClient(delayNanoseconds: 100_000_000)
        let reader = fixture.makeReader(client: client)

        async let first = reader.readUsage(from: fixture.start, to: fixture.end)
        async let second = reader.readUsage(from: fixture.start, to: fixture.end)
        let usages = try await [first, second]

        XCTAssertEqual(usages.map(\.totalTokens), [16, 16])
        XCTAssertEqual(client.fetchManifestCallCount, 1)
        XCTAssertEqual(client.fetchSnapshotCallCount, 1)
    }

    func test_repeatedReadsReuseAuthenticatedInMemorySnapshots() async throws {
        let fixture = try makeFixture()
        let cache = InMemoryRemoteSnapshotCache()
        let client = fixture.makeClient()
        let reader = fixture.makeReader(client: client, cache: cache)

        _ = try await reader.readUsage(from: fixture.start, to: fixture.end)
        _ = try await reader.readUsage(from: fixture.start, to: fixture.end)

        XCTAssertEqual(cache.loadCallCount, 1)
        XCTAssertEqual(client.fetchManifestCallCount, 1)
        XCTAssertEqual(client.fetchSnapshotCallCount, 1)
    }

    func test_changedManifestFetchesOnlyChangedDeviceEnvelope() async throws {
        let fixture = try makeFixture()
        let originalSnapshot = try SnapshotCipher.open(fixture.envelope, key: fixture.encryptionKey)
        let secondKey = SnapshotCipher.generateKey()
        let secondSnapshot = RemoteUsageSnapshot(
            device: RemoteDeviceDescriptor(id: "device-2", name: "worker-2", platform: "linux"),
            generatedAt: originalSnapshot.generatedAt,
            coveredFrom: originalSnapshot.coveredFrom,
            coveredTo: originalSnapshot.coveredTo,
            tokenEvents: originalSnapshot.tokenEvents,
            activityEvents: originalSnapshot.activityEvents)
        let cachedSecondEnvelope = try SnapshotCipher.seal(secondSnapshot, sequence: 1, key: secondKey)
        let changedSecondEnvelope = try SnapshotCipher.seal(secondSnapshot, sequence: 2, key: secondKey)
        let firstDevice = fixture.device(sequence: 1)
        let cachedSecondDevice = RemoteDeviceSummary(
            id: "device-2",
            name: "worker-2",
            createdAt: fixture.start,
            lastSeenAt: Date(),
            latestSequence: 1)
        let changedSecondDevice = RemoteDeviceSummary(
            id: "device-2",
            name: "worker-2",
            createdAt: fixture.start,
            lastSeenAt: Date(),
            latestSequence: 2)
        let cache = InMemoryRemoteSnapshotCache(entry: RemoteSnapshotCacheEntry(
            envelopes: [fixture.envelope, cachedSecondEnvelope],
            manifest: [firstDevice, cachedSecondDevice],
            manifestEntityTag: entityTag("a"),
            fetchedAt: Date().addingTimeInterval(-60),
            snapshotCacheIdentifier: fixture.configuration.snapshotCacheIdentifier))
        let client = StubRemoteHubClient(
            manifestResult: .success(.modified(
                [firstDevice, changedSecondDevice],
                entityTag: entityTag("b"))),
            snapshotResult: .success([changedSecondEnvelope]))
        let provider = StubRemoteConfigurationProvider(
            configuration: fixture.configuration,
            encryptionKeys: [
                fixture.envelope.deviceID: fixture.encryptionKey,
                changedSecondEnvelope.deviceID: secondKey,
            ])
        let reader = RemoteUsageReader(
            configurationProvider: provider,
            client: client,
            cache: cache,
            anchorStore: InMemoryRemoteSnapshotAnchorStore())

        let usage = try await reader.readUsage(from: fixture.start, to: fixture.end)

        XCTAssertEqual(usage.totalTokens, 32)
        XCTAssertEqual(client.fetchedSnapshotDeviceIDs, ["device-2"])
        XCTAssertEqual(cache.savedChangedDeviceIDs, [["device-2"]])
        XCTAssertEqual(try cache.load()?.envelopes.map(\.deviceID).sorted(), ["device-1", "device-2"])
    }

    func test_manifestRemovalDropsCachedDeviceBeforeRequiringItsDeletedKey() async throws {
        let fixture = try makeFixture()
        let revokedKey = SnapshotCipher.generateKey()
        let originalSnapshot = try SnapshotCipher.open(fixture.envelope, key: fixture.encryptionKey)
        let revokedSnapshot = RemoteUsageSnapshot(
            device: RemoteDeviceDescriptor(id: "device-2", name: "revoked", platform: "linux"),
            generatedAt: originalSnapshot.generatedAt,
            coveredFrom: originalSnapshot.coveredFrom,
            coveredTo: originalSnapshot.coveredTo,
            tokenEvents: originalSnapshot.tokenEvents,
            activityEvents: originalSnapshot.activityEvents)
        let revokedEnvelope = try SnapshotCipher.seal(revokedSnapshot, sequence: 1, key: revokedKey)
        let revokedDevice = RemoteDeviceSummary(
            id: revokedEnvelope.deviceID,
            name: "revoked",
            createdAt: fixture.start,
            lastSeenAt: Date(),
            latestSequence: revokedEnvelope.sequence)
        let cache = InMemoryRemoteSnapshotCache(entry: RemoteSnapshotCacheEntry(
            envelopes: [fixture.envelope, revokedEnvelope],
            manifest: [fixture.device(), revokedDevice],
            manifestEntityTag: entityTag("a"),
            fetchedAt: Date().addingTimeInterval(-60),
            snapshotCacheIdentifier: fixture.configuration.snapshotCacheIdentifier))
        let client = StubRemoteHubClient(
            manifestResult: .success(.modified(
                [fixture.device()],
                entityTag: entityTag("b"))))
        let provider = StubRemoteConfigurationProvider(
            configuration: fixture.configuration,
            encryptionKeys: [fixture.envelope.deviceID: fixture.encryptionKey])
        let reader = RemoteUsageReader(
            configurationProvider: provider,
            client: client,
            cache: cache,
            anchorStore: InMemoryRemoteSnapshotAnchorStore())

        let usage = try await reader.readUsage(from: fixture.start, to: fixture.end)

        XCTAssertEqual(usage.totalTokens, 16)
        XCTAssertEqual(client.fetchManifestCallCount, 1)
        XCTAssertEqual(client.fetchSnapshotCallCount, 0)
        XCTAssertEqual(try cache.load()?.envelopes.map(\.deviceID), [fixture.envelope.deviceID])
        XCTAssertEqual(cache.savedChangedDeviceIDs, [[revokedEnvelope.deviceID]])
    }

    func test_restoredDeviceKeyReauthenticatesIncompleteCachedState() async throws {
        let fixture = try makeFixture()
        let manifestTag = entityTag("a")
        let cache = InMemoryRemoteSnapshotCache(entry: fixture.cacheEntry(
            fetchedAt: Date().addingTimeInterval(-60),
            manifestEntityTag: manifestTag))
        let provider = InMemoryRemoteSyncConfigurationStore(configuration: fixture.configuration)
        let client = StubRemoteHubClient(
            manifestResult: .success(.notModified(entityTag: manifestTag)))
        let reader = RemoteUsageReader(
            configurationProvider: provider,
            client: client,
            cache: cache,
            anchorStore: InMemoryRemoteSnapshotAnchorStore())

        await XCTAssertThrowsErrorAsync {
            _ = try await reader.readUsage(from: fixture.start, to: fixture.end)
        }
        try provider.saveEncryptionKey(fixture.encryptionKey, for: fixture.envelope.deviceID)

        let usage = try await reader.readUsage(from: fixture.start, to: fixture.end)

        XCTAssertEqual(usage.totalTokens, 16)
        XCTAssertEqual(cache.loadCallCount, 2)
        XCTAssertEqual(client.fetchManifestCallCount, 2)
    }

    func test_remoteReaderRejectsDeviceThatMissedFreshnessWindow() async throws {
        let fixture = try makeFixture()
        let interval = TokiSyncLimits.minimumSyncIntervalSeconds
        let lastSeenAt = Date().addingTimeInterval(
            -TimeInterval(interval * TokiSyncLimits.staleIntervalMultiplier + 30))
        let manifest = [fixture.device(lastSeenAt: lastSeenAt, syncIntervalSeconds: interval)]
        let client = fixture.makeClient(manifest: manifest)
        let reader = fixture.makeReader(client: client)

        do {
            _ = try await reader.readUsage(from: fixture.start, to: fixture.end)
            XCTFail("Expected stale remote device data to fail")
        } catch let error as RemoteUsageReaderError {
            guard case let .staleDevice(name) = error else {
                return XCTFail("Expected staleDevice, got \(error)")
            }
            XCTAssertEqual(name, "build-server")
        }
    }
}
