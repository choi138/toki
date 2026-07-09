import SQLite3
import XCTest
@testable import Toki

final class HermesReaderTests: XCTestCase {
    func test_hermesReader_readUsageReturnsEmptyForMissingDatabase() async throws {
        let missingURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathComponent("state.db")
        let reader = HermesReader(dbPathOverride: missingURL.path)

        let usage = try await reader.readUsage(
            from: tokiTestISODate("2026-04-10T00:00:00Z"),
            to: tokiTestISODate("2026-04-11T00:00:00Z"))

        XCTAssertFalse(usage.hasReportableData)
    }

    func test_hermesReader_readsSessionTotalsFromStateDatabase() async throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let dbURL = tempDir.appendingPathComponent("state.db")
        try createHermesStateDB(
            at: dbURL,
            rows: hermesUsageFixtureRows())
        let reader = HermesReader(dbPathOverride: dbURL.path)

        let usage = try await reader.readUsage(
            from: tokiTestISODate("2026-04-10T00:00:00Z"),
            to: tokiTestISODate("2026-04-11T00:00:00Z"))

        XCTAssertEqual(usage.inputTokens, 1010)
        XCTAssertEqual(usage.outputTokens, 208)
        XCTAssertEqual(usage.cacheReadTokens, 300)
        XCTAssertEqual(usage.cacheWriteTokens, 40)
        XCTAssertEqual(usage.reasoningTokens, 52)
        XCTAssertEqual(usage.totalTokens, 1610)
        XCTAssertEqual(usage.perModel["gpt-5.5"]?.totalTokens, 1590)
        XCTAssertEqual(usage.perModel["gpt-5.4-mini"]?.totalTokens, 20)
        XCTAssertEqual(usage.perModel["gpt-5.5"]?.sources, Set(["Hermes"]))
        XCTAssertEqual(usage.tokenEvents.map(\.source), ["Hermes", "Hermes"])
        XCTAssertEqual(usage.tokenEvents.map { $0.attribution?.sessionID }, ["session-a", "session-b"])
        XCTAssertEqual(usage.tokenEvents.first?.attribution?.projectName, "Toki")
        XCTAssertEqual(usage.tokenEvents.dropFirst().first?.attribution?.projectName, "OtherProject")
        XCTAssertEqual(usage.tokenEvents.dropFirst().first?.attribution?.quality, .inferred)

        let expectedComputedCost = modelPrice(for: "gpt-5.5")?.cost(
            input: 1000,
            output: 250,
            cacheRead: 300,
            cacheWrite: 40)
        XCTAssertEqual(usage.cost, (expectedComputedCost ?? 0) + 0.25, accuracy: 0.000001)
    }

    func test_hermesReader_tokenHelpersUseSameRangeAndZeroTokenFilters() async throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let dbURL = tempDir.appendingPathComponent("state.db")
        try createHermesStateDB(
            at: dbURL,
            rows: [
                HermesSessionFixture(
                    id: "inside",
                    startedAt: "2026-04-10T09:00:00Z",
                    model: "gpt-5.5",
                    inputTokens: 100,
                    outputTokens: 40,
                    cacheReadTokens: 10,
                    cacheWriteTokens: 5,
                    reasoningTokens: 3,
                    cwd: nil,
                    gitRepoRoot: nil,
                    estimatedCost: nil,
                    actualCost: nil),
                HermesSessionFixture(
                    id: "outside",
                    startedAt: "2026-04-11T00:00:00Z",
                    model: "gpt-5.5",
                    inputTokens: 1000,
                    outputTokens: 1000,
                    cacheReadTokens: 1000,
                    cacheWriteTokens: 1000,
                    reasoningTokens: 1000,
                    cwd: nil,
                    gitRepoRoot: nil,
                    estimatedCost: nil,
                    actualCost: nil),
            ])
        let reader = HermesReader(dbPathOverride: dbURL.path)

        let totalTokens = try await reader.readTotalTokens(
            from: tokiTestISODate("2026-04-10T00:00:00Z"),
            to: tokiTestISODate("2026-04-11T00:00:00Z"))
        let outputTokens = try await reader.readOutputTokens(
            from: tokiTestISODate("2026-04-10T00:00:00Z"),
            to: tokiTestISODate("2026-04-11T00:00:00Z"))

        XCTAssertEqual(totalTokens, 158)
        XCTAssertEqual(outputTokens, 40)
    }

    func test_hermesReader_throwsForMissingSessionsSchema() async throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let dbURL = tempDir.appendingPathComponent("state.db")
        try createEmptyHermesSQLiteDB(at: dbURL)
        let reader = HermesReader(dbPathOverride: dbURL.path)

        do {
            _ = try await reader.readUsage(
                from: tokiTestISODate("2026-04-10T00:00:00Z"),
                to: tokiTestISODate("2026-04-11T00:00:00Z"))
            XCTFail("Expected HermesReader to throw for a statement prepare failure")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("Hermes SQLite prepare failed"))
        }
    }
}

