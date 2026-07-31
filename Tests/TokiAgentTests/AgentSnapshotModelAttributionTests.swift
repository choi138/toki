import Foundation
import TokiUsageCore
import XCTest
@testable import TokiAgentCore
@testable import TokiUsageReaders

final class AgentSnapshotModelAttributionTests: XCTestCase {
    func test_snapshotPreservesMixedHermesModelAttributionAndResidual() async throws {
        let now = Date(timeIntervalSince1970: 1_784_200_000)
        let eventDate = now.addingTimeInterval(-60)
        var usage = RawTokenUsage(inputTokens: 150)
        usage.recordTokenEvent(
            timestamp: eventDate,
            source: "Hermes",
            model: "gpt-5.6-sol",
            inputTokens: 100,
            outputTokens: 0)
        usage.recordTokenEvent(
            timestamp: eventDate,
            source: "Hermes",
            model: "kr/claude-opus-5",
            inputTokens: 30,
            outputTokens: 0)
        usage.recordTokenEvent(
            timestamp: eventDate,
            source: "Hermes",
            model: nil,
            inputTokens: 20,
            outputTokens: 0)
        let descriptor = LocalUsageReaderDescriptor(
            reader: FixedTokenReader(name: "Hermes", usage: usage),
            sourceLocations: [])
        let fixture = try AgentSnapshotFixture()
        defer { fixture.remove() }
        let builder = AgentSnapshotBuilder(
            home: fixture.root,
            readerDescriptors: [descriptor])

        let snapshot = try await builder.build(configuration: fixture.configuration, now: now)
        let tokensByModel = snapshot.tokenEvents.reduce(into: [String: Int]()) { result, event in
            result[
                event.model ?? UsageModelGrouping.mixedOrUnattributedLabel,
                default: 0
            ] += event.totalTokens
        }

        XCTAssertEqual(tokensByModel, [
            "gpt-5.6-sol": 100,
            "kr/claude-opus-5": 30,
            UsageModelGrouping.mixedOrUnattributedLabel: 20,
        ])
    }
}
