import Foundation
import XCTest
@testable import TokiSyncProtocol

final class UsageSnapshotProviderTests: XCTestCase {
    func test_remoteTokenEventRoundTripsEveryCostKnownState() throws {
        let fixtures: [(cost: Double?, costIsKnown: Bool?)] = [
            (nil, nil),
            (nil, false),
            (0, false),
            (0, true),
            (0.25, true),
        ]

        for fixture in fixtures {
            let event = tokenEvent(
                cost: fixture.cost,
                costIsKnown: fixture.costIsKnown)
            let decoded = try TokiSyncCoding.makeDecoder().decode(
                RemoteTokenEvent.self,
                from: TokiSyncCoding.makeEncoder().encode(event))

            XCTAssertEqual(decoded.cost, fixture.cost)
            XCTAssertEqual(decoded.costIsKnown, fixture.costIsKnown)
        }
    }

    func test_remoteTokenEventDecodesOlderPayloadWithoutProvider() throws {
        let data = Data(
            """
            {
              "timestamp":1765756800000,
              "source":"Kimi CLI",
              "model":"kimi-k2.5",
              "inputTokens":1,
              "outputTokens":2,
              "cacheReadTokens":0,
              "cacheWriteTokens":0,
              "reasoningTokens":0
            }
            """.utf8)

        let event = try TokiSyncCoding.makeDecoder().decode(RemoteTokenEvent.self, from: data)

        XCTAssertNil(event.provider)
        XCTAssertNil(event.costIsKnown)
        XCTAssertEqual(event.totalTokens, 3)
    }

    func test_remoteTokenEventRoundTripsRecordedProvider() throws {
        let event = RemoteTokenEvent(
            timestamp: Date(timeIntervalSince1970: 1_765_756_800),
            source: "Kimi CLI",
            model: "moonshotai/kimi-k2.5",
            provider: "openrouter",
            inputTokens: 1,
            outputTokens: 2,
            cacheReadTokens: 3,
            cacheWriteTokens: 4,
            reasoningTokens: 5)

        let decoded = try TokiSyncCoding.makeDecoder().decode(
            RemoteTokenEvent.self,
            from: TokiSyncCoding.makeEncoder().encode(event))

        XCTAssertEqual(decoded, event)
        XCTAssertEqual(decoded.provider, "openrouter")
    }

    func test_snapshotValidationRequiresCostWhenPriceIsKnown() throws {
        let now = Date(timeIntervalSince1970: 1_765_756_800)
        let knownZero = RemoteTokenEvent(
            timestamp: now,
            source: "Kimi CLI",
            model: "kimi-k2.5",
            provider: "moonshot",
            inputTokens: 1,
            outputTokens: 0,
            cacheReadTokens: 0,
            cacheWriteTokens: 0,
            reasoningTokens: 0,
            cost: 0,
            costIsKnown: true)
        let missingKnownCost = RemoteTokenEvent(
            timestamp: now,
            source: "Kimi CLI",
            model: "kimi-k2.5",
            provider: "moonshot",
            inputTokens: 1,
            outputTokens: 0,
            cacheReadTokens: 0,
            cacheWriteTokens: 0,
            reasoningTokens: 0,
            costIsKnown: true)
        let unknownZero = RemoteTokenEvent(
            timestamp: now,
            source: "Kimi CLI",
            model: "kimi-k2.5",
            provider: "moonshot",
            inputTokens: 1,
            outputTokens: 0,
            cacheReadTokens: 0,
            cacheWriteTokens: 0,
            reasoningTokens: 0,
            cost: 0,
            costIsKnown: false)
        let missingUnknownCost = RemoteTokenEvent(
            timestamp: now,
            source: "Kimi CLI",
            model: "kimi-k2.5",
            provider: "moonshot",
            inputTokens: 1,
            outputTokens: 0,
            cacheReadTokens: 0,
            cacheWriteTokens: 0,
            reasoningTokens: 0,
            costIsKnown: false)
        let positiveUnknownCost = RemoteTokenEvent(
            timestamp: now,
            source: "Kimi CLI",
            model: "kimi-k2.5",
            provider: "moonshot",
            inputTokens: 1,
            outputTokens: 0,
            cacheReadTokens: 0,
            cacheWriteTokens: 0,
            reasoningTokens: 0,
            cost: 1,
            costIsKnown: false)

        XCTAssertNoThrow(try RemoteUsageSnapshotValidator.validate(
            snapshot(event: knownZero, now: now),
            now: now))
        XCTAssertThrowsError(try RemoteUsageSnapshotValidator.validate(
            snapshot(event: missingKnownCost, now: now),
            now: now))
        XCTAssertNoThrow(try RemoteUsageSnapshotValidator.validate(
            snapshot(event: unknownZero, now: now),
            now: now))
        XCTAssertNoThrow(try RemoteUsageSnapshotValidator.validate(
            snapshot(event: missingUnknownCost, now: now),
            now: now))
        XCTAssertThrowsError(try RemoteUsageSnapshotValidator.validate(
            snapshot(event: positiveUnknownCost, now: now),
            now: now))
    }