private func hermesUsageFixtureRows() -> [HermesSessionFixture] {
    [
        HermesSessionFixture(
            id: "session-a",
            startedAt: "2026-04-10T09:00:00Z",
            model: "gpt-5.5",
            inputTokens: 1000,
            outputTokens: 200,
            cacheReadTokens: 300,
            cacheWriteTokens: 40,
            reasoningTokens: 50,
            cwd: "/Users/example/Toki",
            gitRepoRoot: nil,
            estimatedCost: 0,
            actualCost: nil),
        HermesSessionFixture(
            id: "session-b",
            startedAt: "2026-04-10T10:00:00Z",
            model: "gpt-5.4-mini",
            inputTokens: 10,
            outputTokens: 8,
            cacheReadTokens: 0,
            cacheWriteTokens: 0,
            reasoningTokens: 2,
            cwd: nil,
            gitRepoRoot: "/Users/example/OtherProject",
            estimatedCost: 0,
            actualCost: 0.25),
        HermesSessionFixture(
            id: "out-of-range",
            startedAt: "2026-04-09T23:59:00Z",
            model: "gpt-5.5",
            inputTokens: 999,
            outputTokens: 999,
            cacheReadTokens: 999,
            cacheWriteTokens: 999,
            reasoningTokens: 999,
            cwd: nil,
            gitRepoRoot: nil,
            estimatedCost: nil,
            actualCost: nil),
        HermesSessionFixture(
            id: "zero-token",
            startedAt: "2026-04-10T11:00:00Z",
            model: "gpt-5.5",
            inputTokens: 0,
            outputTokens: 0,
            cacheReadTokens: 0,
            cacheWriteTokens: 0,
            reasoningTokens: 0,
            cwd: nil,
            gitRepoRoot: nil,
            estimatedCost: nil,
            actualCost: nil),
    ]
}

private struct HermesSessionFixture {
    let id: String
    let startedAt: String
    let model: String?
    let inputTokens: Int
    let outputTokens: Int
    let cacheReadTokens: Int
    let cacheWriteTokens: Int
    let reasoningTokens: Int
    let cwd: String?
    let gitRepoRoot: String?
    let estimatedCost: Double?
    let actualCost: Double?
}

private let hermesTestSQLiteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

private func createHermesStateDB(
    at url: URL,
    rows: [HermesSessionFixture]) throws {
    var database: OpaquePointer?
    guard sqlite3_open(url.path, &database) == SQLITE_OK, let database else {
        throw NSError(domain: "HermesReaderTests", code: 1)
    }
    defer { sqlite3_close(database) }

    guard sqlite3_exec(
        database,
        """
        CREATE TABLE sessions (
            id TEXT PRIMARY KEY,
            started_at REAL NOT NULL,
            model TEXT,
            input_tokens INTEGER DEFAULT 0,
            output_tokens INTEGER DEFAULT 0,
            cache_read_tokens INTEGER DEFAULT 0,
            cache_write_tokens INTEGER DEFAULT 0,
            reasoning_tokens INTEGER DEFAULT 0,
            cwd TEXT,
            git_repo_root TEXT,
            estimated_cost_usd REAL,
            actual_cost_usd REAL
        )
        """,
        nil,
        nil,
        nil) == SQLITE_OK else {
        throw NSError(domain: "HermesReaderTests", code: 2)
    }

    var statement: OpaquePointer?
    guard sqlite3_prepare_v2(
        database,
        """
        INSERT INTO sessions(
            id,
            started_at,
            model,
            input_tokens,
            output_tokens,
            cache_read_tokens,
            cache_write_tokens,
            reasoning_tokens,
            cwd,
            git_repo_root,
            estimated_cost_usd,
            actual_cost_usd
        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        """,
        -1,
        &statement,
        nil) == SQLITE_OK, let statement else {
        throw NSError(domain: "HermesReaderTests", code: 3)
    }
    defer { sqlite3_finalize(statement) }

    for row in rows {
        sqlite3_reset(statement)
        sqlite3_clear_bindings(statement)
        guard let startedAt = DateParser.parse(row.startedAt),
              sqlite3_bind_text(statement, 1, row.id, -1, hermesTestSQLiteTransient) == SQLITE_OK,
              sqlite3_bind_double(statement, 2, startedAt.timeIntervalSince1970) == SQLITE_OK,
              bindHermesText(row.model, at: 3, in: statement),
              sqlite3_bind_int64(statement, 4, Int64(row.inputTokens)) == SQLITE_OK,
              sqlite3_bind_int64(statement, 5, Int64(row.outputTokens)) == SQLITE_OK,
              sqlite3_bind_int64(statement, 6, Int64(row.cacheReadTokens)) == SQLITE_OK,
              sqlite3_bind_int64(statement, 7, Int64(row.cacheWriteTokens)) == SQLITE_OK,
              sqlite3_bind_int64(statement, 8, Int64(row.reasoningTokens)) == SQLITE_OK,
              bindHermesText(row.cwd, at: 9, in: statement),
              bindHermesText(row.gitRepoRoot, at: 10, in: statement),
              bindHermesDouble(row.estimatedCost, at: 11, in: statement),
              bindHermesDouble(row.actualCost, at: 12, in: statement),
              sqlite3_step(statement) == SQLITE_DONE else {
            throw NSError(domain: "HermesReaderTests", code: 4)
        }
    }
}

private func createEmptyHermesSQLiteDB(at url: URL) throws {
    var database: OpaquePointer?
    guard sqlite3_open(url.path, &database) == SQLITE_OK, let database else {
        throw NSError(domain: "HermesReaderTests", code: 5)
    }
    sqlite3_close(database)
}

private func bindHermesText(_ value: String?, at index: Int32, in statement: OpaquePointer) -> Bool {
    guard let value else {
        return sqlite3_bind_null(statement, index) == SQLITE_OK
    }
    return sqlite3_bind_text(statement, index, value, -1, hermesTestSQLiteTransient) == SQLITE_OK
}

private func bindHermesDouble(_ value: Double?, at index: Int32, in statement: OpaquePointer) -> Bool {
    guard let value else {
        return sqlite3_bind_null(statement, index) == SQLITE_OK
    }
    return sqlite3_bind_double(statement, index, value) == SQLITE_OK
}
