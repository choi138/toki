import XCTest
@testable import Toki

final class CodexReaderBehaviorTests: XCTestCase {
    func test_codexReader_keepsRolloutStreamsSeparatedWhenMergingActivity() {
        let first = CodexReader.usage(
            fromRolloutLines: [
                tokenCountLine(
                    ts: "2026-04-10T00:00:00Z",
                    input: 120,
                    cachedInput: 20,
                    output: 30,
                    reasoning: 5,
                    total: 150),
                tokenCountLine(
                    ts: "2026-04-10T00:02:00Z",
                    input: 160,
                    cachedInput: 20,
                    output: 40,
                    reasoning: 10,
                    total: 200),
            ],
            model: "gpt-5.4-mini",
            from: codexBehaviorISODate("2026-04-10T00:00:00Z"),
            to: codexBehaviorISODate("2026-04-10T23:00:00Z"),
            streamID: "rollout-a")
        let second = CodexReader.usage(
            fromRolloutLines: [
                tokenCountLine(
                    ts: "2026-04-10T00:04:00Z",
                    input: 120,
                    cachedInput: 20,
                    output: 30,
                    reasoning: 5,
                    total: 150),
                tokenCountLine(
                    ts: "2026-04-10T00:06:00Z",
                    input: 160,
                    cachedInput: 20,
                    output: 40,
                    reasoning: 10,
                    total: 200),
            ],
            model: "gpt-5.4-mini",
            from: codexBehaviorISODate("2026-04-10T00:00:00Z"),
            to: codexBehaviorISODate("2026-04-10T23:00:00Z"),
            streamID: "rollout-b")

        var combined = RawTokenUsage()
        combined += first
        combined += second
        combined.recomputeMergedActiveEstimate()

        XCTAssertEqual(combined.activeSeconds, 300, accuracy: 0.001)
    }

    func test_codexReader_mergesMissingDatabaseModelFromJsonlSession() {
        let merged = CodexReader().mergedSessions(
            databaseSessions: [
                CodexSession(rolloutPath: "/tmp/rollout-a.jsonl", model: nil),
            ],
            jsonlSessions: [
                CodexSession(rolloutPath: "/tmp/rollout-a.jsonl", model: "gpt-5.4"),
            ])

        XCTAssertEqual(merged.count, 1)
        XCTAssertEqual(merged.first?.model, "gpt-5.4")
    }

    private func tokenCountLine(
        ts: String,
        input: Int,
        cachedInput: Int,
        output: Int,
        reasoning: Int,
        total: Int) -> String {
        let usage = [
            "\"input_tokens\":\(input)",
            "\"cached_input_tokens\":\(cachedInput)",
            "\"output_tokens\":\(output)",
            "\"reasoning_output_tokens\":\(reasoning)",
            "\"total_tokens\":\(total)",
        ].joined(separator: ",")
        return """
        {"timestamp":"\(ts)","type":"event_msg",\
        "payload":{"type":"token_count","info":{"total_token_usage":{\(usage)}}}}
        """
    }
}

private func codexBehaviorISODate(_ value: String) -> Date {
    guard let date = DateParser.parse(value) else {
        XCTFail("Failed to parse ISO date: \(value)")
        return Date.distantPast
    }
    return date
}
