import Darwin
import Foundation
import TokiSyncProtocol
import XCTest
@testable import Toki

extension RemoteUsageReaderTests {
    func test_replayAnchorSurvivesCacheRemovalUntilDeviceRevocation() throws {
        let fixture = try makeFixture()
        let snapshot = try SnapshotCipher.open(fixture.envelope, key: fixture.encryptionKey)
        let newerEnvelope = try SnapshotCipher.seal(snapshot, sequence: 2, key: fixture.encryptionKey)
        let root = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let cache = RemoteSnapshotCache(url: root.appendingPathComponent("snapshots.json"))
        let anchorStore = RemoteSnapshotAnchorStore(
            url: root.appendingPathComponent("anchors.json"),
            legacyCacheURL: cache.url)

        try cache.save(fixture.cacheEntry(envelopes: [newerEnvelope], sequence: 2))
        try anchorStore.validateAndSave(
            [newerEnvelope],
            originIdentifier: fixture.configuration.snapshotCacheIdentifier)
        try cache.clear()

        XCTAssertThrowsError(try anchorStore.validateAndSave(
            [fixture.envelope],
            originIdentifier: fixture.configuration.snapshotCacheIdentifier)) { error in
                guard let readerError = error as? RemoteUsageReaderError,
                      case .staleSnapshot = readerError else {
                    return XCTFail("Expected staleSnapshot, got \(error)")
                }
            }

        try anchorStore.remove(
            deviceID: fixture.envelope.deviceID,
            originIdentifier: fixture.configuration.snapshotCacheIdentifier)
        XCTAssertNoThrow(try anchorStore.validateAndSave(
            [fixture.envelope],
            originIdentifier: fixture.configuration.snapshotCacheIdentifier))
    }

    func test_replayAnchorsArePartitionedByRemoteOrigin() throws {
        let fixture = try makeFixture()
        let snapshot = try SnapshotCipher.open(fixture.envelope, key: fixture.encryptionKey)
        let newerEnvelope = try SnapshotCipher.seal(snapshot, sequence: 2, key: fixture.encryptionKey)
        let otherConfiguration = try RemoteHubConfiguration(
            hubURL: fixture.configuration.hubURL,
            ownerToken: String(repeating: "n", count: 32))
        let root = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let anchorStore = RemoteSnapshotAnchorStore(
            url: root.appendingPathComponent("anchors.json"),
            legacyCacheURL: root.appendingPathComponent("missing-cache.json"))

        try anchorStore.validateAndSave(
            [newerEnvelope],
            originIdentifier: fixture.configuration.snapshotCacheIdentifier)

        XCTAssertNoThrow(try anchorStore.validateAndSave(
            [fixture.envelope],
            originIdentifier: otherConfiguration.snapshotCacheIdentifier))
        XCTAssertThrowsError(try anchorStore.validateAndSave(
            [fixture.envelope],
            originIdentifier: fixture.configuration.snapshotCacheIdentifier)) { error in
                guard let readerError = error as? RemoteUsageReaderError,
                      case .staleSnapshot = readerError else {
                    return XCTFail("Expected staleSnapshot, got \(error)")
                }
            }
    }

    func test_replayAnchorAheadOfDiskCacheRefetchesFromHub() async throws {
        let fixture = try makeFixture()
        let snapshot = try SnapshotCipher.open(fixture.envelope, key: fixture.encryptionKey)
        let newerEnvelope = try SnapshotCipher.seal(snapshot, sequence: 2, key: fixture.encryptionKey)
        let cache = InMemoryRemoteSnapshotCache(
            entry: fixture.cacheEntry(fetchedAt: Date().addingTimeInterval(-60)))
        let anchorStore = InMemoryRemoteSnapshotAnchorStore(
            envelopes: [newerEnvelope],
            originIdentifier: fixture.configuration.snapshotCacheIdentifier)
        let client = fixture.makeClient(
            envelopes: [newerEnvelope],
            manifest: [fixture.device(sequence: newerEnvelope.sequence)])
        let reader = fixture.makeReader(
            client: client,
            cache: cache,
            anchorStore: anchorStore)

        let usage = try await reader.readUsage(from: fixture.start, to: fixture.end)

        XCTAssertEqual(usage.totalTokens, 16)
        XCTAssertEqual(try cache.load()?.envelopes, [newerEnvelope])
        XCTAssertEqual(client.fetchManifestCallCount, 1)
        XCTAssertEqual(client.fetchSnapshotCallCount, 1)
    }

