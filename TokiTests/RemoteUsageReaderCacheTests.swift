import Foundation
import TokiSyncProtocol
import XCTest
@testable import Toki

extension RemoteUsageReaderTests {
    func test_remoteReaderUsesEncryptedCacheForTransportFailure() async throws {
        let fixture = try makeFixture()
        let cache = InMemoryRemoteSnapshotCache(
            entry: fixture.cacheEntry(fetchedAt: Date().addingTimeInterval(-60)))
        let client = StubRemoteHubClient(
            manifestResult: .failure(URLError(.notConnectedToInternet)))
        let reader = fixture.makeReader(client: client, cache: cache)

        let usage = try await reader.readUsage(from: fixture.start, to: fixture.end)

        XCTAssertEqual(usage.totalTokens, 16)
    }

    func test_remoteReaderDoesNotReuseCacheFromDifferentHubOrigin() async throws {
        let fixture = try makeFixture()
        let otherConfiguration = try RemoteHubConfiguration(
            hubURL: XCTUnwrap(URL(string: "https://other-hub.example.test")),
            ownerToken: String(repeating: "n", count: 32))
        let provider = StubRemoteConfigurationProvider(
            configuration: otherConfiguration,
            encryptionKeys: [fixture.envelope.deviceID: fixture.encryptionKey])
        let cache = InMemoryRemoteSnapshotCache(entry: fixture.cacheEntry())
        let reader = RemoteUsageReader(
            configurationProvider: provider,
            client: StubRemoteHubClient(
                manifestResult: .failure(URLError(.notConnectedToInternet))),
            cache: cache,
            anchorStore: InMemoryRemoteSnapshotAnchorStore())

        await XCTAssertThrowsErrorAsync {
            _ = try await reader.readUsage(from: fixture.start, to: fixture.end)
        }
        XCTAssertNil(try cache.load())
    }

    func test_remoteReaderDoesNotReuseCacheAfterOwnerCredentialChanges() async throws {
        let fixture = try makeFixture()
        let otherConfiguration = try RemoteHubConfiguration(
            hubURL: fixture.configuration.hubURL,
            ownerToken: String(repeating: "n", count: 32))
        let provider = StubRemoteConfigurationProvider(
            configuration: otherConfiguration,
            encryptionKeys: [fixture.envelope.deviceID: fixture.encryptionKey])
        let cache = InMemoryRemoteSnapshotCache(entry: fixture.cacheEntry())
        let reader = RemoteUsageReader(
            configurationProvider: provider,
            client: StubRemoteHubClient(
                manifestResult: .failure(URLError(.notConnectedToInternet))),
            cache: cache,
            anchorStore: InMemoryRemoteSnapshotAnchorStore())

        XCTAssertNotEqual(
            fixture.configuration.snapshotCacheIdentifier,
            otherConfiguration.snapshotCacheIdentifier)
        await XCTAssertThrowsErrorAsync {
            _ = try await reader.readUsage(from: fixture.start, to: fixture.end)
        }
        XCTAssertNil(try cache.load())
    }

    func test_remoteReaderUsesOfflineCacheEvenWhenManifestDeviceIsStale() async throws {
        let fixture = try makeFixture()
        let staleDevice = fixture.device(
            lastSeenAt: Date().addingTimeInterval(-2 * 60 * 60),
            syncIntervalSeconds: TokiSyncLimits.minimumSyncIntervalSeconds)
        let cache = InMemoryRemoteSnapshotCache(entry: RemoteSnapshotCacheEntry(
            envelopes: [fixture.envelope],
            manifest: [staleDevice],
            fetchedAt: Date().addingTimeInterval(-60 * 60),
            snapshotCacheIdentifier: fixture.configuration.snapshotCacheIdentifier))
        let reader = fixture.makeReader(
            client: StubRemoteHubClient(
                manifestResult: .failure(URLError(.notConnectedToInternet))),
            cache: cache)

        let firstUsage = try await reader.readUsage(from: fixture.start, to: fixture.end)
        let repeatedUsage = try await reader.readUsage(from: fixture.start, to: fixture.end)

        XCTAssertEqual(firstUsage.totalTokens, 16)
        XCTAssertEqual(repeatedUsage.totalTokens, 16)
    }

    func test_remoteReaderRejectsExpiredCacheForTransportFailure() async throws {
        let fixture = try makeFixture()
        let cache = InMemoryRemoteSnapshotCache(
            entry: fixture.cacheEntry(fetchedAt: Date().addingTimeInterval(-49 * 60 * 60)))
        let client = StubRemoteHubClient(
            manifestResult: .failure(URLError(.notConnectedToInternet)))
        let reader = fixture.makeReader(client: client, cache: cache)

        await XCTAssertThrowsErrorAsync {
            _ = try await reader.readUsage(from: fixture.start, to: fixture.end)
        }
    }

    func test_remoteReaderRejectsTamperedEnvelopeMetadata() async throws {
        let fixture = try makeFixture()
        let tampered = EncryptedUsageEnvelope(
            deviceID: fixture.envelope.deviceID,
            sequence: fixture.envelope.sequence + 1,
            generatedAt: fixture.envelope.generatedAt,
            payload: fixture.envelope.payload)
        let client = fixture.makeClient(
            envelopes: [tampered],
            manifest: [fixture.device(sequence: tampered.sequence)])
        let reader = fixture.makeReader(client: client)

        await XCTAssertThrowsErrorAsync {
            _ = try await reader.readUsage(from: fixture.start, to: fixture.end)
        }
    }

