import XCTest
@testable import Toki

// swiftlint:disable:next type_body_length
final class CodexReaderAdditionalTests: XCTestCase {
    // Raw JSONL and cache-schema fixtures intentionally stay inline and byte-visible.
    // swiftlint:disable line_length
    func test_codexReader_usesReportedTotalToSuppressForkReplayAfterComponentRewrite() {
        let lines = [
            #"{"timestamp":"2026-04-10T08:59:58Z","type":"session_meta","payload":{"id":"child-session","forked_from_id":"parent-session"}}"#,
            tokenCountLine(
                ts: "2026-04-10T08:59:59Z",
                input: 100,
                cachedInput: 20,
                output: 10,
                reasoning: 2,
                total: 110),
            #"{"timestamp":"2026-04-10T09:00:00Z","type":"turn_context","payload":{"model":"gpt-5.4-mini"}}"#,
            tokenCountLine(
                ts: "2026-04-10T09:00:01Z",
                input: 95,
                cachedInput: 15,
                output: 20,
                reasoning: 2,
                total: 105,
                lastUsage: TokenCountLineUsage(input: 5, cachedInput: 0, output: 10, reasoning: 0)),
            tokenCountLine(
                ts: "2026-04-10T09:00:02Z",
                input: 110,
                cachedInput: 22,
                output: 12,
                reasoning: 3,
                total: 122,
                lastUsage: TokenCountLineUsage(input: 10, cachedInput: 2, output: 2, reasoning: 1)),
        ]

        let usage = CodexReader.usage(
            fromRolloutLines: lines,
            model: "gpt-5.4-mini",
            from: isoDate("2026-04-10T00:00:00Z"),
            to: isoDate("2026-04-11T00:00:00Z"),
            streamID: "child-rollout")

        XCTAssertEqual(usage.tokenEvents.map(\.totalTokens), [12])
        XCTAssertEqual(usage.totalTokens, 12)
    }

    func test_codexReader_treatsNonASCIIHexTurnIDAsInvalidAfterForkReplay() {
        let lines = [
            #"{"timestamp":"2026-05-05T21:52:10.000Z","type":"session_meta","payload":{"id":"019e5c03-1e99-7000-8000-000000000001","forked_from_id":"019e5b00-0000-7000-8000-000000000001"}}"#,
            #"{"timestamp":"2026-05-05T21:52:10.001Z","type":"session_meta","payload":{"id":"019e5b00-0000-7000-8000-000000000001"}}"#,
            tokenCountLine(
                ts: "2026-05-05T21:52:10.200Z",
                input: 300,
                cachedInput: 0,
                output: 30,
                reasoning: 0,
                total: 330),
            #"{"timestamp":"2026-05-05T21:52:20.100Z","type":"turn_context","payload":{"turn_id":"00000000-000０-7000-8000-000000000001","model":"gpt-5.4-mini"}}"#,
            tokenCountLine(
                ts: "2026-05-05T21:52:20.200Z",
                input: 320,
                cachedInput: 0,
                output: 32,
                reasoning: 0,
                total: 352,
                lastUsage: TokenCountLineUsage(input: 20, cachedInput: 0, output: 2, reasoning: 0)),
        ]

        let usage = CodexReader.usage(
            fromRolloutLines: lines,
            model: "gpt-5.4-mini",
            from: isoDate("2026-05-05T00:00:00Z"),
            to: isoDate("2026-05-06T00:00:00Z"),
            streamID: "non-ascii-hex-turn-id-fork")

        XCTAssertEqual(usage.tokenEvents.map(\.totalTokens), [22])
        XCTAssertEqual(usage.totalTokens, 22)
    }

    func test_codexReader_deduplicatesSameSessionAcrossFilesButKeepsIndependentSessions() {
        let merged = CodexReader().mergedSessions(
            databaseSessions: [
                CodexSession(
                    rolloutPath: "/tmp/current/replayed.jsonl",
                    model: "gpt-5.4-mini",
                    upstreamSessionID: "shared-session"),
                CodexSession(
                    rolloutPath: "/tmp/archived/copied.jsonl",
                    model: "gpt-5.4-mini",
                    upstreamSessionID: "shared-session"),
                CodexSession(
                    rolloutPath: "/tmp/current/independent.jsonl",
                    model: "gpt-5.4-mini",
                    upstreamSessionID: "independent-session"),
            ],
            jsonlSessions: [])

        XCTAssertEqual(merged.count, 2)
        XCTAssertEqual(Set(merged.map(\.upstreamSessionID)), ["shared-session", "independent-session"])
    }

    func test_codexRolloutCacheInvalidatesPreDedupSchema() throws {
        let legacyJSON = #"{"schemaVersion":1,"fileSize":10,"modifiedAt":100,"timeZoneIdentifier":"UTC","dailyUsage":{},"dailyActivityTimestamps":{},"dailyTokenUsageEvents":{}}"#
        let entry = try JSONDecoder().decode(
            CodexRolloutUsageCacheEntry.self,
            from: Data(legacyJSON.utf8))

        XCTAssertEqual(CodexRolloutUsageCacheEntry.currentSchemaVersion, 2)
        XCTAssertFalse(entry.isCurrentSchema)
    }

    // swiftlint:enable line_length

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
}
