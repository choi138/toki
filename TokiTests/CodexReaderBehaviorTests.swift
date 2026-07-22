import TokiUsageCore
import XCTest
@testable import Toki
@testable import TokiUsageReaders

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
        XCTAssertEqual(combined.workTime.wallClockSeconds, 300, accuracy: 0.001)
        XCTAssertEqual(combined.workTime.activeStreamCount, 2)
        XCTAssertEqual(combined.workTime.maxConcurrentStreams, 1)
    }

    func test_codexReader_marksSubagentRolloutWorkTime() {
        let usage = CodexReader.usage(
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
            streamID: "rollout-a",
            agentKind: .subagent)

        XCTAssertEqual(usage.workTime.agentSeconds, 150, accuracy: 0.001)
        XCTAssertEqual(usage.workTime.mainAgentSeconds, 0, accuracy: 0.001)
        XCTAssertEqual(usage.workTime.subagentSeconds, 150, accuracy: 0.001)
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

    func test_codexReader_preservesSubagentKindWhenMergingDuplicateSessions() {
        let merged = CodexReader().mergedSessions(
            databaseSessions: [
                CodexSession(rolloutPath: "/tmp/rollout-a.jsonl", model: "gpt-5.4"),
            ],
            jsonlSessions: [
                CodexSession(rolloutPath: "/tmp/rollout-a.jsonl", model: nil, agentKind: .subagent),
            ])

        XCTAssertEqual(merged.count, 1)
        XCTAssertEqual(merged.first?.agentKind, .subagent)
    }

    func test_codexReader_skipsJsonlLookupWhenDatabaseHasModelAndSourceAttribution() {
        let skippedPaths = CodexReader().pathsWithCompleteDatabaseAttribution(
            in: [
                CodexSession(
                    rolloutPath: "/tmp/main-with-model.jsonl",
                    model: "gpt-5.4",
                    projectPath: "/tmp/project-a",
                    projectAttributionQuality: .exact),
                CodexSession(
                    rolloutPath: "/tmp/subagent-with-model.jsonl",
                    model: "gpt-5.4",
                    agentKind: .subagent,
                    projectPath: "/tmp/project-b",
                    projectAttributionQuality: .exact),
                CodexSession(rolloutPath: "/tmp/subagent-without-model.jsonl", model: nil, agentKind: .subagent),
                CodexSession(
                    rolloutPath: "/tmp/model-without-source.jsonl",
                    model: "gpt-5.4",
                    hasSourceAttribution: false,
                    projectPath: "/tmp/project-c",
                    projectAttributionQuality: .exact),
            ])

        XCTAssertEqual(skippedPaths, ["/tmp/main-with-model.jsonl", "/tmp/subagent-with-model.jsonl"])
    }
}