    func test_remoteReaderReconcilesSnapshotThatAdvancedAfterManifest() async throws {
        let fixture = try makeFixture()
        let snapshot = try SnapshotCipher.open(fixture.envelope, key: fixture.encryptionKey)
        let advancedEnvelope = try SnapshotCipher.seal(snapshot, sequence: 2, key: fixture.encryptionKey)
        let cache = InMemoryRemoteSnapshotCache()
        let reader = fixture.makeReader(
            client: fixture.makeClient(
                envelopes: [advancedEnvelope],
                manifest: [fixture.device(sequence: 1)]),
            cache: cache)

        let usage = try await reader.readUsage(from: fixture.start, to: fixture.end)
        let saved = try XCTUnwrap(cache.load())

        XCTAssertEqual(usage.totalTokens, 16)
        XCTAssertEqual(saved.envelopes.first?.sequence, 2)
        XCTAssertEqual(saved.manifest.first?.latestSequence, 2)
        XCTAssertNil(saved.manifestEntityTag)
    }

    func test_remoteReaderRejectsSnapshotOlderThanManifestSequence() async throws {
        let fixture = try makeFixture()
        let reader = fixture.makeReader(
            client: fixture.makeClient(
                envelopes: [fixture.envelope],
                manifest: [fixture.device(sequence: 2)]))

        await XCTAssertThrowsErrorAsync {
            _ = try await reader.readUsage(from: fixture.start, to: fixture.end)
        }
    }

    func test_snapshotPayloadBudgetRejectsCumulativeOverflow() throws {
        let fixture = try makeFixture()
        var budget = RemoteSnapshotPayloadBudget(maximumBytes: fixture.envelope.payload.utf8.count * 2 - 1)

        try budget.consume(fixture.envelope)

        XCTAssertThrowsError(try budget.consume(fixture.envelope)) { error in
            guard let clientError = error as? RemoteHubClientError,
                  case .responseTooLarge = clientError else {
                return XCTFail("Expected responseTooLarge, got \(error)")
            }
        }
        XCTAssertEqual(budget.usedBytes, fixture.envelope.payload.utf8.count)
    }

    func test_remoteReaderDoesNotUseCacheForCertificateFailure() async throws {
        let fixture = try makeFixture()
        let cache = InMemoryRemoteSnapshotCache(
            entry: fixture.cacheEntry(fetchedAt: Date().addingTimeInterval(-60)))
        let client = StubRemoteHubClient(
            manifestResult: .failure(URLError(.serverCertificateUntrusted)))
        let reader = fixture.makeReader(client: client, cache: cache)

        await XCTAssertThrowsErrorAsync {
            _ = try await reader.readUsage(from: fixture.start, to: fixture.end)
        }
    }

    func test_remoteReaderDoesNotUseCacheForRedirectedAuthenticatedRequest() async throws {
        let fixture = try makeFixture()
        let cache = InMemoryRemoteSnapshotCache(
            entry: fixture.cacheEntry(fetchedAt: Date().addingTimeInterval(-60)))
        let client = StubRemoteHubClient(
            manifestResult: .failure(RemoteHubClientError.redirectedResponse))
        let reader = fixture.makeReader(client: client, cache: cache)

        await XCTAssertThrowsErrorAsync {
            _ = try await reader.readUsage(from: fixture.start, to: fixture.end)
        }
    }

    func test_remoteReaderDoesNotOverwriteCacheWithTamperedResponse() async throws {
        let fixture = try makeFixture()
        let tampered = EncryptedUsageEnvelope(
            deviceID: fixture.envelope.deviceID,
            sequence: fixture.envelope.sequence + 1,
            generatedAt: fixture.envelope.generatedAt,
            payload: fixture.envelope.payload)
        let originalEntry = fixture.cacheEntry(fetchedAt: Date().addingTimeInterval(-60))
        let cache = InMemoryRemoteSnapshotCache(entry: originalEntry)
        let client = fixture.makeClient(
            envelopes: [tampered],
            manifest: [fixture.device(sequence: tampered.sequence)])
        let reader = fixture.makeReader(client: client, cache: cache)

        await XCTAssertThrowsErrorAsync {
            _ = try await reader.readUsage(from: fixture.start, to: fixture.end)
        }
        XCTAssertEqual(cache.saveCallCount, 0)
        XCTAssertEqual(try cache.load(), originalEntry)
    }

    func test_remoteReaderRequiresPerDeviceEncryptionKey() async throws {
        let fixture = try makeFixture()
        let provider = StubRemoteConfigurationProvider(
            configuration: fixture.configuration,
            encryptionKeys: [:])
        let reader = RemoteUsageReader(
            configurationProvider: provider,
            client: fixture.makeClient(),
            cache: InMemoryRemoteSnapshotCache(),
            anchorStore: InMemoryRemoteSnapshotAnchorStore())

        await XCTAssertThrowsErrorAsync {
            _ = try await reader.readUsage(from: fixture.start, to: fixture.end)
        }
    }
}
