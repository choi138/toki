import Foundation
import TokiSyncProtocol
import TokiUsageCore
import XCTest
@testable import TokiAgentCore
@testable import TokiUsageReaders

final class AgentSnapshotModelAttributionTests: XCTestCase {
    func test_snapshotEncodesCanonicalMixedActivityAsUnattributedRemoteModel() async throws {
        let now = Date(timeIntervalSince1970: 1_784_200_000)
        let eventDate = now.addingTimeInterval(-60)
        let usage = RawTokenUsage(activityEvents: [
            ActivityTimeEvent(
                streamID: "mixed-model-session",
                timestamp: eventDate,
                key: UsageModelGrouping.mixedOrUnattributedKey),
        ])
        let descriptor = LocalUsageReaderDescriptor(
            reader: FixedTokenReader(name: "Hermes", usage: usage),
            sourceLocations: [])
        let fixture = try AgentSnapshotFixture()
        defer { fixture.remove() }
        let builder = AgentSnapshotBuilder(
            home: fixture.root,
            readerDescriptors: [descriptor])

        let snapshot = try await builder.build(configuration: fixture.configuration, now: now)

        XCTAssertEqual(snapshot.activityEvents.count, 1)
        XCTAssertNil(snapshot.activityEvents.first?.model)
    }

    func test_snapshotPreservesCostOnlyEventForRemoteMapping() async throws {
        let now = Date(timeIntervalSince1970: 1_784_200_000)
        let eventDate = now.addingTimeInterval(-60)
        var usage = RawTokenUsage(cost: 1.25)
        usage.recordTokenEvent(
            timestamp: eventDate,
            source: "Hermes",
            model: nil,
            inputTokens: 0,
            outputTokens: 0,
            cost: 1.25)
        let descriptor = LocalUsageReaderDescriptor(
            reader: FixedTokenReader(name: "Hermes", usage: usage),
            sourceLocations: [])
        let fixture = try AgentSnapshotFixture()
        defer { fixture.remove() }
        let builder = AgentSnapshotBuilder(
            home: fixture.root,
            readerDescriptors: [descriptor])

        let snapshot = try await builder.build(configuration: fixture.configuration, now: now)
        let event = try XCTUnwrap(snapshot.tokenEvents.first)

        XCTAssertEqual(snapshot.tokenEvents.count, 1)
        XCTAssertEqual(event.totalTokens, 0)
        XCTAssertNil(event.model)
        XCTAssertEqual(event.cost ?? -1, 1.25, accuracy: 0.000001)
        XCTAssertNoThrow(try RemoteUsageSnapshotValidator.validate(snapshot, now: now))
    }

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