extension CodexReaderBehaviorTests {
    func test_codexReader_mergesJsonlSourceAttributionWhenDatabaseSourceIsMissing() {
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

    func test_codexAgentKindDetectsSubagentSource() {
        XCTAssertEqual(codexAgentKind(fromSource: "cli"), .main)
        XCTAssertEqual(codexAgentKind(fromSource: #"{"subagent":"review"}"#), .subagent)
        XCTAssertEqual(
            codexAgentKind(
                fromSource: #"{"subagent":{"thread_spawn":{"parent_thread_id":"parent","depth":1}}}"#),
            .subagent)
    }

    func test_codexReader_prefersDatabaseModelWhenDuplicateRowsIncludeNil() {
        let merged = CodexReader().mergedSessions(
            databaseSessions: [
                CodexSession(rolloutPath: "/tmp/rollout-a.jsonl", model: "gpt-5.4"),
                CodexSession(rolloutPath: "/tmp/rollout-a.jsonl", model: nil),
            ],
            jsonlSessions: [])

        XCTAssertEqual(merged.count, 1)
        XCTAssertEqual(merged.first?.model, "gpt-5.4")
    }

    func test_codexReader_preservesCachedDailyUsageWhenTimestampBackfillIsEmpty() {
        let preservedUsage = [
            "2026-04-10": CodexCachedDailyUsage(
                inputTokens: 10,
                outputTokens: 20,
                cacheReadTokens: 5,
                reasoningTokens: 3,
                activeSeconds: 60),
        ]

        let merged = CodexReader.dailyUsageForTimestampBackfill(
            rebuiltDailyUsage: [:],
            existingDailyUsage: preservedUsage)

        XCTAssertEqual(merged["2026-04-10"]?.totalTokens, 38)
        XCTAssertEqual(merged["2026-04-10"]?.activeSeconds ?? 0, 60, accuracy: 0.001)
    }

    func test_codexReader_tokenHelpersSumSparseDailyUsageForWideRanges() throws {
        let calendar = Calendar.current
        let firstDay = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 4, day: 10)))
        let secondDay = try XCTUnwrap(calendar.date(byAdding: .day, value: 1, to: firstDay))
        let endDay = try XCTUnwrap(calendar.date(byAdding: .day, value: 3, to: firstDay))
        let excludedDay = try XCTUnwrap(calendar.date(byAdding: .day, value: 1, to: endDay))
        let allTimeStart = calendar.startOfDay(for: Date(timeIntervalSince1970: 0))
        let dailyUsage = [
            codexDayKey(for: firstDay): CodexCachedDailyUsage(inputTokens: 10),
            codexDayKey(for: secondDay): CodexCachedDailyUsage(outputTokens: 20),
            codexDayKey(for: excludedDay): CodexCachedDailyUsage(inputTokens: 999),
        ]

        let totalTokens = CodexReader.totalTokens(
            fromDailyUsage: dailyUsage,
            from: allTimeStart,
            to: endDay)
        let outputTokens = CodexReader.outputTokens(
            fromDailyUsage: dailyUsage,
            from: allTimeStart,
            to: endDay)

        XCTAssertEqual(totalTokens, 30)
        XCTAssertEqual(outputTokens, 20)
    }

    func test_codexReader_stripsCachedActiveTimeWhenRolloutEventsExist() {
        var usage = RawTokenUsage()
        usage.activeSeconds = 3600
        usage.perModel["gpt-5.4"] = PerModelUsage(
            totalTokens: 120,
            cost: 1.2,
            activeSeconds: 3600,
            sources: ["Codex"])

        let sanitizedUsage = CodexReader.strippingCachedActiveTime(
            from: usage,
            whenActivityEventsExist: [
                ActivityTimeEvent(
                    streamID: "rollout-a",
                    timestamp: codexBehaviorISODate("2026-04-10T00:00:00Z"),
                    key: "gpt-5.4"),
            ])

        XCTAssertEqual(sanitizedUsage.activeSeconds, 0, accuracy: 0.001)
        XCTAssertEqual(sanitizedUsage.perModel["gpt-5.4"]?.activeSeconds ?? 0, 0, accuracy: 0.001)
        XCTAssertEqual(sanitizedUsage.perModel["gpt-5.4"]?.totalTokens, 120)
    }

    func test_codexReaderSkipsSymlinkedArchivedSessionWithoutDatabaseRow() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("toki-codex-symlink-tests-\(UUID().uuidString)", isDirectory: true)
        let archiveDirectory = directory.appendingPathComponent("archived_sessions", isDirectory: true)
        try FileManager.default.createDirectory(at: archiveDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let databaseURL = directory.appendingPathComponent("state_5.sqlite")
        try createSecurityAuditSQLiteDB(
            at: databaseURL,
            statements: [
                """
                CREATE TABLE threads (
                    rollout_path TEXT NOT NULL,
                    model TEXT,
                    source TEXT,
                    cwd TEXT,
                    created_at INTEGER NOT NULL,
                    updated_at INTEGER NOT NULL
                )
                """,
            ])
        let targetURL = directory.appendingPathComponent("outside-session.jsonl")
        let linkURL = archiveDirectory.appendingPathComponent("linked-session.jsonl")
        let lines = [
            #"{"timestamp":"2026-04-10T08:59:58Z","type":"session_meta","payload":{"id":"linked-session"}}"#,
            tokenCountLine(
                ts: "2026-04-10T09:00:00Z",
                input: 120,
                cachedInput: 20,
                output: 30,
                reasoning: 5,
                total: 150),
        ]
        try Data((lines.joined(separator: "\n") + "\n").utf8).write(to: targetURL)
        try FileManager.default.createSymbolicLink(at: linkURL, withDestinationURL: targetURL)
        let reader = CodexReader(dbPath: databaseURL.path)
        let startDate = codexBehaviorISODate("2026-04-10T00:00:00Z")
        let endDate = codexBehaviorISODate("2026-04-11T00:00:00Z")

        let sessions = reader.overlappingSessions(from: startDate, to: endDate)
        let usage = try await reader.readUsage(from: startDate, to: endDate)

        XCTAssertTrue(sessions.isEmpty)
        XCTAssertTrue(usage.tokenEvents.isEmpty)
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
