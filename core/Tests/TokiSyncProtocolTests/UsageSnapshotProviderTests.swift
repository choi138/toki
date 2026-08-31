import Foundation
import XCTest
@testable import TokiSyncProtocol

final class UsageSnapshotProviderTests: XCTestCase {
    func test_remoteTokenEventDecodesOlderPayloadWithoutProvider() throws {
        let data = Data(
            """
            {
              "timestamp":1765756800000,
              "source":"GitHub Copilot CLI",
              "model":"gpt-5.4",
              "inputTokens":1,
              "outputTokens":2,
              "cacheReadTokens":0,
              "cacheWriteTokens":0,
              "reasoningTokens":0
            }
            """.utf8)

        let event = try TokiSyncCoding.makeDecoder().decode(RemoteTokenEvent.self, from: data)

        XCTAssertNil(event.provider)
        XCTAssertEqual(event.totalTokens, 3)
    }

    func test_remoteTokenEventRoundTripsRecordedProvider() throws {
        let event = RemoteTokenEvent(
            timestamp: Date(timeIntervalSince1970: 1_765_756_800),
            source: "GitHub Copilot CLI",
            model: "claude-sonnet-4.6",
            provider: "github",
            inputTokens: 1,
            outputTokens: 2,
            cacheReadTokens: 3,
            cacheWriteTokens: 4,
            reasoningTokens: 5)

        let decoded = try TokiSyncCoding.makeDecoder().decode(
            RemoteTokenEvent.self,
            from: TokiSyncCoding.makeEncoder().encode(event))

        XCTAssertEqual(decoded, event)
        XCTAssertEqual(decoded.provider, "github")
    }

    func test_snapshotRejectsKnownCostWithoutValue() throws {
        let start = Date(timeIntervalSince1970: 1_765_756_800)
        let end = start.addingTimeInterval(3600)
        let snapshot = RemoteUsageSnapshot(
            device: RemoteDeviceDescriptor(
                id: "device-1",
                name: "build-server",
                platform: "linux"),
            generatedAt: start.addingTimeInterval(120),
            coveredFrom: start,
            coveredTo: end,
            tokenEvents: [
                RemoteTokenEvent(
                    timestamp: start.addingTimeInterval(60),
                    source: "Factory Droid",
                    model: "known-cost-model",
                    inputTokens: 1,
                    outputTokens: 0,
                    cacheReadTokens: 0,
                    cacheWriteTokens: 0,
                    reasoningTokens: 0,
                    cost: nil,
                    costIsKnown: true),
            ],
            activityEvents: [])
        let validate = {
            try RemoteUsageSnapshotValidator.validate(snapshot, now: end)
        }

        XCTAssertThrowsError(try validate()) { error in
            guard case RemoteUsageSnapshotValidationError.invalidTokenEvent = error else {
                return XCTFail("Expected invalidTokenEvent, got \(error)")
            }
        }
    }
}
