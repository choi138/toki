import XCTest
@testable import Toki

final class ClaudeCodeReaderActivityTests: XCTestCase {
    func test_claudeCodeReader_deduplicatesActivityAcrossLogsForSameRequest() {
        let usage = ClaudeCodeReader.usage(
            fromJSONLSessions: [
                (
                    streamID: "project-a",
                    lines: [
                        claudeCodeReaderActivityLine(
                            timestamp: "2026-04-10T00:00:00Z",
                            requestId: "req-1",
                            messageID: "msg-1",
                            model: "claude-sonnet-4-6",
                            input: 10,
                            output: 2),
                        claudeCodeReaderActivityLine(
                            timestamp: "2026-04-10T00:01:00Z",
                            requestId: "req-1",
                            messageID: "msg-1",
                            model: "claude-sonnet-4-6",
                            input: 10,
                            output: 4),
                    ]),
                (
                    streamID: "project-b",
                    lines: [
                        claudeCodeReaderActivityLine(
                            timestamp: "2026-04-10T00:02:00Z",
                            requestId: "req-1",
                            messageID: "msg-1",
                            model: "claude-sonnet-4-6",
                            input: 10,
                            output: 7),
                    ]),
            ],
            from: claudeCodeReaderActivityISODate("2026-04-10T00:00:00Z"),
            to: claudeCodeReaderActivityISODate("2026-04-11T00:00:00Z"))

        XCTAssertEqual(usage.totalTokens, 17)
        XCTAssertEqual(usage.activeSeconds, 90, accuracy: 0.001)
        XCTAssertEqual(
            usage.perModel["claude-sonnet-4-6"]?.activeSeconds ?? 0,
            90,
            accuracy: 0.001)
    }
}

private func claudeCodeReaderActivityLine(
    timestamp: String,
    requestId: String,
    messageID: String,
    model: String,
    input: Int,
    output: Int,
    cacheRead: Int = 0,
    cacheWrite: Int = 0) -> String {
    """
    {"type":"assistant","timestamp":"\(timestamp)","requestId":"\(requestId)",\
    "message":{"id":"\(messageID)","model":"\(model)","usage":{\
    "input_tokens":\(input),"output_tokens":\(output),"cache_read_input_tokens":\(cacheRead),\
    "cache_creation_input_tokens":\(cacheWrite)}}}
    """
}

private func claudeCodeReaderActivityISODate(_ value: String) -> Date {
    guard let date = DateParser.parse(value) else {
        XCTFail("Failed to parse ISO date: \(value)")
        return Date.distantPast
    }
    return date
}
