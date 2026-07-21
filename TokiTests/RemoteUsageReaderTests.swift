import Foundation
import TokiSyncProtocol
import XCTest
@testable import Toki

final class RemoteUsageReaderTests: XCTestCase {
    func test_remoteReaderDecryptsAndMapsUsageWithoutLocalPaths() async throws {
        let fixture = try makeFixture()
        let client = fixture.makeClient()
        let reader = fixture.makeReader(client: client)

        let usage = try await reader.readUsage(from: fixture.start, to: fixture.end)

        XCTAssertEqual(usage.inputTokens, 10)
        XCTAssertEqual(usage.outputTokens, 3)
        XCTAssertEqual(usage.cacheReadTokens, 2)
        XCTAssertEqual(usage.reasoningTokens, 1)
        XCTAssertEqual(usage.totalTokens, 16)
        XCTAssertEqual(usage.tokenEvents.first?.source, "Codex · build-server")
        XCTAssertEqual(usage.tokenEvents.first?.attribution, nil)
        XCTAssertEqual(usage.activityEvents.count, 1)
        XCTAssertEqual(usage.perModel["gpt-5"]?.totalTokens, 16)
    }
}

extension RemoteUsageReaderTests {
    func test_remoteReaderReturnsOneOriginSlicePerStableDeviceID() async throws {
        let fixture = try makeFixture()
        let secondKey = SnapshotCipher.generateKey()
        let secondSnapshot = RemoteUsageSnapshot(
            device: RemoteDeviceDescriptor(
                id: "device-2",
                name: "build-server",
                platform: "linux"),
            generatedAt: fixture.start.addingTimeInterval(180),
            coveredFrom: fixture.start,
            coveredTo: fixture.end,
            tokenEvents: [
                RemoteTokenEvent(
                    timestamp: fixture.start.addingTimeInterval(90),
                    source: "Codex",
                    model: "gpt-5",
                    inputTokens: 20,
                    outputTokens: 5,
                    cacheReadTokens: 0,
                    cacheWriteTokens: 0,
                    reasoningTokens: 0),
            ],
            activityEvents: [])
        let secondEnvelope = try SnapshotCipher.seal(
            secondSnapshot,
            sequence: 1,
            key: secondKey)
        let secondDevice = RemoteDeviceSummary(
            id: secondEnvelope.deviceID,
            name: "build-server",
            createdAt: fixture.start,
            lastSeenAt: Date(),
            latestSequence: secondEnvelope.sequence,
            syncIntervalSeconds: TokiSyncLimits.defaultSyncIntervalSeconds)
        let provider = StubRemoteConfigurationProvider(
            configuration: fixture.configuration,
            encryptionKeys: [
                fixture.envelope.deviceID: fixture.encryptionKey,
                secondEnvelope.deviceID: secondKey,
            ])
        let client = StubRemoteHubClient(
            manifestResult: .success(.modified(
                [fixture.device(), secondDevice],
                entityTag: entityTag("b"))),
            snapshotResult: .success([fixture.envelope, secondEnvelope]))
        let reader = RemoteUsageReader(
            configurationProvider: provider,
            client: client,
            cache: InMemoryRemoteSnapshotCache(),
            anchorStore: InMemoryRemoteSnapshotAnchorStore())

        let slices = try await reader.readUsageByOrigin(
            from: fixture.start,
            to: fixture.end)

        XCTAssertEqual(slices.count, 2)
        XCTAssertEqual(Set(slices.map(\.origin.name)), ["build-server"])
        XCTAssertEqual(Set(slices.map(\.origin.id)).count, 2)
        XCTAssertEqual(Set(slices.map(\.usage.totalTokens)), [16, 25])
        XCTAssertEqual(
            Set(slices.flatMap(\.sourceStats).map(\.source)),
            ["Codex"])
    }
}
