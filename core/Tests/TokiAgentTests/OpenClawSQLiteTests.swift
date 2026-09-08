import Foundation
import TokiUsageCore
import XCTest
@testable import TokiUsageReaders

#if os(Linux)
    import CSQLite
#else
    import SQLite3
#endif

final class OpenClawSQLiteTests: XCTestCase {
    func test_walOnlyUpdatesAreReadWithoutChangingSourceDatabaseWALOrSHM() async throws {
        let fixture = try OpenClawFixture()
        defer { fixture.remove() }
        let database = try fixture.database()
        defer { sqlite3_close(database) }
        try fixture.execute("PRAGMA wal_checkpoint(TRUNCATE)", in: database)
        let base = fixture.agents.appendingPathComponent("main/agent/openclaw-agent.sqlite")
        let mainBefore = try Data(contentsOf: base)
        try fixture.insert(OpenClawFixture.event(), into: database)
        let before = try sourceBytes(base)
        XCTAssertEqual(try Data(contentsOf: base), mainBefore)
        XCTAssertGreaterThan(before["-wal"]?.count ?? 0, 0)
        let first = try await fixture.read()
        XCTAssertEqual(first.totalTokens, 360)
        XCTAssertEqual(try sourceBytes(base), before)
        try fixture.insert(OpenClawFixture.event(id: "a2"), into: database, seq: 1)
        let afterWrite = try sourceBytes(base)
        XCTAssertEqual(try Data(contentsOf: base), mainBefore)
        let second = try await fixture.read()
        XCTAssertEqual(second.totalTokens, 720)
        XCTAssertEqual(try sourceBytes(base), afterWrite)
    }

    func test_snapshotReadsWALWithoutSourceSHMAndDoesNotCreateSourceSidecars() async throws {
        let source = try OpenClawFixture()
        defer { source.remove() }
        let target = try OpenClawFixture()
        defer { target.remove() }
        let database = try source.database()
        defer { sqlite3_close(database) }
        try source.insert(OpenClawFixture.event(), into: database)
        let sourceDB = source.agents.appendingPathComponent("main/agent/openclaw-agent.sqlite")
        let targetDB = target.agents.appendingPathComponent("main/agent/openclaw-agent.sqlite")
        try FileManager.default.createDirectory(
            at: targetDB.deletingLastPathComponent(),
            withIntermediateDirectories: true)
        for suffix in ["", "-wal"] {
            try Data(contentsOf: URL(fileURLWithPath: sourceDB.path + suffix))
                .write(to: URL(fileURLWithPath: targetDB.path + suffix))
        }
        let before = try sourceBytes(targetDB)
        let usage = try await target.read()
        XCTAssertEqual(usage.totalTokens, 360)
        XCTAssertEqual(try sourceBytes(targetDB), before)
        XCTAssertFalse(FileManager.default.fileExists(atPath: targetDB.path + "-shm"))
    }

    func test_readOnlyDatabaseWithoutSidecarsWorksAndRemainsUntouched() async throws {
        let fixture = try OpenClawFixture()
        defer { fixture.remove() }
        let database = try fixture.database()
        try fixture.insert(OpenClawFixture.event(), into: database)
        XCTAssertEqual(sqlite3_close(database), SQLITE_OK)
        let url = fixture.agents.appendingPathComponent("main/agent/openclaw-agent.sqlite")
        let before = try sourceBytes(url)
        try FileManager.default.setAttributes([.posixPermissions: 0o400], ofItemAtPath: url.path)
        let usage = try await fixture.read()
        XCTAssertEqual(usage.totalTokens, 360)
        XCTAssertEqual(try sourceBytes(url), before)
    }