    func test_legacyReplayAnchorsMigrateBeforeLegacyCacheRemoval() throws {
        let fixture = try makeFixture()
        let snapshot = try SnapshotCipher.open(fixture.envelope, key: fixture.encryptionKey)
        let newerEnvelope = try SnapshotCipher.seal(snapshot, sequence: 2, key: fixture.encryptionKey)
        let root = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let legacyCacheURL = root.appendingPathComponent("legacy-cache.json")
        let anchorURL = root.appendingPathComponent("anchors.json")
        let legacyDocument = try LegacyAnchorFixtureDocument(
            anchors: RemoteSnapshotProgress.anchors(for: [newerEnvelope]))
        try TokiSyncCoding.makeEncoder().encode(legacyDocument).write(to: legacyCacheURL)
        let anchorStore = RemoteSnapshotAnchorStore(url: anchorURL, legacyCacheURL: legacyCacheURL)

        try anchorStore.validateAndSave(
            [newerEnvelope],
            originIdentifier: fixture.configuration.snapshotCacheIdentifier)
        try FileManager.default.removeItem(at: legacyCacheURL)

        XCTAssertTrue(FileManager.default.fileExists(atPath: anchorURL.path))
        XCTAssertThrowsError(try anchorStore.validateAndSave(
            [fixture.envelope],
            originIdentifier: fixture.configuration.snapshotCacheIdentifier)) { error in
                guard let readerError = error as? RemoteUsageReaderError,
                      case .staleSnapshot = readerError else {
                    return XCTFail("Expected staleSnapshot, got \(error)")
                }
            }
    }

