import Foundation
import TokiSyncProtocol
import XCTest
@testable import Toki

extension RemoteUsageReaderTests {
    func makeFixture() throws -> RemoteReaderFixture {
        let start = Date(timeIntervalSince1970: 1_750_000_000)
        let end = start.addingTimeInterval(3600)
        let key = SnapshotCipher.generateKey()
        let configuration = try RemoteHubConfiguration(
            hubURL: XCTUnwrap(URL(string: "https://hub.example.test")),
            ownerToken: String(repeating: "o", count: 32))
        let snapshot = RemoteUsageSnapshot(
            device: RemoteDeviceDescriptor(id: "device-1", name: "build-server", platform: "linux"),
            generatedAt: start.addingTimeInterval(120),
            coveredFrom: start,
            coveredTo: end,
            tokenEvents: [
                RemoteTokenEvent(
                    timestamp: start.addingTimeInterval(60),
                    source: "Codex",
                    model: "gpt-5",
                    inputTokens: 10,
                    outputTokens: 3,
                    cacheReadTokens: 2,
                    cacheWriteTokens: 0,
                    reasoningTokens: 1),
            ],
            activityEvents: [
                RemoteActivityEvent(
                    timestamp: start.addingTimeInterval(60),
                    source: "Codex",
                    model: "gpt-5",
                    streamID: "opaque-stream",
                    agentKind: .main),
            ])
        return try RemoteReaderFixture(
            configuration: configuration,
            envelope: SnapshotCipher.seal(snapshot, sequence: 1, key: key),
            encryptionKey: key,
            start: start,
            end: end)
    }

    func makeTemporaryDirectory() -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("toki-remote-tests-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }
}

struct RemoteReaderFixture {
    let configuration: RemoteHubConfiguration
    let envelope: EncryptedUsageEnvelope
    let encryptionKey: String
    let start: Date
    let end: Date

    var configurationProvider: StubRemoteConfigurationProvider {
        StubRemoteConfigurationProvider(
            configuration: configuration,
            encryptionKeys: [envelope.deviceID: encryptionKey])
    }

    func device(
        sequence: UInt64? = nil,
        lastSeenAt: Date? = Date(),
        syncIntervalSeconds: Int = TokiSyncLimits.defaultSyncIntervalSeconds) -> RemoteDeviceSummary {
        RemoteDeviceSummary(
            id: envelope.deviceID,
            name: "build-server",
            createdAt: start,
            lastSeenAt: lastSeenAt,
            latestSequence: sequence ?? envelope.sequence,
            syncIntervalSeconds: syncIntervalSeconds)
    }

    func cacheEntry(
        envelopes: [EncryptedUsageEnvelope]? = nil,
        sequence: UInt64? = nil,
        fetchedAt: Date = Date(),
        manifestEntityTag: String? = nil) -> RemoteSnapshotCacheEntry {
        let values = envelopes ?? [envelope]
        return RemoteSnapshotCacheEntry(
            envelopes: values,
            manifest: [device(sequence: sequence ?? values.first?.sequence)],
            manifestEntityTag: manifestEntityTag,
            fetchedAt: fetchedAt,
            snapshotCacheIdentifier: configuration.snapshotCacheIdentifier)
    }

    func makeClient(
        envelopes: [EncryptedUsageEnvelope]? = nil,
        manifest: [RemoteDeviceSummary]? = nil,
        delayNanoseconds: UInt64 = 0) -> StubRemoteHubClient {
        StubRemoteHubClient(
            manifestResult: .success(.modified(
                manifest ?? [device(sequence: (envelopes ?? [envelope]).first?.sequence)],
                entityTag: entityTag("a"))),
            snapshotResult: .success(envelopes ?? [envelope]),
            delayNanoseconds: delayNanoseconds)
    }

    func makeReader(
        client: StubRemoteHubClient,
        cache: any RemoteSnapshotCaching = InMemoryRemoteSnapshotCache(),
        anchorStore: any RemoteSnapshotAnchorStoring = InMemoryRemoteSnapshotAnchorStore()) -> RemoteUsageReader {
        RemoteUsageReader(
            configurationProvider: configurationProvider,
            client: client,
            cache: cache,
            anchorStore: anchorStore)
    }
}

struct LegacyAnchorFixtureDocument: Encodable {
    let anchors: [String: RemoteSnapshotAnchor]
}
