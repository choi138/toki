import XCTest
@testable import Toki

final class CodexReaderTests: XCTestCase {
    func test_codexReader_usesBaselineBeforeRangeAndDeduplicatesSnapshots() {
        let lines = [
            tokenCountLine(
                ts: "2026-04-09T14:59:00Z",
                input: 100,
                cachedInput: 20,
                output: 40,
                reasoning: 10,
                total: 140),
            tokenCountLine(
                ts: "2026-04-10T00:01:00Z",
                input: 140,
                cachedInput: 30,
                output: 55,
                reasoning: 15,
                total: 195),
            tokenCountLine(
                ts: "2026-04-10T00:02:00Z",
                input: 140,
                cachedInput: 30,
                output: 55,
                reasoning: 15,
                total: 195),
            tokenCountLine(
                ts: "2026-04-10T00:03:00Z",
                input: 200,
                cachedInput: 50,
                output: 80,
                reasoning: 20,
                total: 280),
        ]

        let usage = CodexReader.usage(
            fromRolloutLines: lines,
            model: "gpt-5.4",
            from: isoDate("2026-04-10T00:00:00Z"),
            to: isoDate("2026-04-11T00:00:00Z"),
            streamID: "rollout-a")

        XCTAssertEqual(usage.inputTokens, 70)
        XCTAssertEqual(usage.cacheReadTokens, 30)
        XCTAssertEqual(usage.outputTokens, 30)
        XCTAssertEqual(usage.reasoningTokens, 10)
        XCTAssertEqual(usage.totalTokens, 140)
        XCTAssertEqual(usage.tokenEvents.map(\.totalTokens), [55, 85])
        XCTAssertEqual(usage.tokenEvents.first?.timestamp, isoDate("2026-04-10T00:01:00Z"))
        XCTAssertEqual(usage.perModel["gpt-5.4"]?.totalTokens, 140)
        let expectedCost = modelPrice(for: "gpt-5.4")?.cost(
            input: usage.inputTokens,
            output: usage.outputTokens + usage.reasoningTokens,
            cacheRead: usage.cacheReadTokens,
            cacheWrite: 0)
        XCTAssertEqual(usage.cost, expectedCost ?? 0, accuracy: 0.000001)
    }

    func test_codexReader_countsInitialSnapshotWhenSessionStartsInsideRange() {
        let lines = [
            tokenCountLine(
                ts: "2026-04-10T09:00:00Z",
                input: 120,
                cachedInput: 20,
                output: 30,
                reasoning: 5,
                total: 150),
        ]

        let usage = CodexReader.usage(
            fromRolloutLines: lines,
            model: "gpt-5.4-mini",
            from: isoDate("2026-04-10T00:00:00Z"),
            to: isoDate("2026-04-11T00:00:00Z"),
            streamID: "rollout-a")

        XCTAssertEqual(usage.inputTokens, 100)
        XCTAssertEqual(usage.cacheReadTokens, 20)
        XCTAssertEqual(usage.outputTokens, 25)
        XCTAssertEqual(usage.reasoningTokens, 5)
        XCTAssertEqual(usage.totalTokens, 150)
        XCTAssertEqual(usage.perModel["gpt-5.4-mini"]?.totalTokens, 150)
        let expectedCost = modelPrice(for: "gpt-5.4-mini")?.cost(
            input: usage.inputTokens,
            output: usage.outputTokens + usage.reasoningTokens,
            cacheRead: usage.cacheReadTokens,
            cacheWrite: 0)
        XCTAssertEqual(usage.cost, expectedCost ?? 0, accuracy: 0.000001)
    }

    func test_codexReader_respects_partialDayRange() {
        let lines = [
            tokenCountLine(
                ts: "2026-04-10T08:00:00Z",
                input: 120,
                cachedInput: 20,
                output: 30,
                reasoning: 5,
                total: 150),
            tokenCountLine(
                ts: "2026-04-10T15:00:00Z",
                input: 170,
                cachedInput: 30,
                output: 40,
                reasoning: 10,
                total: 220),
        ]

        let usage = CodexReader.usage(
            fromRolloutLines: lines,
            model: "gpt-5.4-mini",
            from: isoDate("2026-04-10T12:00:00Z"),
            to: isoDate("2026-04-10T23:00:00Z"),
            streamID: "rollout-a")

        XCTAssertEqual(usage.inputTokens, 40)
        XCTAssertEqual(usage.cacheReadTokens, 10)
        XCTAssertEqual(usage.outputTokens, 5)
        XCTAssertEqual(usage.reasoningTokens, 5)
        XCTAssertEqual(usage.totalTokens, 60)
    }

    func test_codexReader_respectsPartialDayRangeWithOutOfOrderSnapshots() {
        let lines = [
            tokenCountLine(
                ts: "2026-04-10T15:00:00Z",
                input: 170,
                cachedInput: 30,
                output: 40,
                reasoning: 10,
                total: 220),
            tokenCountLine(
                ts: "2026-04-10T10:00:00Z",
                input: 120,
                cachedInput: 20,
                output: 30,
                reasoning: 5,
                total: 150),
        ]

        let usage = CodexReader.usage(
            fromRolloutLines: lines,
            model: "gpt-5.4-mini",
            from: isoDate("2026-04-10T12:00:00Z"),
            to: isoDate("2026-04-10T23:00:00Z"),
            streamID: "rollout-a")

        XCTAssertEqual(usage.inputTokens, 40)
        XCTAssertEqual(usage.cacheReadTokens, 10)
        XCTAssertEqual(usage.outputTokens, 5)
        XCTAssertEqual(usage.reasoningTokens, 5)
        XCTAssertEqual(usage.totalTokens, 60)
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

    private func isoDate(_ value: String) -> Date {
        guard let date = DateParser.parse(value) else {
            XCTFail("Failed to parse ISO date: \(value)")
            return Date.distantPast
        }
        return date
    }
}
