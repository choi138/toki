import XCTest
@testable import TokiUsageReaders

final class PiCompatibleDeduplicationTests: XCTestCase {
    func test_messageIDsRemainIndependentAcrossMainSessions() {
        let lines = [
            sessionLine(id: "session-a"),
            messageLine(id: "shared-message", timestamp: "2026-08-01T12:00:00Z", input: 3),
            sessionLine(id: "session-b"),
            messageLine(id: "shared-message", timestamp: "2026-08-01T12:01:00Z", input: 7),
        ]

        let usage = PiReader.usage(
            fromJSONLLines: lines,
            streamID: "message-scope",
            from: deduplicationDate("2026-08-01T00:00:00Z"),
            to: deduplicationDate("2026-08-02T00:00:00Z"))

        XCTAssertEqual(usage.inputTokens, 10)
        XCTAssertEqual(usage.tokenEvents.count, 2)
    }

    func test_idlessResponseIDsRemainScopedToSessionAndProvider() {
        let lines = [
            sessionLine(id: "session-a"),
            responseLine(
                timestamp: "2026-08-01T12:00:00Z",
                model: "gpt-5",
                provider: "openai",
                input: 3,
                output: 2),
            responseLine(
                timestamp: "2026-08-01T12:01:00Z",
                model: "claude-opus-5",
                provider: "anthropic",
                input: 5,
                output: 4),
            sessionLine(id: "session-b"),
            responseLine(
                timestamp: "2026-08-01T12:02:00Z",
                model: "gpt-5",
                provider: "openai",
                input: 7,
                output: 6),
        ]

        let usage = PiReader.usage(
            fromJSONLLines: lines,
            streamID: "response-scope",
            from: deduplicationDate("2026-08-01T00:00:00Z"),
            to: deduplicationDate("2026-08-02T00:00:00Z"))

        XCTAssertEqual(usage.inputTokens, 15)
        XCTAssertEqual(usage.outputTokens, 12)
        XCTAssertEqual(usage.tokenEvents.count, 3)
    }

    private func sessionLine(id: String) -> String {
        #"{"type":"session","id":"\#(id)","timestamp":"2026-08-01T08:00:00Z"}"#
    }

    private func messageLine(id: String, timestamp: String, input: Int) -> String {
        [
            #"{"type":"message","id":"\#(id)","timestamp":"\#(timestamp)","message":{"#,
            #""role":"assistant","model":"gpt-5","usage":{"input":\#(input),"output":1}}}"#,
        ].joined()
    }

    private func responseLine(
        timestamp: String,
        model: String,
        provider: String,
        input: Int,
        output: Int) -> String {
        [
            #"{"type":"message","timestamp":"\#(timestamp)","message":{"role":"assistant","#,
            #""model":"\#(model)","provider":"\#(provider)","responseId":"shared-response","#,
            #""usage":{"input":\#(input),"output":\#(output)}}}"#,
        ].joined()
    }
}

private func deduplicationDate(_ value: String) -> Date {
    ISO8601DateFormatter().date(from: value)!
}
