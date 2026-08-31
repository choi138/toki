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
        let expectedCoveredFrom = now.addingTimeInterval(-120 + 0.001)

        XCTAssertEqual(firstSnapshot.coveredFrom, expectedCoveredFrom)
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
        XCTAssertFalse(snapshot.tokenEvents.isEmpty)
        XCTAssertTrue(snapshot.tokenEvents.allSatisfy { $0.timestamp >= snapshot.coveredFrom })
        XCTAssertLessThanOrEqual(encodedEnvelope.count, TokiSyncLimits.maximumEnvelopeBytes)
        XCTAssertNil(snapshot.costEvents)

        let precedingTimestamp = try XCTUnwrap(
            usage.tokenEvents.lazy.map(\.timestamp).filter { $0 < snapshot.coveredFrom }.max())
        let precedingSnapshot = RemoteUsageSnapshot(
            device: snapshot.device,
            generatedAt: snapshot.generatedAt,
            coveredFrom: precedingTimestamp,
            coveredTo: snapshot.coveredTo,
            tokenEvents: [Self.highVolumeRemoteEvent(timestamp: precedingTimestamp)] + snapshot.tokenEvents,
            costEvents: nil,
            activityEvents: snapshot.activityEvents)
        XCTAssertThrowsError(try SnapshotCipher.seal(
            precedingSnapshot,
            sequence: UInt64.max,
            key: fixture.configuration.encryptionKey)) { error in
                guard case SnapshotCipherError.payloadTooLarge = error else {
                    return XCTFail("Expected payloadTooLarge, received \(error)")
                }
            }
    }

    func test_snapshotUsesStableCutoffAfterOversizedTimestampCohort() async throws {
        let fixture = try AgentSnapshotFixture()
        defer { fixture.remove() }
        let eventTimestamp = fixture.now.addingTimeInterval(-60)
        let usage = Self.usage(
            source: "Senpi",
            timestamps: [eventTimestamp, eventTimestamp, eventTimestamp])
        let descriptor = LocalUsageReaderDescriptor(
            reader: FixedTokenReader(name: "Senpi", usage: usage),
            sourceLocations: [])
        let limits = AgentSnapshotEventLimits(
            maximumTokenEventCount: 2,
            maximumCostEventCount: 2,
            maximumActivityEventCount: 2)
        let builder = AgentSnapshotBuilder(
            home: fixture.root,
            readerDescriptors: [descriptor],
            eventLimits: limits)

        let firstSnapshot = try await builder.build(
            configuration: fixture.configuration,
            now: fixture.now)
        let secondSnapshot = try await builder.build(
            configuration: fixture.configuration,
            now: fixture.now.addingTimeInterval(10))

        XCTAssertGreaterThan(firstSnapshot.coveredFrom, eventTimestamp)
        XCTAssertLessThan(firstSnapshot.coveredFrom, fixture.now)
        XCTAssertEqual(firstSnapshot.coveredFrom, secondSnapshot.coveredFrom)
        XCTAssertEqual(
            try builder.contentDigest(firstSnapshot),
            try builder.contentDigest(secondSnapshot))
    }
}

extension AgentSnapshotEventLimitTests {
    func test_snapshotChecksFittingFullWindowOnce() throws {
        let now = Date(timeIntervalSince1970: 1_788_000_000)
        let coveredFrom = now.addingTimeInterval(-300)
        var fitCheckCount = 0
        let bounder = AgentSnapshotEventBounder(
            limits: AgentSnapshotEventLimits(
                maximumTokenEventCount: 10,
                maximumCostEventCount: 10,
                maximumActivityEventCount: 10),
            envelopeFitCheck: { _, _ in
                fitCheckCount += 1
                return true
            })

        let snapshot = try bounder.snapshot(
            device: RemoteDeviceDescriptor(id: "device", name: "Device", platform: "linux"),
            generatedAt: now,
            coveredFrom: coveredFrom,
            coveredTo: now.addingTimeInterval(300),
            tokenEvents: [
                Self.highVolumeRemoteEvent(timestamp: now.addingTimeInterval(-120)),
                Self.highVolumeRemoteEvent(timestamp: now.addingTimeInterval(-60)),
            ],
            costEvents: [],
            activityEvents: [],
            encryptionKey: "test-key")

        XCTAssertEqual(snapshot.coveredFrom, coveredFrom)
        XCTAssertEqual(fitCheckCount, 1)
    }

    func test_snapshotDefersFutureEventsUntilTheyBecomeEligible() async throws {
        let fixture = try AgentSnapshotFixture()
        defer { fixture.remove() }
        let timestamps = [10.0, 20.0, 30.0].map(fixture.now.addingTimeInterval)
        let usage = Self.usage(source: "Senpi", timestamps: timestamps)
        let descriptor = LocalUsageReaderDescriptor(
            reader: FixedTokenReader(name: "Senpi", usage: usage),
            sourceLocations: [])
        let limits = AgentSnapshotEventLimits(
            maximumTokenEventCount: 2,
            maximumCostEventCount: 2,
            maximumActivityEventCount: 2)
        let builder = AgentSnapshotBuilder(
            home: fixture.root,
            readerDescriptors: [descriptor],
            eventLimits: limits)

        let firstSnapshot = try await builder.build(
            configuration: fixture.configuration,
            now: fixture.now)
        let pendingSignature = try await builder.sourceSignature(
            configuration: fixture.configuration,
            now: fixture.now.addingTimeInterval(9))
        let eligibleSignature = try await builder.sourceSignature(
            configuration: fixture.configuration,
            now: fixture.now.addingTimeInterval(10))
        let laterSnapshot = try await builder.build(
            configuration: fixture.configuration,
            now: fixture.now.addingTimeInterval(40))

        XCTAssertTrue(firstSnapshot.tokenEvents.isEmpty)
        XCTAssertNil(firstSnapshot.costEvents)
        XCTAssertTrue(firstSnapshot.activityEvents.isEmpty)
        XCTAssertNotEqual(pendingSignature, eligibleSignature)
        XCTAssertEqual(laterSnapshot.tokenEvents.map(\.timestamp), Array(timestamps.suffix(2)))
        XCTAssertEqual(laterSnapshot.costEvents?.map(\.timestamp), Array(timestamps.suffix(2)))
        XCTAssertEqual(laterSnapshot.activityEvents.map(\.timestamp), Array(timestamps.suffix(2)))
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

    private static func highVolumeRemoteEvent(timestamp: Date) -> RemoteTokenEvent {
        RemoteTokenEvent(
            timestamp: timestamp,
            source: "Senpi",
            model: String(repeating: "m", count: RemoteUsageSnapshotValidator.maximumModelLength),
            provider: "openrouter",
            inputTokens: RemoteUsageSnapshotValidator.maximumTokenCountPerBucket,
            outputTokens: RemoteUsageSnapshotValidator.maximumTokenCountPerBucket,
            cacheReadTokens: RemoteUsageSnapshotValidator.maximumTokenCountPerBucket,
            cacheWriteTokens: RemoteUsageSnapshotValidator.maximumTokenCountPerBucket,
            reasoningTokens: RemoteUsageSnapshotValidator.maximumTokenCountPerBucket,
            cost: RemoteUsageSnapshotValidator.maximumCostPerEvent)
    }
}
