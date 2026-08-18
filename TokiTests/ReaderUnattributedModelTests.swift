import Foundation
import SQLite3
import TokiUsageCore
import XCTest
@testable import Toki
@testable import TokiUsageReaders

/// Every reader must leave a per-model row for usage it cannot attribute to a named model.
///
/// Report building trusts authoritative per-model rows over token events whose source labels
/// disagree, so a source that contributes only events vanishes from the model breakdown as soon as
/// another source reports the same key. The row must carry active time too, otherwise it replaces
/// the event-derived estimate with zero elapsed time.
final class ReaderUnattributedModelTests: XCTestCase {
    func test_groupingKeyFoldsMissingAndBlankModelNames() {
        XCTAssertEqual(
            UsageModelGrouping.groupingKey(for: nil),
            UsageModelGrouping.mixedOrUnattributedKey)
        XCTAssertEqual(
            UsageModelGrouping.groupingKey(for: "   "),
            UsageModelGrouping.mixedOrUnattributedKey)
        XCTAssertEqual(UsageModelGrouping.groupingKey(for: "gpt-5"), "gpt-5")
    }

    func test_accumulatePerModelUsageFoldsUnnamedModelsIntoTheMixedKey() {
        var usage = RawTokenUsage()
        usage.accumulatePerModelUsage(model: nil, source: "Probe", totalTokens: 40, cost: 0.5)
        usage.accumulatePerModelUsage(model: "gpt-5", source: "Probe", totalTokens: 10)

        let mixed = usage.perModel[UsageModelGrouping.mixedOrUnattributedKey]

        XCTAssertEqual(mixed?.totalTokens, 40)
        XCTAssertEqual(mixed?.cost, 0.5)
        XCTAssertEqual(mixed?.sources, ["Probe"])
        XCTAssertEqual(usage.perModel["gpt-5"]?.totalTokens, 10)
    }

    func test_geminiLegacyFormatKeepsUnattributedUsageInModelRows() async throws {
        let base = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("toki-gemini-legacy-\(UUID().uuidString)")
        let chats = base.appendingPathComponent("session/chats")
        try FileManager.default.createDirectory(at: chats, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }

        let file = chats.appendingPathComponent("history.json")
        // The legacy format carries usageMetadata with no model name.
        try #"[{"usageMetadata":{"promptTokenCount":300,"candidatesTokenCount":40}}]"#
            .write(to: file, atomically: true, encoding: .utf8)
        let fileDate = tokiTestISODate("2026-04-10T12:00:00Z")
        try FileManager.default.setAttributes(
            [.modificationDate: fileDate],
            ofItemAtPath: file.path)

        let start = tokiTestISODate("2026-04-10T00:00:00Z")
        let end = tokiTestISODate("2026-04-11T00:00:00Z")
        let usage = try await GeminiReader(chatsBaseURLOverride: base)
            .readUsage(from: start, to: end)

        XCTAssertEqual(usage.totalTokens, 340, "legacy Gemini fixture was not picked up")

        let row = try XCTUnwrap(UsageReportBuilder.buildModelStats(
            from: usage,
            startDate: start,
            endDate: end)
            .first { $0.modelID == UsageModelGrouping.mixedOrUnattributedKey })

        XCTAssertEqual(row.totalTokens, 340)
        XCTAssertEqual(row.sources, ["Gemini CLI"])
    }