    func test_originMismatchMigratesLegacyCacheAnchorBeforeClearing() async throws {
        let fixture = try makeFixture()
        let snapshot = try SnapshotCipher.open(fixture.envelope, key: fixture.encryptionKey)
        let newerEnvelope = try SnapshotCipher.seal(snapshot, sequence: 2, key: fixture.encryptionKey)
        let root = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let cacheURL = root.appendingPathComponent("snapshots.json")
        let anchorURL = root.appendingPathComponent("anchors.json")
        let cache = RemoteSnapshotCache(url: cacheURL)
        try cache.save(RemoteSnapshotCacheEntry(
            envelopes: [newerEnvelope],
            manifest: [fixture.device(sequence: newerEnvelope.sequence)],
            fetchedAt: Date(),
            snapshotCacheIdentifier: nil))
        let anchorStore = RemoteSnapshotAnchorStore(
            url: anchorURL,
            legacyCacheURL: cacheURL)
        let reader = fixture.makeReader(
            client: fixture.makeClient(),
            cache: cache,
            anchorStore: anchorStore)

        do {
            _ = try await reader.readUsage(from: fixture.start, to: fixture.end)
            XCTFail("Expected the migrated anchor to reject the older snapshot")
        } catch let error as RemoteUsageReaderError {
            guard case .staleSnapshot = error else {
                return XCTFail("Expected staleSnapshot, got \(error)")
            }
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: anchorURL.path))
        XCTAssertNil(try cache.load())
    }

    func test_corruptedLegacyCacheWithoutAnchorFailsClosed() throws {
        let fixture = try makeFixture()
        let root = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let legacyCacheURL = root.appendingPathComponent("legacy-cache.json")
        let anchorURL = root.appendingPathComponent("anchors.json")
        try Data("not-json".utf8).write(to: legacyCacheURL)
        let anchorStore = RemoteSnapshotAnchorStore(url: anchorURL, legacyCacheURL: legacyCacheURL)

        XCTAssertThrowsError(try anchorStore.validateAndSave(
            [fixture.envelope],
            originIdentifier: fixture.configuration.snapshotCacheIdentifier)) { error in
                guard let anchorError = error as? RemoteSnapshotAnchorStoreError,
                      case .invalidAnchorStore = anchorError else {
                    return XCTFail("Expected invalidAnchorStore, got \(error)")
                }
            }
        XCTAssertFalse(FileManager.default.fileExists(atPath: anchorURL.path))
    }

    func test_replayAnchorLockContentionFailsWithoutWaiting() throws {
        let fixture = try makeFixture()
        let root = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let anchorURL = root.appendingPathComponent("anchors.json")
        let lockURL = anchorURL.appendingPathExtension("lock")
        let descriptor = lockURL.path.withCString { path in
            Darwin.open(path, O_CREAT | O_RDWR | O_CLOEXEC, mode_t(0o600))
        }
        XCTAssertGreaterThanOrEqual(descriptor, 0)
        guard descriptor >= 0 else { return }
        defer {
            _ = flock(descriptor, LOCK_UN)
            _ = Darwin.close(descriptor)
        }
        XCTAssertEqual(flock(descriptor, LOCK_EX | LOCK_NB), 0)
        let anchorStore = RemoteSnapshotAnchorStore(
            url: anchorURL,
            legacyCacheURL: root.appendingPathComponent("missing-cache.json"))

        XCTAssertThrowsError(try anchorStore.validateAndSave(
            [fixture.envelope],
            originIdentifier: fixture.configuration.snapshotCacheIdentifier)) { error in
                guard let anchorError = error as? RemoteSnapshotAnchorStoreError,
                      case .lockUnavailable = anchorError else {
                    return XCTFail("Expected lockUnavailable, got \(error)")
                }
            }
    }

    func test_replayAnchorLockRepairsExistingPermissions() throws {
        let fixture = try makeFixture()
        let root = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let anchorURL = root.appendingPathComponent("anchors.json")
        let lockURL = anchorURL.appendingPathExtension("lock")
        try Data().write(to: lockURL)
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: 0o666)],
            ofItemAtPath: lockURL.path)
        let anchorStore = RemoteSnapshotAnchorStore(
            url: anchorURL,
            legacyCacheURL: root.appendingPathComponent("missing-cache.json"))

        try anchorStore.validateAndSave(
            [fixture.envelope],
            originIdentifier: fixture.configuration.snapshotCacheIdentifier)

        let attributes = try FileManager.default.attributesOfItem(atPath: lockURL.path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
    }

    func test_replayAnchorRejectsCurrentStoreAboveRegistryLimit() throws {
        let fixture = try makeFixture()
        let root = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let anchorURL = root.appendingPathComponent("anchors.json")
        try Data(
            repeating: 0x61,
            count: TokiSyncLimits.maximumRegistryBytes + 1).write(to: anchorURL)
        let anchorStore = RemoteSnapshotAnchorStore(
            url: anchorURL,
            legacyCacheURL: root.appendingPathComponent("missing-cache.json"))

        XCTAssertThrowsError(try anchorStore.validateAndSave(
            [fixture.envelope],
            originIdentifier: fixture.configuration.snapshotCacheIdentifier)) { error in
                guard let anchorError = error as? RemoteSnapshotAnchorStoreError,
                      case .invalidAnchorStore = anchorError else {
                    return XCTFail("Expected invalidAnchorStore, got \(error)")
                }
            }
    }

    func test_cacheCorruptionCannotResetReplayAnchor() async throws {
        let fixture = try makeFixture()
        let snapshot = try SnapshotCipher.open(fixture.envelope, key: fixture.encryptionKey)
        let newerEnvelope = try SnapshotCipher.seal(snapshot, sequence: 2, key: fixture.encryptionKey)
        let root = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let cacheURL = root.appendingPathComponent("snapshots.json")
        let cache = RemoteSnapshotCache(url: cacheURL)
        let anchorStore = RemoteSnapshotAnchorStore(
            url: root.appendingPathComponent("anchors.json"),
            legacyCacheURL: cacheURL)
        try anchorStore.validateAndSave(
            [newerEnvelope],
            originIdentifier: fixture.configuration.snapshotCacheIdentifier)
        try Data("not-json".utf8).write(to: cacheURL)
        let reader = fixture.makeReader(
            client: fixture.makeClient(),
            cache: cache,
            anchorStore: anchorStore)

        do {
            _ = try await reader.readUsage(from: fixture.start, to: fixture.end)
            XCTFail("Expected the retained anchor to reject an older snapshot")
        } catch let error as RemoteUsageReaderError {
            guard case .staleSnapshot = error else {
                return XCTFail("Expected staleSnapshot, got \(error)")
            }
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: cacheURL.path))
    }

    func test_temporaryKeyFailureCannotResetReplayAnchor() async throws {
        let fixture = try makeFixture()
        let snapshot = try SnapshotCipher.open(fixture.envelope, key: fixture.encryptionKey)
        let newerEnvelope = try SnapshotCipher.seal(snapshot, sequence: 2, key: fixture.encryptionKey)
        let provider = FlakyRemoteConfigurationProvider(
            configuration: fixture.configuration,
            encryptionKey: fixture.encryptionKey,
            failuresRemaining: 1)
        let anchorStore = InMemoryRemoteSnapshotAnchorStore(
            envelopes: [newerEnvelope],
            originIdentifier: fixture.configuration.snapshotCacheIdentifier)
        let reader = RemoteUsageReader(
            configurationProvider: provider,
            client: fixture.makeClient(),
            cache: InMemoryRemoteSnapshotCache(),
            anchorStore: anchorStore)

        await XCTAssertThrowsErrorAsync {
            _ = try await reader.readUsage(from: fixture.start, to: fixture.end)
        }
        do {
            _ = try await reader.readUsage(from: fixture.start, to: fixture.end)
            XCTFail("Expected the retained anchor to reject an older snapshot")
        } catch let error as RemoteUsageReaderError {
            guard case .staleSnapshot = error else {
                return XCTFail("Expected staleSnapshot, got \(error)")
            }
        }
    }

    func test_corruptedReplayAnchorFailsClosed() async throws {
        let fixture = try makeFixture()
        let root = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let anchorURL = root.appendingPathComponent("anchors.json")
        try Data("not-json".utf8).write(to: anchorURL)
        let anchorStore = RemoteSnapshotAnchorStore(
            url: anchorURL,
            legacyCacheURL: root.appendingPathComponent("missing-cache.json"))
        let cache = InMemoryRemoteSnapshotCache()
        let reader = fixture.makeReader(
            client: fixture.makeClient(),
            cache: cache,
            anchorStore: anchorStore)

        do {
            _ = try await reader.readUsage(from: fixture.start, to: fixture.end)
            XCTFail("Expected a corrupted anchor store to fail closed")
        } catch let error as RemoteSnapshotAnchorStoreError {
            guard case .invalidAnchorStore = error else {
                return XCTFail("Expected invalidAnchorStore, got \(error)")
            }
        }
        XCTAssertEqual(cache.saveCallCount, 0)
    }
}
