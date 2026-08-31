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

        XCTAssertEqual(firstSnapshot.coveredFrom, expectedTimestamps[0])
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

    func test_snapshotNarrowsCoverageUntilEncryptedEnvelopeFits() async throws {
        let fixture = try AgentSnapshotFixture()
        defer { fixture.remove() }
        let eventCount = 25000
        let usage = Self.highVolumeUsage(now: fixture.now, eventCount: eventCount)
        let descriptor = LocalUsageReaderDescriptor(
            reader: FixedTokenReader(name: "Senpi", usage: usage),
            sourceLocations: [])
        let builder = AgentSnapshotBuilder(
            home: fixture.root,
            readerDescriptors: [descriptor])

        let snapshot = try await builder.build(
            configuration: fixture.configuration,
            now: fixture.now)
        let envelope = try SnapshotCipher.seal(
            snapshot,
            sequence: UInt64.max,
            key: fixture.configuration.encryptionKey)
        let encodedEnvelope = try TokiSyncCoding.makeEncoder().encode(envelope)

        XCTAssertGreaterThan(snapshot.coveredFrom, fixture.now.addingTimeInterval(-30))
        XCTAssertLessThan(snapshot.tokenEvents.count, eventCount)
        XCTAssertTrue(snapshot.tokenEvents.allSatisfy { $0.timestamp >= snapshot.coveredFrom })
        XCTAssertLessThanOrEqual(encodedEnvelope.count, TokiSyncLimits.maximumEnvelopeBytes)
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

    private static func highVolumeUsage(now: Date, eventCount: Int) -> RawTokenUsage {
        var usage = RawTokenUsage()
        let model = String(repeating: "m", count: RemoteUsageSnapshotValidator.maximumModelLength)
        for index in 0..<eventCount {
            usage.recordTokenEvent(
                timestamp: now.addingTimeInterval(-30 + Double(index) / 1000),
                source: "Senpi",
                model: model,
                provider: "openrouter",
                inputTokens: RemoteUsageSnapshotValidator.maximumTokenCountPerBucket,
                outputTokens: RemoteUsageSnapshotValidator.maximumTokenCountPerBucket,
                cacheReadTokens: RemoteUsageSnapshotValidator.maximumTokenCountPerBucket,
                cacheWriteTokens: RemoteUsageSnapshotValidator.maximumTokenCountPerBucket,
                reasoningTokens: RemoteUsageSnapshotValidator.maximumTokenCountPerBucket,
                cost: RemoteUsageSnapshotValidator.maximumCostPerEvent)
        }
        return usage
    }
}
