import Foundation
import XCTest
#if os(Linux)
    import CSQLite
#else
    import SQLite3
#endif
import TokiUsageCore
@testable import TokiUsageReaders

final class HermesProfileCollectionTests: XCTestCase {
    func test_registryCollectsDefaultAndProfileDatabasesWithCollidingSessionIDs() async throws {
        let fixture = try HermesProfileFixture()
        defer { fixture.remove() }
        let defaultDatabase = fixture.home.appendingPathComponent(".hermes/state.db")
        let profileDatabase = fixture.home.appendingPathComponent(".hermes/profiles/research/state.db")
        try createHermesProfileDatabase(at: defaultDatabase)
        try createHermesProfileDatabase(at: profileDatabase)
        let environment = [
            "XDG_CONFIG_HOME": fixture.root.appendingPathComponent("config").path,
            "XDG_DATA_HOME": fixture.root.appendingPathComponent("data").path,
            "XDG_STATE_HOME": fixture.root.appendingPathComponent("state").path,
        ]
        let reader = try XCTUnwrap(LocalUsageReaderRegistry
            .readers(home: fixture.home, environment: environment)
            .first { $0.name == HermesReader.sourceName })
        let rangeStart = Date(timeIntervalSince1970: 1_700_000_000)
        let rangeEnd = Date(timeIntervalSince1970: 1_900_000_000)

        _ = try await reader.readUsage(from: rangeStart, to: rangeEnd)
        let activityAt = Date()
        try insertHermesProfileSession(
            into: defaultDatabase,
            id: "shared-session-id",
            startedAt: activityAt,
            inputTokens: 10,
            model: "default-model")
        try insertHermesProfileSession(
            into: profileDatabase,
            id: "shared-session-id",
            startedAt: activityAt,
            inputTokens: 20,
            model: "profile-model")

        let usage = try await reader.readUsage(from: rangeStart, to: rangeEnd)

        XCTAssertEqual(usage.inputTokens, 30)
        XCTAssertEqual(usage.totalTokens, 30)
        XCTAssertEqual(usage.perModel["default-model"]?.totalTokens, 10)
        XCTAssertEqual(usage.perModel["profile-model"]?.totalTokens, 20)
        XCTAssertEqual(usage.tokenEvents.count, 2)
    }

    func test_discoversProfileCreatedAfterReaderConstructionAndRestartIsIdempotent() async throws {
        let fixture = try HermesProfileFixture()
        defer { fixture.remove() }
        let defaultDatabase = fixture.home.appendingPathComponent(".hermes/state.db")
        let profileDatabase = fixture.home.appendingPathComponent(".hermes/profiles/later/state.db")
        try createHermesProfileDatabase(at: defaultDatabase)
        let environment = fixture.environment
        let firstReader = try hermesReader(home: fixture.home, environment: environment)
        let range = fixture.range

        _ = try await firstReader.readUsage(from: range.start, to: range.end)
        try createHermesProfileDatabase(at: profileDatabase)
        _ = try await firstReader.readUsage(from: range.start, to: range.end)
        try insertHermesProfileSession(
            into: profileDatabase,
            id: "new-profile-session",
            startedAt: Date(),
            inputTokens: 7,
            model: "new-profile-model")

        let first = try await firstReader.readUsage(from: range.start, to: range.end)
        let repeated = try await firstReader.readUsage(from: range.start, to: range.end)
        let restarted = try await hermesReader(home: fixture.home, environment: environment)
            .readUsage(from: range.start, to: range.end)

        XCTAssertEqual(first.inputTokens, 7)
        XCTAssertEqual(repeated.inputTokens, 7)
        XCTAssertEqual(restarted.inputTokens, 7)
        XCTAssertEqual(restarted.tokenEvents.count, 1)
    }

    func test_explicitHermesHomeIsolatesThatProfile() async throws {
        let fixture = try HermesProfileFixture()
        defer { fixture.remove() }
        let defaultDatabase = fixture.home.appendingPathComponent(".hermes/state.db")
        let explicitHome = fixture.root.appendingPathComponent("explicit-hermes", isDirectory: true)
        let explicitDatabase = explicitHome.appendingPathComponent("state.db")
        try createHermesProfileDatabase(at: defaultDatabase)
        try createHermesProfileDatabase(at: explicitDatabase)
        let range = fixture.range
        let defaultReader = try hermesReader(home: fixture.home, environment: fixture.environment)
        _ = try await defaultReader.readUsage(from: range.start, to: range.end)
        try insertHermesProfileSession(
            into: defaultDatabase,
            id: "must-not-be-read",
            startedAt: Date(),
            inputTokens: 100,
            model: "default-model")
        let defaultUsage = try await defaultReader.readUsage(from: range.start, to: range.end)
        XCTAssertEqual(defaultUsage.inputTokens, 100)

        var environment = fixture.environment
        environment["HERMES_HOME"] = explicitHome.path
        let reader = try hermesReader(home: fixture.home, environment: environment)
        _ = try await reader.readUsage(from: range.start, to: range.end)
        try insertHermesProfileSession(
            into: explicitDatabase,
            id: "explicit-only",
            startedAt: Date(),
            inputTokens: 9,
            model: "explicit-model")

        let usage = try await reader.readUsage(from: range.start, to: range.end)

        XCTAssertEqual(usage.inputTokens, 9)
        XCTAssertNil(usage.perModel["default-model"])
        XCTAssertEqual(usage.perModel["explicit-model"]?.totalTokens, 9)
    }