    func test_sessionMetadataSupportsCurrentLegacyAndBareSchemas() async throws {
        for table in ["session_windows", "sessions", ""] {
            let fixture = try OpenClawFixture()
            defer { fixture.remove() }
            let schema = table.isEmpty ? OpenClawSQLiteTests.bareSchema
                : OpenClawSQLiteTests.bareSchema + """
                CREATE TABLE \(table) (session_id TEXT, model_provider TEXT, model TEXT);
                INSERT INTO \(table) VALUES ('session', 'openai', 'gpt-5.2');
                """
            let database = try fixture.database(schema: schema)
            defer { sqlite3_close(database) }
            let event = OpenClawFixture.event(model: nil)
                .replacingOccurrences(of: #""provider":"anthropic""#, with: #""provider":null"#)
            try fixture.insert(event, into: database)
            let usage = try await fixture.read()
            XCTAssertEqual(usage.totalTokens, 360)
            XCTAssertEqual(usage.tokenEvents.first?.model, table.isEmpty ? nil : "gpt-5.2")
            XCTAssertEqual(usage.tokenEvents.first?.provider, table.isEmpty ? nil : "openai")
        }
    }

    func test_databaseContextOverridesCurrentMetadataAndResetsPerSession() async throws {
        let fixture = try OpenClawFixture()
        defer { fixture.remove() }
        let database = try fixture.database(schema: Self.bareSchema + """
        CREATE TABLE session_windows (session_id TEXT, model_provider TEXT, model TEXT);
        INSERT INTO session_windows VALUES ('a', 'anthropic', 'claude-opus-4-6');
        INSERT INTO session_windows VALUES ('b', 'openai', 'gpt-5.2');
        """)
        defer { sqlite3_close(database) }
        try fixture.insert(
            #"{"type":"model_change","modelId":"claude-sonnet-4-6","provider":"anthropic"}"#,
            into: database, session: "a")
        try fixture.insert(OpenClawFixture.event(id: "a", model: nil), into: database, session: "a", seq: 1)
        try fixture.insert(
            OpenClawFixture.event(
                id: "b", model: nil, timestamp: OpenClawFixture.timestamp + 1000),
            into: database,
            session: "b")
        let usage = try await fixture.read()
        XCTAssertEqual(usage.tokenEvents.map(\.model), ["claude-sonnet-4-6", "gpt-5.2"])
    }

    func test_databaseCreatedAtFallbackSupportsSecondsMillisecondsAndHalfOpenBounds() async throws {
        let fixture = try OpenClawFixture()
        defer { fixture.remove() }
        let database = try fixture.database(schema: Self.bareSchema)
        defer { sqlite3_close(database) }
        let start = OpenClawFixture.start.timeIntervalSince1970
        let end = OpenClawFixture.end.timeIntervalSince1970
        for (index, time) in [start - 1, start, start * 1000 + 1000, end * 1000].enumerated() {
            try fixture.insert(
                OpenClawFixture.event(id: "a\(index)", timestamp: nil),
                into: database, seq: index, createdAt: time)
        }
        let usage = try await fixture.read()
        XCTAssertEqual(usage.totalTokens, 720)
        XCTAssertEqual(usage.tokenEvents.map(\.timestamp), [
            OpenClawFixture.start, OpenClawFixture.start.addingTimeInterval(1),
        ])
    }

    func test_malformedDatabaseRowsDoNotEndScan() async throws {
        let fixture = try OpenClawFixture()
        defer { fixture.remove() }
        let database = try fixture.database()
        defer { sqlite3_close(database) }
        try fixture.insert("broken", into: database)
        try fixture.insert(OpenClawFixture.event(usage: #"{"input":"invalid","output":5}"#), into: database, seq: 1)
        try fixture.insert(OpenClawFixture.event(), into: database, seq: 2)
        let usage = try await fixture.read()
        XCTAssertEqual(usage.totalTokens, 360)
        XCTAssertEqual(usage.tokenEvents.count, 1)
    }

    func test_unknownAndIncompleteSchemasThrowWhileEmptyKnownSchemaIsEmpty() async throws {
        for schema in ["CREATE TABLE unrelated (id TEXT)", "CREATE TABLE transcript_events (session_id TEXT)"] {
            let fixture = try OpenClawFixture()
            defer { fixture.remove() }
            let database = try fixture.database(schema: schema)
            defer { sqlite3_close(database) }
            do {
                _ = try await fixture.read()
                XCTFail("Unknown schema must not look like successful empty usage")
            } catch {
                XCTAssertEqual(error as? OpenClawReadError, .unsupportedSchema)
            }
        }
        let fixture = try OpenClawFixture()
        defer { fixture.remove() }
        let database = try fixture.database()
        defer { sqlite3_close(database) }
        let usage = try await fixture.read()
        XCTAssertEqual(usage.totalTokens, 0)
        XCTAssertTrue(usage.tokenEvents.isEmpty)
    }

    private func sourceBytes(_ url: URL) throws -> [String: Data] {
        var bytes: [String: Data] = [:]
        for suffix in ["", "-wal", "-shm", "-journal"] {
            let file = URL(fileURLWithPath: url.path + suffix)
            if FileManager.default.fileExists(atPath: file.path) { bytes[suffix] = try Data(contentsOf: file) }
        }
        return bytes
    }

    static let bareSchema = """
    CREATE TABLE transcript_events (
        session_id TEXT NOT NULL, seq INTEGER NOT NULL, event_json TEXT NOT NULL,
        created_at INTEGER NOT NULL, PRIMARY KEY (session_id, seq)
    );
    """
}
