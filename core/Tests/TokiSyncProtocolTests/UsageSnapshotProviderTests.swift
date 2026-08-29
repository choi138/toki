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
}
