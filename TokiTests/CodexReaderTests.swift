import XCTest
@testable import Toki

// swiftlint:disable:next type_body_length
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

    func test_codexRolloutDailySummaryBuildsTotalsActivityAndTokenEventsInTimestampOrder() {
        let lines = [
            tokenCountLine(
                ts: "2026-04-10T13:00:00Z",
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

        let summary = codexRolloutDailySummary(
            fromSnapshots: codexRolloutSnapshots(fromRolloutLines: lines))
        let daySummary = summary.dailyUsage["2026-04-10"]

        XCTAssertEqual(daySummary?.inputTokens, 140)
        XCTAssertEqual(daySummary?.cacheReadTokens, 30)
        XCTAssertEqual(daySummary?.outputTokens, 30)
        XCTAssertEqual(daySummary?.reasoningTokens, 10)
        XCTAssertEqual(daySummary?.totalTokens, 210)
        XCTAssertEqual(summary.dailyActivityTimestamps["2026-04-10"]?.count, 2)
        XCTAssertEqual(summary.dailyTokenUsageEvents["2026-04-10"]?.map(\.totalTokens), [150, 60])
    }

    func test_codexRolloutDailySummaryStreamsJsonlWithoutMaterializingLines() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let url = directory.appendingPathComponent("rollout.jsonl")
        let content = [
            tokenCountLine(
                ts: "2026-04-10T00:01:00Z",
                input: 100,
                cachedInput: 10,
                output: 20,
                reasoning: 5,
                total: 125),
            tokenCountLine(
                ts: "2026-04-10T00:02:00Z",
                input: 130,
                cachedInput: 20,
                output: 35,
                reasoning: 10,
                total: 165),
        ].joined(separator: "\n")
        try content.write(to: url, atomically: true, encoding: .utf8)

        let summary = codexRolloutDailySummary(fromRolloutAt: url)

        XCTAssertEqual(summary.dailyUsage["2026-04-10"]?.totalTokens, 165)
        XCTAssertEqual(summary.dailyTokenUsageEvents["2026-04-10"]?.map(\.totalTokens), [120, 45])
    }

    func test_codexReaderSkipsJsonlLookupWhenDatabaseHasCompleteAttribution() {
        let skippedPaths = CodexReader().pathsWithCompleteDatabaseAttribution(
            in: [
                CodexSession(rolloutPath: "/tmp/main-with-model.jsonl", model: "gpt-5.4"),
                CodexSession(rolloutPath: "/tmp/subagent-with-model.jsonl", model: "gpt-5.4", agentKind: .subagent),
                CodexSession(rolloutPath: "/tmp/subagent-without-model.jsonl", model: nil, agentKind: .subagent),
                CodexSession(
                    rolloutPath: "/tmp/model-without-source.jsonl",
                    model: "gpt-5.4",
                    hasSourceAttribution: false),
            ])

        XCTAssertEqual(skippedPaths, ["/tmp/main-with-model.jsonl", "/tmp/subagent-with-model.jsonl"])
    }

    func test_codexReaderMergesJsonlSourceAttributionWhenDatabaseSourceIsMissing() {
        let merged = CodexReader().mergedSessions(
            databaseSessions: [
                CodexSession(
                    rolloutPath: "/tmp/rollout-a.jsonl",
                    model: "gpt-5.4",
                    hasSourceAttribution: false),
            ],
            jsonlSessions: [
                CodexSession(
                    rolloutPath: "/tmp/rollout-a.jsonl",
                    model: nil,
                    agentKind: .subagent,
                    hasSourceAttribution: true),
            ])

        XCTAssertEqual(merged.count, 1)
        XCTAssertEqual(merged.first?.model, "gpt-5.4")
        XCTAssertEqual(merged.first?.agentKind, .subagent)
        XCTAssertEqual(merged.first?.hasSourceAttribution, true)
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
