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
        XCTAssertEqual(usage.perModel["gpt-5"]?.sources, ["Codex · build-server"])
    }

    func test_defaultAggregationPreservesRemoteSourceStats() async throws {
        let fixture = try makeFixture()
        let reader = fixture.makeReader(client: fixture.makeClient())
        let result = await UsageAggregator(readers: [reader]).aggregateUsage(for: UsageAggregationRequest(
            start: fixture.start,
            end: fixture.end,
            enabledReaderNames: [:],
            includesEmptySourceRows: false))

        XCTAssertEqual(result.usageData.sourceStats.map(\.source), ["Codex"])
        XCTAssertEqual(result.usageData.sourceStats.map(\.totalTokens), [16])
    }

    func test_activityEventsAreGroupedBySourceInOneMappingPass() throws {
        let fixture = try makeFixture()
        let original = try SnapshotCipher.open(fixture.envelope, key: fixture.encryptionKey)
        let snapshot = RemoteUsageSnapshot(
            device: original.device,
            generatedAt: original.generatedAt,
            coveredFrom: original.coveredFrom,
            coveredTo: original.coveredTo,
            tokenEvents: [],
            activityEvents: [
                RemoteActivityEvent(
                    timestamp: fixture.start.addingTimeInterval(60),
                    source: "Codex",
                    model: "gpt-5",
                    streamID: "codex-1",
                    agentKind: .main),
                RemoteActivityEvent(
                    timestamp: fixture.start.addingTimeInterval(90),
                    source: "Codex",
                    model: "gpt-5",
                    streamID: "codex-2",
                    agentKind: .subagent),
                RemoteActivityEvent(
                    timestamp: fixture.start.addingTimeInterval(120),
                    source: "Claude",
                    model: "claude-sonnet",
                    streamID: "claude-1",
                    agentKind: .main),
                RemoteActivityEvent(
                    timestamp: fixture.end,
                    source: "outside-range",
                    model: nil,
                    streamID: "ignored",
                    agentKind: .main),
            ])

        let grouped = RemoteUsageMapper().mappedActivityEventsBySource(
            from: snapshot,
            startDate: fixture.start,
            endDate: fixture.end)

        XCTAssertEqual(Set(grouped.keys), ["Codex", "Claude"])
        XCTAssertEqual(grouped["Codex"]?.count, 2)
        XCTAssertEqual(grouped["Claude"]?.count, 1)
        XCTAssertEqual(grouped.values.flatMap { $0 }.count, 3)
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
