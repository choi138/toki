import Foundation
import TokiSyncProtocol
import TokiUsageCore
import XCTest
@testable import TokiAgentCore
@testable import TokiUsageReaders

final class OpenClawSnapshotTests: XCTestCase {
    func test_publicReaderReachesSnapshotWithModelProviderCostBucketsAndIndependentActivity() async throws {
        let fixture = try OpenClawFixture()
        defer { fixture.remove() }
        try fixture.jsonl([OpenClawFixture.event()])
        try fixture.jsonl([OpenClawFixture.event()], agent: "work")
        try fixture.jsonl([OpenClawFixture.event(
            id: "unpriced", model: "fixture-unpriced-model", timestamp: OpenClawFixture.timestamp + 1000,
            usage: #"{"input":7,"output":2}"#)], filename: "unknown.jsonl")
        let reader = OpenClawReader(agentsURLOverride: fixture.agents)
        let usage = try await reader.readUsage(from: OpenClawFixture.start, to: OpenClawFixture.end)
        let configuration = try AgentConfiguration(bundle: AgentPairingBundle(
            hubURL: XCTUnwrap(URL(string: "https://hub.example.test")),
            deviceID: "openclaw-fixture", deviceName: "fixture",
            uploadToken: SnapshotCipher.randomToken(), encryptionKey: SnapshotCipher.generateKey(),
            retentionDays: 7, syncIntervalSeconds: 900))
        let builder = AgentSnapshotBuilder(
            home: fixture.root, environment: [:],
            readerDescriptors: [LocalUsageReaderDescriptor(reader: reader, sourceLocations: [])])
        let now = OpenClawFixture.end.addingTimeInterval(-1)
        let snapshot = try await builder.build(configuration: configuration, now: now)
        let decoded = try JSONDecoder().decode(
            RemoteUsageSnapshot.self, from: JSONEncoder().encode(snapshot))
        XCTAssertEqual(snapshot, decoded)
        XCTAssertNoThrow(try RemoteUsageSnapshotValidator.validate(decoded, now: now))
        XCTAssertEqual(decoded.tokenEvents.reduce(0) { $0 + $1.totalTokens }, usage.totalTokens)
        let modeled = decoded.tokenEvents.filter { $0.model == "claude-opus-4-6" }
        XCTAssertEqual(modeled.reduce(0) { $0 + $1.totalTokens }, 720)
        XCTAssertTrue(modeled.allSatisfy { $0.provider == "anthropic" && $0.costIsKnown == true })
        XCTAssertEqual(modeled.reduce(0) { $0 + $1.reasoningTokens }, 40)
        XCTAssertEqual(modeled.reduce(0) { $0 + ($1.cost ?? 0) }, 0.0072, accuracy: 0.000001)
        let unknown = try XCTUnwrap(decoded.tokenEvents.first { $0.model == "fixture-unpriced-model" })
        XCTAssertEqual(unknown.costIsKnown, false)
        // The existing wire contract encodes explicitly unknown prices as zero + false.
        // Nil is reserved for legacy events with no cost-known metadata.
        XCTAssertEqual(unknown.cost, 0)
        XCTAssertEqual(Set(decoded.activityEvents.filter { $0.model == "claude-opus-4-6" }.map(\.streamID)).count, 2)
        let encoded = try XCTUnwrap(String(bytes: JSONEncoder().encode(decoded), encoding: .utf8))
        XCTAssertFalse(encoded.contains(fixture.root.path))
    }
}