    func test_openCodeRowsWithoutModelIDKeepUnattributedUsageAndActiveTime() async throws {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("toki-opencode-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let start = tokiTestISODate("2026-04-10T00:00:00Z")
        let end = tokiTestISODate("2026-04-11T00:00:00Z")
        let database = directory.appendingPathComponent("opencode.db")
        // Assistant rows carrying token usage but no modelID.
        try makeOpenCodeDatabase(
            at: database,
            rows: [
                OpenCodeFixtureRow(
                    timestamp: tokiTestISODate("2026-04-10T12:00:00Z"),
                    input: 300,
                    output: 40),
                OpenCodeFixtureRow(
                    timestamp: tokiTestISODate("2026-04-10T12:01:00Z"),
                    input: 400,
                    output: 50),
            ])

        let usage = try await OpenCodeReader(dbPathOverride: database.path)
            .readUsage(from: start, to: end)

        XCTAssertEqual(usage.totalTokens, 790, "OpenCode fixture was not picked up")

        let row = try XCTUnwrap(UsageReportBuilder.buildModelStats(
            from: usage,
            startDate: start,
            endDate: end)
            .first { $0.modelID == UsageModelGrouping.mixedOrUnattributedKey })

        XCTAssertEqual(row.totalTokens, 790)
        XCTAssertEqual(row.sources, ["OpenCode"])
        XCTAssertGreaterThan(row.activeSeconds, 0)
    }

    func test_claudeCodeEntriesWithoutAModelKeepUnattributedUsageInModelRows() {
        let usage = ClaudeCodeReader.usage(
            fromJSONLLines: [
                // An assistant entry whose message carries usage but no model name.
                #"{"timestamp":"2026-04-10T12:00:00Z","type":"assistant","requestId":"req-1","#
                    + #""message":{"id":"msg-1","usage":{"input_tokens":300,"output_tokens":40}}}"#,
            ],
            streamID: "/tmp/claude-session.jsonl",
            from: tokiTestISODate("2026-04-10T00:00:00Z"),
            to: tokiTestISODate("2026-04-11T00:00:00Z"))

        let mixed = usage.perModel[UsageModelGrouping.mixedOrUnattributedKey]

        XCTAssertEqual(usage.totalTokens, 340, "Claude Code fixture was not picked up")
        XCTAssertEqual(mixed?.totalTokens, 340)
        XCTAssertEqual(mixed?.sources, ["Claude Code"])
    }

    func test_cursorBubblesWithoutAModelKeepUnattributedUsageInModelRows() {
        let usage = CursorReader.usage(
            fromBubblePayloads: [
                // A token bubble with no matching model bubble.
                #"{"bubbleId":"b1","usageUuid":"u1","createdAt":"2026-04-10T12:00:00Z","#
                    + #""tokenCount":{"inputTokens":300,"outputTokens":40}}"#,
            ],
            from: tokiTestISODate("2026-04-10T00:00:00Z"),
            to: tokiTestISODate("2026-04-11T00:00:00Z"))

        let mixed = usage.perModel[UsageModelGrouping.mixedOrUnattributedKey]

        XCTAssertEqual(usage.totalTokens, 340, "Cursor fixture was not picked up")
        XCTAssertEqual(mixed?.totalTokens, 340)
        XCTAssertEqual(mixed?.sources, ["Cursor"])
    }

    func test_codexRolloutsWithoutAModelKeepUnattributedUsageInModelRows() {
        let usage = CodexReader.usage(
            fromRolloutLines: [
                tokenCountLine(
                    ts: "2026-04-10T12:00:00Z",
                    input: 300,
                    cachedInput: 0,
                    output: 40,
                    reasoning: 0,
                    total: 340),
            ],
            model: nil,
            from: tokiTestISODate("2026-04-10T00:00:00Z"),
            to: tokiTestISODate("2026-04-11T00:00:00Z"),
            streamID: "/tmp/codex-rollout.jsonl")

        let mixed = usage.perModel[UsageModelGrouping.mixedOrUnattributedKey]

        XCTAssertEqual(usage.totalTokens, 340, "Codex fixture was not picked up")
        XCTAssertEqual(mixed?.totalTokens, 340)
        XCTAssertEqual(mixed?.sources, ["Codex"])
    }

    /// An event-only source must survive alongside another source that reports an authoritative
    /// row for the same mixed/unattributed key. This is the cross-source condition that used to
    /// drop it from the model breakdown entirely.
    func test_unattributedSourcesFromTwoReadersBothReachTheModelRows() {
        let start = tokiTestISODate("2026-04-10T00:00:00Z")
        let end = tokiTestISODate("2026-04-11T00:00:00Z")
        var usage = RawTokenUsage()
        usage.inputTokens = 130
        usage.accumulatePerModelUsage(model: nil, source: "OpenClaw", totalTokens: 100)
        usage.accumulatePerModelUsage(model: nil, source: "OpenCode", totalTokens: 30)

        let rows = UsageReportBuilder.buildModelStats(
            from: usage,
            startDate: start,
            endDate: end)
            .filter { $0.modelID == UsageModelGrouping.mixedOrUnattributedKey }

        XCTAssertEqual(rows.reduce(0) { $0 + $1.totalTokens }, 130)
        XCTAssertEqual(Set(rows.flatMap(\.sources)), ["OpenClaw", "OpenCode"])
    }
}

private struct OpenCodeFixtureRow {
    let timestamp: Date
    let input: Int
    let output: Int
}

private func makeOpenCodeDatabase(
    at url: URL,
    rows: [OpenCodeFixtureRow]) throws {
    var database: OpaquePointer?
    guard sqlite3_open(url.path, &database) == SQLITE_OK, let database else {
        throw NSError(domain: "ReaderUnattributedModelTests", code: 1)
    }
    defer { sqlite3_close(database) }

    guard sqlite3_exec(
        database,
        "CREATE TABLE message (session_id TEXT, time_created INTEGER, data TEXT)",
        nil,
        nil,
        nil) == SQLITE_OK else {
        throw NSError(domain: "ReaderUnattributedModelTests", code: 2)
    }

    for row in rows {
        let millis = Int(row.timestamp.timeIntervalSince1970 * 1000)
        let data = #"{"role":"assistant","tokens":{"input":\#(row.input),"output":\#(row.output)}}"#
        let insert = """
            INSERT INTO message (session_id, time_created, data)
            VALUES ('opencode-session', \(millis), '\(data)')
        """
        guard sqlite3_exec(database, insert, nil, nil, nil) == SQLITE_OK else {
            throw NSError(domain: "ReaderUnattributedModelTests", code: 3)
        }
    }
}
