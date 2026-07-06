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

    func test_codexReader_prefersLastTokenUsageWhenTotalSnapshotRegresses() {
        let lines = [
            tokenCountLine(
                ts: "2026-04-10T09:00:00Z",
                input: 1000,
                cachedInput: 800,
                output: 100,
                reasoning: 40,
                total: 1100,
                lastUsage: TokenCountLineUsage(
                    input: 100,
                    cachedInput: 80,
                    output: 10,
                    reasoning: 4)),
            tokenCountLine(
                ts: "2026-04-10T09:01:00Z",
                input: 900,
                cachedInput: 850,
                output: 90,
                reasoning: 30,
                total: 990,
                lastUsage: TokenCountLineUsage(
                    input: 50,
                    cachedInput: 40,
                    output: 8,
                    reasoning: 2)),
        ]

        let usage = CodexReader.usage(
            fromRolloutLines: lines,
            model: "gpt-5.4-mini",
            from: isoDate("2026-04-10T00:00:00Z"),
            to: isoDate("2026-04-11T00:00:00Z"),
            streamID: "rollout-a")
        let summary = codexRolloutDailySummary(
            fromSnapshots: codexRolloutSnapshots(fromRolloutLines: lines))

        XCTAssertEqual(usage.inputTokens, 30)
        XCTAssertEqual(usage.cacheReadTokens, 120)
        XCTAssertEqual(usage.outputTokens, 12)
        XCTAssertEqual(usage.reasoningTokens, 6)
        XCTAssertEqual(usage.totalTokens, 168)
        XCTAssertEqual(usage.tokenEvents.map(\.totalTokens), [110, 58])
        XCTAssertEqual(summary.dailyUsage["2026-04-10"]?.totalTokens, 168)
        XCTAssertEqual(summary.dailyTokenUsageEvents["2026-04-10"]?.map(\.totalTokens), [110, 58])
    }

    func test_codexReaderAttachesSessionAttributionToTokenEvents() {
        let usage = CodexReader.usage(
            fromRolloutLines: [
                tokenCountLine(
                    ts: "2026-04-10T09:00:00Z",
                    input: 120,
                    cachedInput: 20,
                    output: 30,
                    reasoning: 5,
                    total: 150),
            ],
            model: "gpt-5.4-mini",
            from: isoDate("2026-04-10T00:00:00Z"),
            to: isoDate("2026-04-11T00:00:00Z"),
            streamID: "/tmp/rollout-a.jsonl",
            attribution: UsageAttribution(
                projectPath: "/Users/example/Toki",
                sessionID: "rollout-a",
                quality: .exact))

        XCTAssertEqual(usage.tokenEvents.first?.attribution?.projectName, "Toki")
        XCTAssertEqual(usage.tokenEvents.first?.attribution?.sessionID, "rollout-a")
        XCTAssertEqual(usage.tokenEvents.first?.attribution?.quality, .exact)
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

    func test_codexReaderSkipsJsonlLookupForTotalOnlyAttributionWithoutProjectPath() {
        let skippedPaths = CodexReader().pathsWithCompleteDatabaseAttribution(
            in: [
                CodexSession(rolloutPath: "/tmp/main-with-model.jsonl", model: "gpt-5.4"),
                CodexSession(
                    rolloutPath: "/tmp/model-without-source.jsonl",
                    model: "gpt-5.4",
                    hasSourceAttribution: false),
            ],
            requiresProjectAttribution: false)

        XCTAssertEqual(skippedPaths, ["/tmp/main-with-model.jsonl"])
    }

    func test_codexReaderUsesDatabaseCwdForProjectAttribution() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let dbURL = directory.appendingPathComponent("state_5.sqlite")
        let rolloutPath = directory.appendingPathComponent("rollout.jsonl").path
        try createSecurityAuditSQLiteDB(
            at: dbURL,
            statements: [
                """
                CREATE TABLE threads (
                    rollout_path TEXT NOT NULL,
                    model TEXT,
                    source TEXT NOT NULL,
                    cwd TEXT NOT NULL,
                    created_at INTEGER NOT NULL,
                    updated_at INTEGER NOT NULL
                )
                """,
                """
                INSERT INTO threads (
                    rollout_path,
                    model,
                    source,
                    cwd,
                    created_at,
                    updated_at
                ) VALUES (
                    '\(rolloutPath)',
                    'gpt-5.4-mini',
                    'vscode',
                    '/Users/example/Desktop/Project/content',
                    1775779200,
                    1775782800
                )
                """,
            ])

        let session = try XCTUnwrap(
            CodexReader(dbPath: dbURL.path)
                .overlappingSessions(
                    from: isoDate("2026-04-10T00:00:00Z"),
                    to: isoDate("2026-04-11T00:00:00Z"))
                .first { $0.rolloutPath == rolloutPath })

        XCTAssertEqual(session.projectPath, "/Users/example/Desktop/Project/content")
        XCTAssertEqual(session.projectAttributionQuality, .exact)
        XCTAssertEqual(session.attribution.projectName, "content")
    }

    func test_codexReaderKeepsDatabaseSessionsWhenCwdColumnIsMissing() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let dbURL = directory.appendingPathComponent("state_5.sqlite")
        let rolloutPath = directory.appendingPathComponent("rollout.jsonl").path
        try createSecurityAuditSQLiteDB(
            at: dbURL,
            statements: [
                """
                CREATE TABLE threads (
                    rollout_path TEXT NOT NULL,
                    model TEXT,
                    source TEXT NOT NULL,
                    created_at INTEGER NOT NULL,
                    updated_at INTEGER NOT NULL
                )
                """,
                """
                INSERT INTO threads (
                    rollout_path,
                    model,
                    source,
                    created_at,
                    updated_at
                ) VALUES (
                    '\(rolloutPath)',
                    'gpt-5.4-mini',
                    'vscode',
                    1775779200,
                    1775782800
                )
                """,
            ])

        let session = try XCTUnwrap(
            CodexReader(dbPath: dbURL.path)
                .overlappingSessions(
                    from: isoDate("2026-04-10T00:00:00Z"),
                    to: isoDate("2026-04-11T00:00:00Z"))
                .first { $0.rolloutPath == rolloutPath })

        XCTAssertEqual(session.model, "gpt-5.4-mini")
        XCTAssertEqual(session.hasSourceAttribution, true)
        XCTAssertNil(session.projectPath)
        XCTAssertEqual(session.projectAttributionQuality, .unknown)
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
        tokenCountLine(
            ts: ts,
            input: input,
            cachedInput: cachedInput,
            output: output,
            reasoning: reasoning,
            total: total,
            additionalInfoFields: [])
    }

    private func tokenCountLine(
        ts: String,
        input: Int,
        cachedInput: Int,
        output: Int,
        reasoning: Int,
        total: Int,
        lastUsage: TokenCountLineUsage) -> String {
        tokenCountLine(
            ts: ts,
            input: input,
            cachedInput: cachedInput,
            output: output,
            reasoning: reasoning,
            total: total,
            additionalInfoFields: [
                tokenUsageField("last_token_usage", usage: lastUsage),
            ])
    }

    private func tokenCountLine(
        ts: String,
        input: Int,
        cachedInput: Int,
        output: Int,
        reasoning: Int,
        total: Int,
        additionalInfoFields: [String]) -> String {
        let totalUsage = TokenCountLineUsage(
            input: input,
            cachedInput: cachedInput,
            output: output,
            reasoning: reasoning,
            total: total)
        let infoFields = [
            tokenUsageField("total_token_usage", usage: totalUsage),
        ] + additionalInfoFields

        return """
        {"timestamp":"\(ts)","type":"event_msg",\
        "payload":{"type":"token_count","info":{\(infoFields.joined(separator: ","))}}}
        """
    }

    private func tokenUsageField(_ name: String, usage: TokenCountLineUsage) -> String {
        """
        "\(name)":{"input_tokens":\(usage.input),\
        "cached_input_tokens":\(usage.cachedInput),\
        "output_tokens":\(usage.output),\
        "reasoning_output_tokens":\(usage.reasoning),\
        "total_tokens":\(usage.total)}
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

private struct TokenCountLineUsage {
    let input: Int
    let cachedInput: Int
    let output: Int
    let reasoning: Int
    let total: Int

    init(
        input: Int,
        cachedInput: Int,
        output: Int,
        reasoning: Int) {
        self.init(
            input: input,
            cachedInput: cachedInput,
            output: output,
            reasoning: reasoning,
            total: input + output)
    }

    init(
        input: Int,
        cachedInput: Int,
        output: Int,
        reasoning: Int,
        total: Int) {
        self.input = input
        self.cachedInput = cachedInput
        self.output = output
        self.reasoning = reasoning
        self.total = total
    }
}
