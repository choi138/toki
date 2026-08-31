import Foundation
import TokiUsageCore
import XCTest

final class TokenUsageEventValidationTests: XCTestCase {
    func test_publicInitializerNeutralizesUnsupportedTokenCounts() {
        let event = TokenUsageEvent(
            timestamp: Date(timeIntervalSinceReferenceDate: 0),
            source: "Test",
            model: "gpt-5",
            inputTokens: 1_000_000_001,
            outputTokens: 5,
            cacheReadTokens: 0,
            cacheWriteTokens: 0,
            reasoningTokens: 0,
            cost: 0)

        XCTAssertEqual(event.inputTokens, 0)
        XCTAssertEqual(event.outputTokens, 0)
        XCTAssertEqual(event.totalTokens, 0)
    }

    func test_decoderRejectsUnsupportedTokenCounts() {
        let json = [
            #"{"timestamp":0,"source":"Test","inputTokens":1000000001,"#,
            #""outputTokens":5,"cacheReadTokens":0,"cacheWriteTokens":0,"#,
            #""reasoningTokens":0,"cost":0}"#,
        ].joined()
        let payload = Data(json.utf8)

        XCTAssertThrowsError(try JSONDecoder().decode(TokenUsageEvent.self, from: payload))
    }

    func test_validEventStillRoundTrips() throws {
        let event = TokenUsageEvent(
            timestamp: Date(timeIntervalSinceReferenceDate: 123),
            source: "Test",
            model: "gpt-5",
            provider: "openai",
            inputTokens: 7,
            outputTokens: 5,
            cacheReadTokens: 3,
            cacheWriteTokens: 2,
            reasoningTokens: 1,
            cost: 0.25,
            costIsKnown: true)

        let decoded = try JSONDecoder().decode(
            TokenUsageEvent.self,
            from: JSONEncoder().encode(event))

        XCTAssertEqual(decoded, event)
    }
}
