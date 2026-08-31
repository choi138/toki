import Foundation
import TokiSyncProtocol
import TokiUsageCore
import XCTest
@testable import TokiAgentCore
@testable import TokiUsageReaders

final class AgentSnapshotEventLimitTests: XCTestCase {
    func test_snapshotBoundsAggregateReaderEventsDeterministically() async throws {
        let fixture = try AgentSnapshotFixture()
        defer { fixture.remove() }
        let now = fixture.now
        let senpiUsage = Self.usage(
            source: "Senpi",
            timestamps: [
                now.addingTimeInterval(-240),
                now.addingTimeInterval(-60),
            ])
        let existingUsage = Self.usage(
            source: "Claude Code",
            timestamps: [
                now.addingTimeInterval(-120),
                now.addingTimeInterval(-30),
            ])
        let descriptors = [
            LocalUsageReaderDescriptor(
                reader: FixedTokenReader(name: "Senpi", usage: senpiUsage),
                sourceLocations: []),
            LocalUsageReaderDescriptor(
                reader: FixedTokenReader(name: "Claude Code", usage: existingUsage),
                sourceLocations: []),
        ]
        let limits = AgentSnapshotEventLimits(
            maximumTokenEventCount: 2,
            maximumCostEventCount: 2,
            maximumActivityEventCount: 2)
        let firstBuilder = AgentSnapshotBuilder(
            home: fixture.root,
            readerDescriptors: descriptors,
            eventLimits: limits)
        let secondBuilder = AgentSnapshotBuilder(
            home: fixture.root,
            readerDescriptors: Array(descriptors.reversed()),
            eventLimits: limits)

        let firstSnapshot = try await firstBuilder.build(
            configuration: fixture.configuration,
            now: now)
        let secondSnapshot = try await secondBuilder.build(
            configuration: fixture.configuration,
            now: now)
        let expectedTimestamps = [
            now.addingTimeInterval(-60),
            now.addingTimeInterval(-30),
        ]

        XCTAssertEqual(firstSnapshot.tokenEvents.map(\.timestamp), expectedTimestamps)
        XCTAssertEqual(firstSnapshot.costEvents?.map(\.timestamp), expectedTimestamps)
        XCTAssertEqual(firstSnapshot.activityEvents.map(\.timestamp), expectedTimestamps)
        XCTAssertEqual(firstSnapshot.tokenEvents, secondSnapshot.tokenEvents)
        XCTAssertEqual(firstSnapshot.costEvents, secondSnapshot.costEvents)
        XCTAssertEqual(firstSnapshot.activityEvents, secondSnapshot.activityEvents)
        XCTAssertNoThrow(try RemoteUsageSnapshotValidator.validate(firstSnapshot, now: now))
        XCTAssertNoThrow(try SnapshotCipher.seal(
            firstSnapshot,
            sequence: 1,
            key: fixture.configuration.encryptionKey))
    }

    private static func usage(source: String, timestamps: [Date]) -> RawTokenUsage {
        var usage = RawTokenUsage()
        for (index, timestamp) in timestamps.enumerated() {
            usage.recordTokenEvent(
                timestamp: timestamp,
                source: source,
                model: "test-model",
                inputTokens: index + 1,
                outputTokens: 1)
            usage.recordTokenEvent(
                timestamp: timestamp,
                source: source,
                model: "test-model",
                inputTokens: 0,
                outputTokens: 0,
                cost: Double(index + 1))
            usage.activityEvents.append(ActivityTimeEvent(
                streamID: "\(source)-\(index)",
                timestamp: timestamp,
                key: "test-model"))
        }
        return usage
    }
}