    private func snapshot(event: RemoteTokenEvent, now: Date) -> RemoteUsageSnapshot {
        RemoteUsageSnapshot(
            device: RemoteDeviceDescriptor(id: "device", name: "Mac", platform: "macos"),
            generatedAt: now,
            coveredFrom: now.addingTimeInterval(-60),
            coveredTo: now.addingTimeInterval(60),
            tokenEvents: [event],
            activityEvents: [])
    }

    func test_validatorAcceptsSupportedCostStates() {
        let fixtures: [(cost: Double?, costIsKnown: Bool?)] = [
            (nil, nil),
            (nil, false),
            (0, nil),
            (0, false),
            (0, true),
            (0.25, true),
        ]

        for fixture in fixtures {
            let snapshot = snapshot(tokenEvent: tokenEvent(
                cost: fixture.cost,
                costIsKnown: fixture.costIsKnown))

            XCTAssertNoThrow(try RemoteUsageSnapshotValidator.validate(
                snapshot,
                now: snapshot.generatedAt))
        }
    }

    func test_validatorRejectsInconsistentCostStates() {
        let fixtures: [(cost: Double?, costIsKnown: Bool?)] = [
            (nil, true),
            (0.01, false),
            (-0.01, nil),
            (.nan, true),
        ]

        for fixture in fixtures {
            let event = tokenEvent(
                cost: fixture.cost,
                costIsKnown: fixture.costIsKnown)
            let snapshot = snapshot(tokenEvent: event)
            XCTAssertThrowsError(try RemoteUsageSnapshotValidator.validate(
                snapshot,
                now: snapshot.generatedAt)) { error in
                    guard case RemoteUsageSnapshotValidationError.invalidTokenEvent = error else {
                        return XCTFail("Unexpected validation error: \(error)")
                    }
                }
        }
    }

    private func tokenEvent(
        cost: Double? = nil,
        costIsKnown: Bool? = nil) -> RemoteTokenEvent {
        RemoteTokenEvent(
            timestamp: Date(timeIntervalSince1970: 1_765_756_800),
            source: "Pi",
            model: "gpt-5",
            provider: "openai",
            inputTokens: 1,
            outputTokens: 2,
            cacheReadTokens: 0,
            cacheWriteTokens: 0,
            reasoningTokens: 0,
            cost: cost,
            costIsKnown: costIsKnown)
    }

    private func snapshot(tokenEvent: RemoteTokenEvent) -> RemoteUsageSnapshot {
        RemoteUsageSnapshot(
            device: RemoteDeviceDescriptor(
                id: "device-1",
                name: "Device",
                platform: "linux"),
            generatedAt: tokenEvent.timestamp,
            coveredFrom: tokenEvent.timestamp.addingTimeInterval(-60),
            coveredTo: tokenEvent.timestamp.addingTimeInterval(60),
            tokenEvents: [tokenEvent],
            activityEvents: [])
    }
}
