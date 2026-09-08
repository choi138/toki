import Foundation
import TokiUsageCore
import XCTest
@testable import TokiUsageReaders

#if os(Linux)
    import CSQLite
#else
    import SQLite3
#endif

final class OpenClawCompatibilityTests: XCTestCase {
    func test_legacyTopLevelPreservesModel() async throws {
        let fixture = try OpenClawFixture()
        defer { fixture.remove() }
        try fixture.jsonl([
            #"{"role":"assistant","model":"claude-sonnet-4-6","provider":"anthropic","#
                + #""timestamp":"2026-08-30T10:00:01Z","usage":{"input_tokens":100,"output_tokens":50}}"#,
        ])
        let usage = try await fixture.read()
        XCTAssertEqual(usage.totalTokens, 150)
        XCTAssertEqual(usage.tokenEvents.first?.model, "claude-sonnet-4-6")
        XCTAssertEqual(usage.perModel["claude-sonnet-4-6"]?.totalTokens, 150)
    }

    func test_currentNestedJSONLPreservesBucketsModelProviderAndSpend() async throws {
        let fixture = try OpenClawFixture()
        defer { fixture.remove() }
        try fixture.jsonl([OpenClawFixture.event()])
        let usage = try await fixture.read()
        assertFullUsage(usage)
    }

    func test_currentSQLiteReadsActualTranscriptSchema() async throws {
        let fixture = try OpenClawFixture()
        defer { fixture.remove() }
        let database = try fixture.database()
        defer { sqlite3_close(database) }
        try fixture.insert(OpenClawFixture.event(), into: database)
        let usage = try await fixture.read()
        assertFullUsage(usage)
    }

    private func assertFullUsage(_ usage: RawTokenUsage, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(usage.inputTokens, 100, file: file, line: line)
        XCTAssertEqual(usage.outputTokens, 30, file: file, line: line)
        XCTAssertEqual(usage.reasoningTokens, 20, file: file, line: line)
        XCTAssertEqual(usage.cacheReadTokens, 200, file: file, line: line)
        XCTAssertEqual(usage.cacheWriteTokens, 10, file: file, line: line)
        XCTAssertEqual(usage.totalTokens, 360, file: file, line: line)
        XCTAssertEqual(usage.cost, 0.0036, accuracy: 0.000001, file: file, line: line)
        XCTAssertEqual(usage.tokenEvents.first?.costIsKnown, true, file: file, line: line)
        XCTAssertEqual(usage.tokenEvents.first?.provider, "anthropic", file: file, line: line)
        XCTAssertEqual(usage.tokenEvents.first?.model, "claude-opus-4-6", file: file, line: line)
        XCTAssertEqual(usage.perModel["claude-opus-4-6"]?.totalTokens, 360, file: file, line: line)
    }
}

// Synthetic, source-derived fixtures, never personal session data.
// Schema/envelope: junhoyeo/tokscale@3bd6dceb98925edab4e149c9bb1cf3fec9123f17,
// crates/tokscale-core/src/sessions/openclaw.rs::test_fixtures (MIT).
struct OpenClawFixture {
    let root: URL
    var agents: URL {
        root.appendingPathComponent(".openclaw/agents")
    }

    static let start = Date(timeIntervalSince1970: 1_788_048_000) // 2026-08-30 00:00 UTC
    static let timestamp = 1_788_084_001_000.0
    static let end = start.addingTimeInterval(86400)

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("toki-openclaw-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: agents, withIntermediateDirectories: true)
    }

    func remove() {
        try? FileManager.default.removeItem(at: root)
    }

    @discardableResult
    func jsonl(_ lines: [String], agent: String = "main", filename: String = "session.jsonl") throws -> URL {
        let url = agents.appendingPathComponent("\(agent)/sessions/\(filename)")
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(lines.joined(separator: "\n").utf8).write(to: url)
        return url
    }

    func database(agent: String = "main", schema: String? = nil) throws -> OpaquePointer {
        let url = agents.appendingPathComponent("\(agent)/agent/openclaw-agent.sqlite")
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        var pointer: OpaquePointer?
        XCTAssertEqual(sqlite3_open(url.path, &pointer), SQLITE_OK)
        let database = try XCTUnwrap(pointer)
        try execute("PRAGMA journal_mode=WAL; PRAGMA wal_autocheckpoint=0;", in: database)
        try execute(schema ?? Self.schema, in: database)
        return database
    }

    func execute(_ sql: String, in database: OpaquePointer) throws {
        guard sqlite3_exec(database, sql, nil, nil, nil) == SQLITE_OK else {
            throw NSError(domain: "OpenClawFixture", code: Int(sqlite3_errcode(database)))
        }
    }

    func insert(
        _ event: String,
        into database: OpaquePointer,
        session: String = "session",
        seq: Int = 0,
        createdAt: Double = timestamp) throws {
        var statement: OpaquePointer?
        XCTAssertEqual(sqlite3_prepare_v2(
            database,
            "INSERT INTO transcript_events (session_id,seq,event_json,created_at) VALUES (?,?,?,?)",
            -1,
            &statement,
            nil), SQLITE_OK)
        defer { sqlite3_finalize(statement) }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        sqlite3_bind_text(statement, 1, session, -1, transient)
        sqlite3_bind_int64(statement, 2, Int64(seq))
        sqlite3_bind_text(statement, 3, event, -1, transient)
        sqlite3_bind_double(statement, 4, createdAt)
        XCTAssertEqual(sqlite3_step(statement), SQLITE_DONE)
    }

    func read() async throws -> RawTokenUsage {
        try await OpenClawReader(agentsURLOverride: agents).readUsage(from: Self.start, to: Self.end)
    }

    static func event(
        id: String = "a1",
        model: String? = "claude-opus-4-6",
        timestamp: Double? = timestamp,
        usage: String? = nil) -> String {
        let modelField = model.map { #", "model":"\#($0)""# } ?? ""
        let timeField = timestamp.map { #", "timestamp":\#(Int64($0))"# } ?? ""
        let tokens = usage ?? (#"{"input":100,"output":50,"cacheRead":200,"cacheWrite":10,"#
            + #""reasoningTokens":20,"totalTokens":360,"cost":{"total":0.0036}}"#)
        return #"{"type":"message","id":"\#(id)","message":{"role":"assistant","provider":"anthropic""#
            + #"\#(modelField)\#(timeField),"usage":\#(tokens)}}"#
    }

    static let schema = """
    CREATE TABLE session_windows (
      session_id TEXT NOT NULL PRIMARY KEY, session_key TEXT NOT NULL, previous_session_id TEXT,
      created_at INTEGER NOT NULL, updated_at INTEGER NOT NULL,
      model_provider TEXT, model TEXT, agent_harness_id TEXT
    ) STRICT;
    CREATE TABLE transcript_events (
      session_id TEXT NOT NULL, seq INTEGER NOT NULL, event_json TEXT NOT NULL,
      created_at INTEGER NOT NULL, PRIMARY KEY (session_id, seq)
    ) STRICT;
    """
}