    func test_deduplicatesSymlinkedProfileAndReportsCorruptSibling() async throws {
        let fixture = try HermesProfileFixture()
        defer { fixture.remove() }
        let defaultDatabase = fixture.home.appendingPathComponent(".hermes/state.db")
        let realProfile = fixture.home.appendingPathComponent(".hermes/profiles/real", isDirectory: true)
        let realDatabase = realProfile.appendingPathComponent("state.db")
        let aliasProfile = fixture.home.appendingPathComponent(".hermes/profiles/alias", isDirectory: true)
        let corruptDatabase = fixture.home.appendingPathComponent(".hermes/profiles/corrupt/state.db")
        try createHermesProfileDatabase(at: defaultDatabase)
        try createHermesProfileDatabase(at: realDatabase)
        try FileManager.default.createSymbolicLink(at: aliasProfile, withDestinationURL: realProfile)
        try FileManager.default.createDirectory(
            at: corruptDatabase.deletingLastPathComponent(),
            withIntermediateDirectories: true)
        try Data("not a sqlite database".utf8).write(to: corruptDatabase)
        let reader = try hermesReader(home: fixture.home, environment: fixture.environment)
        let range = fixture.range

        _ = try await reader.readUsage(from: range.start, to: range.end)
        try insertHermesProfileSession(
            into: defaultDatabase,
            id: "default",
            startedAt: Date(),
            inputTokens: 3,
            model: "default-model")
        try insertHermesProfileSession(
            into: realDatabase,
            id: "real",
            startedAt: Date(),
            inputTokens: 4,
            model: "real-model")

        let usage = try await reader.readUsage(from: range.start, to: range.end)

        XCTAssertEqual(usage.inputTokens, 7)
        XCTAssertEqual(usage.tokenEvents.count, 2)
        XCTAssertEqual(
            usage.supplemental.first { $0.id == "hermes-profile-read-errors" }?.value,
            1)
    }
}

private func hermesReader(
    home: URL,
    environment: [String: String]) throws -> any TokenReader {
    try XCTUnwrap(LocalUsageReaderRegistry
        .readers(home: home, environment: environment)
        .first { $0.name == HermesReader.sourceName })
}

private struct HermesProfileFixture {
    let root: URL
    let home: URL

    init() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("TokiHermesProfiles-\(UUID().uuidString)", isDirectory: true)
        home = root.appendingPathComponent("home", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
    }

    var environment: [String: String] {
        [
            "XDG_CONFIG_HOME": root.appendingPathComponent("config").path,
            "XDG_DATA_HOME": root.appendingPathComponent("data").path,
            "XDG_STATE_HOME": root.appendingPathComponent("state").path,
        ]
    }

    var range: (start: Date, end: Date) {
        (
            Date(timeIntervalSince1970: 1_700_000_000),
            Date(timeIntervalSince1970: 1_900_000_000))
    }

    func remove() {
        try? FileManager.default.removeItem(at: root)
    }
}

private func createHermesProfileDatabase(at url: URL) throws {
    try FileManager.default.createDirectory(
        at: url.deletingLastPathComponent(),
        withIntermediateDirectories: true)
    var database: OpaquePointer?
    XCTAssertEqual(sqlite3_open(url.path, &database), SQLITE_OK)
    guard let database else { throw HermesProfileTestError.couldNotOpenDatabase }
    defer { sqlite3_close(database) }
    let sql = """
    CREATE TABLE sessions (
        id TEXT PRIMARY KEY,
        started_at REAL NOT NULL,
        model TEXT,
        cwd TEXT,
        git_repo_root TEXT,
        input_tokens INTEGER,
        output_tokens INTEGER,
        cache_read_tokens INTEGER,
        cache_write_tokens INTEGER,
        reasoning_tokens INTEGER,
        estimated_cost_usd REAL,
        actual_cost_usd REAL
    );
    CREATE TABLE messages (session_id TEXT, timestamp REAL);
    """
    guard sqlite3_exec(database, sql, nil, nil, nil) == SQLITE_OK else {
        throw HermesProfileTestError.sqlite(String(cString: sqlite3_errmsg(database)))
    }
}

private func insertHermesProfileSession(
    into url: URL,
    id: String,
    startedAt: Date,
    inputTokens: Int,
    model: String) throws {
    var database: OpaquePointer?
    XCTAssertEqual(sqlite3_open(url.path, &database), SQLITE_OK)
    guard let database else { throw HermesProfileTestError.couldNotOpenDatabase }
    defer { sqlite3_close(database) }
    let sql = """
    INSERT INTO sessions (
        id, started_at, model, cwd, git_repo_root,
        input_tokens, output_tokens, cache_read_tokens,
        cache_write_tokens, reasoning_tokens,
        estimated_cost_usd, actual_cost_usd
    ) VALUES (?, ?, ?, '', '', ?, 0, 0, 0, 0, 0, 0);
    """
    var statement: OpaquePointer?
    guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK,
          let statement else {
        throw HermesProfileTestError.sqlite(String(cString: sqlite3_errmsg(database)))
    }
    defer { sqlite3_finalize(statement) }
    sqlite3_bind_text(statement, 1, id, -1, hermesProfileSQLiteTransient)
    sqlite3_bind_double(statement, 2, startedAt.timeIntervalSince1970)
    sqlite3_bind_text(statement, 3, model, -1, hermesProfileSQLiteTransient)
    sqlite3_bind_int64(statement, 4, sqlite3_int64(inputTokens))
    guard sqlite3_step(statement) == SQLITE_DONE else {
        throw HermesProfileTestError.sqlite(String(cString: sqlite3_errmsg(database)))
    }
}

private let hermesProfileSQLiteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

private enum HermesProfileTestError: Error {
    case couldNotOpenDatabase
    case sqlite(String)
}
