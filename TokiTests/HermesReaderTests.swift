// swiftlint:disable file_length
import SQLite3
import TokiUsageCore
import XCTest
@testable import Toki
@testable import TokiUsageReaders

// swiftlint:disable:next type_body_length
final class HermesReaderTests: XCTestCase {
    func test_hermesReader_readUsageReturnsEmptyForMissingDatabase() async throws {
        let missingURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathComponent("state.db")
        let reader = HermesReader(
            dbPathOverride: missingURL.path,
            usageLedger: HermesUsageLedger(fileURL: missingURL.deletingLastPathComponent()
                .appendingPathComponent("hermes-usage-ledger.json")),
            now: { tokiTestISODate("2026-04-10T12:00:00Z") })

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
        let ledger = HermesUsageLedger(fileURL: tempDir.appendingPathComponent("hermes-usage-ledger.json"))
        try await ledger.refresh(
            observations: [],
            observedAt: tokiTestISODate("2026-04-10T08:00:00Z"))
        let reader = HermesReader(
            dbPathOverride: dbURL.path,
            usageLedger: ledger,
            now: { tokiTestISODate("2026-04-10T12:00:00Z") })

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
        let sessionIdentifiers = usage.tokenEvents.compactMap { $0.attribution?.sessionID }
        XCTAssertEqual(Set(sessionIdentifiers).count, 2)
        XCTAssertTrue(sessionIdentifiers.allSatisfy { $0.count == 32 })
        XCTAssertFalse(sessionIdentifiers.contains("session-a"))
        XCTAssertFalse(sessionIdentifiers.contains("session-b"))
        XCTAssertEqual(
            Set(usage.tokenEvents.compactMap { $0.attribution?.projectName }),
            Set(["Toki", "OtherProject"]))
        XCTAssertEqual(
            usage.tokenEvents.first { $0.attribution?.projectName == "OtherProject" }?.attribution?.quality,
            .inferred)

        let expectedComputedCost = modelPrice(for: "gpt-5.5")?.cost(
            input: 1000,
            output: 250,
            cacheRead: 300,
            cacheWrite: 40)
        XCTAssertEqual(usage.cost, (expectedComputedCost ?? 0) + 0.25, accuracy: 0.000001)
    }

    func test_hermesReader_readsModelUsageForZeroTokenSession() async throws {
        let tempDir = try makeHermesTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let dbURL = tempDir.appendingPathComponent("state.db")
        try createHermesStateDB(
            at: dbURL,
            rows: [
                HermesSessionFixture(
                    id: "discord-session",
                    startedAt: "2026-04-10T09:00:00Z",
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
            ])
        try insertHermesModelUsage(
            databaseURL: dbURL,
            rows: [
                HermesModelUsageFixture(
                    sessionID: "discord-session",
                    model: "gpt-5.5",
                    task: "approval",
                    apiCallCount: 1,
                    inputTokens: 100,
                    outputTokens: 20,
                    cacheReadTokens: 5,
                    cacheWriteTokens: 0,
                    reasoningTokens: 2,
                    estimatedCost: 0,
                    actualCost: 0),
            ])
        let ledger = HermesUsageLedger(fileURL: tempDir.appendingPathComponent("hermes-usage-ledger.json"))
        try await ledger.refresh(
            observations: [],
            observedAt: tokiTestISODate("2026-04-10T08:00:00Z"))
        let reader = HermesReader(
            dbPathOverride: dbURL.path,
            usageLedger: ledger,
            now: { tokiTestISODate("2026-04-10T12:00:00Z") })

        let usage = try await reader.readUsage(
            from: tokiTestISODate("2026-04-10T00:00:00Z"),
            to: tokiTestISODate("2026-04-11T00:00:00Z"))

        XCTAssertEqual(usage.inputTokens, 100)
        XCTAssertEqual(usage.outputTokens, 20)
        XCTAssertEqual(usage.cacheReadTokens, 5)
        XCTAssertEqual(usage.cacheWriteTokens, 0)
        XCTAssertEqual(usage.reasoningTokens, 2)
        XCTAssertEqual(usage.totalTokens, 127)
        XCTAssertEqual(usage.perModel["gpt-5.5"]?.totalTokens, 127)
        XCTAssertEqual(usage.tokenEvents.map(\.model), ["gpt-5.5"])
    }

    func test_hermesReader_reconcilesOverlappingSessionAndModelUsageWithoutDoubleCounting() async throws {
        let tempDir = try makeHermesTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let dbURL = tempDir.appendingPathComponent("state.db")
        try createHermesStateDB(
            at: dbURL,
            rows: [
                HermesSessionFixture(
                    id: "discord-session",
                    startedAt: "2026-04-10T09:00:00Z",
                    model: "gpt-5.5",
                    inputTokens: 1000,
                    outputTokens: 200,
                    cacheReadTokens: 300,
                    cacheWriteTokens: 40,
                    reasoningTokens: 50,
                    cwd: nil,
                    gitRepoRoot: nil,
                    estimatedCost: 1,
                    actualCost: nil),
            ])
        try insertHermesModelUsage(
            databaseURL: dbURL,
            rows: [
                HermesModelUsageFixture(
                    sessionID: "discord-session",
                    model: "gpt-5.5",
                    task: "",
                    apiCallCount: 1,
                    inputTokens: 1000,
                    outputTokens: 200,
                    cacheReadTokens: 300,
                    cacheWriteTokens: 40,
                    reasoningTokens: 50,
                    estimatedCost: 1,
                    actualCost: 0),
                HermesModelUsageFixture(
                    sessionID: "discord-session",
                    model: "gpt-5.5",
                    task: "approval",
                    apiCallCount: 1,
                    inputTokens: 100,
                    outputTokens: 20,
                    cacheReadTokens: 5,
                    cacheWriteTokens: 0,
                    reasoningTokens: 2,
                    estimatedCost: 0.2,
                    actualCost: 0),
            ])
        let ledger = HermesUsageLedger(fileURL: tempDir.appendingPathComponent("hermes-usage-ledger.json"))
        try await ledger.refresh(
            observations: [],
            observedAt: tokiTestISODate("2026-04-10T08:00:00Z"))
        let reader = HermesReader(
            dbPathOverride: dbURL.path,
            usageLedger: ledger,
            now: { tokiTestISODate("2026-04-10T12:00:00Z") })

        let usage = try await reader.readUsage(
            from: tokiTestISODate("2026-04-10T00:00:00Z"),
            to: tokiTestISODate("2026-04-11T00:00:00Z"))

        XCTAssertEqual(usage.inputTokens, 1100)
        XCTAssertEqual(usage.outputTokens, 220)
        XCTAssertEqual(usage.cacheReadTokens, 305)
        XCTAssertEqual(usage.cacheWriteTokens, 40)
        XCTAssertEqual(usage.reasoningTokens, 52)
        XCTAssertEqual(usage.totalTokens, 1717)
        XCTAssertEqual(usage.cost, 1.2, accuracy: 0.000001)
        XCTAssertEqual(usage.perModel["gpt-5.5"]?.totalTokens, 1717)
    }

    func test_hermesReader_fallsBackToSessionsWhenModelUsageSchemaIsIncomplete() async throws {
        let tempDir = try makeHermesTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let dbURL = tempDir.appendingPathComponent("state.db")
        try createHermesStateDB(
            at: dbURL,
            rows: [hermesSingleCounterFixture(id: "legacy-session", inputTokens: 123)])
        try createIncompleteHermesModelUsageTable(databaseURL: dbURL)
        let ledger = HermesUsageLedger(fileURL: tempDir.appendingPathComponent("hermes-usage-ledger.json"))
        try await ledger.refresh(
            observations: [],
            observedAt: tokiTestISODate("2026-04-09T07:00:00Z"))
        let reader = HermesReader(
            dbPathOverride: dbURL.path,
            usageLedger: ledger,
            now: { tokiTestISODate("2026-04-10T12:00:00Z") })

        let usage = try await reader.readUsage(
            from: tokiTestISODate("2026-04-09T00:00:00Z"),
            to: tokiTestISODate("2026-04-11T00:00:00Z"))

        XCTAssertEqual(usage.inputTokens, 123)
        XCTAssertEqual(usage.totalTokens, 123)
    }

    func test_hermesReader_reportsZeroTokenMainCallsWithoutCountingAuxiliaryUsage() throws {
        let tempDir = try makeHermesTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let dbURL = tempDir.appendingPathComponent("state.db")
        try createHermesStateDB(
            at: dbURL,
            rows: [hermesSingleCounterFixture(id: "discord-session", inputTokens: 0)])
        try insertHermesModelUsage(
            databaseURL: dbURL,
            rows: [
                HermesModelUsageFixture(
                    sessionID: "discord-session",
                    model: "gpt-5.5",
                    task: "",
                    apiCallCount: 3,
                    inputTokens: 0,
                    outputTokens: 0,
                    cacheReadTokens: 0,
                    cacheWriteTokens: 0,
                    reasoningTokens: 0,
                    estimatedCost: 0,
                    actualCost: 0),
                HermesModelUsageFixture(
                    sessionID: "discord-session",
                    model: "gpt-5.5",
                    task: "approval",
                    apiCallCount: 2,
                    inputTokens: 100,
                    outputTokens: 20,
                    cacheReadTokens: 0,
                    cacheWriteTokens: 0,
                    reasoningTokens: 0,
                    estimatedCost: 0,
                    actualCost: 0),
            ])
        let reader = HermesReader(
            dbPathOverride: dbURL.path,
            usageLedger: HermesUsageLedger(fileURL: tempDir.appendingPathComponent("hermes-usage-ledger.json")))

        let coverage = try reader.coverageStatus()

        XCTAssertEqual(coverage.unmeteredMainAPICallCount, 3)
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
        try insertHermesMessage(
            databaseURL: dbURL,
            sessionID: "inside",
            timestamp: tokiTestISODate("2026-04-10T09:30:00Z"))
        try insertHermesMessage(
            databaseURL: dbURL,
            sessionID: "outside",
            timestamp: tokiTestISODate("2026-04-11T00:00:30Z"))
        let ledger = HermesUsageLedger(fileURL: tempDir.appendingPathComponent("hermes-usage-ledger.json"))
        try await ledger.refresh(
            observations: [],
            observedAt: tokiTestISODate("2026-04-09T00:00:00Z"))
        let reader = HermesReader(
            dbPathOverride: dbURL.path,
            usageLedger: ledger,
            now: { tokiTestISODate("2026-04-11T01:00:00Z") })

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
        let reader = HermesReader(
            dbPathOverride: dbURL.path,
            usageLedger: HermesUsageLedger(fileURL: tempDir.appendingPathComponent("hermes-usage-ledger.json")),
            now: { tokiTestISODate("2026-04-10T12:00:00Z") })

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

func makeHermesTemporaryDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(
        at: url,
        withIntermediateDirectories: true,
        attributes: [.posixPermissions: 0o700])
    return url
}

func hermesSingleCounterFixture(
    id: String,
    inputTokens: Int) -> HermesSessionFixture {
    HermesSessionFixture(
        id: id,
        startedAt: "2026-04-09T08:00:00Z",
        model: "gpt-5.5",
        inputTokens: inputTokens,
        outputTokens: 0,
        cacheReadTokens: 0,
        cacheWriteTokens: 0,
        reasoningTokens: 0,
        cwd: nil,
        gitRepoRoot: nil,
        estimatedCost: 0,
        actualCost: nil)
}

func hermesObservation(
    sessionID: String,
    startedAt: Date,
    latestActivityAt: Date? = nil,
    inputTokens: Int) -> HermesSessionObservation {
    HermesSessionObservation(
        sessionID: sessionID,
        startedAt: startedAt,
        earliestActivityAt: latestActivityAt,
        latestActivityAt: latestActivityAt,
        model: "gpt-5.5",
        counters: HermesTokenCounters(
            inputTokens: inputTokens,
            outputTokens: 0,
            cacheReadTokens: 0,
            cacheWriteTokens: 0,
            reasoningTokens: 0),
        cost: 0,
        projectName: nil,
        attributionQuality: .unknown)
}

func writePrivateHermesTestData(_ data: Data, to url: URL) throws {
    try data.write(to: url)
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
}

func assertHermesLedgerReadFails(
    _ ledger: HermesUsageLedger,
    file: StaticString = #filePath,
    line: UInt = #line) async {
    do {
        _ = try await ledger.events(
            from: tokiTestISODate("2026-04-10T00:00:00Z"),
            to: tokiTestISODate("2026-04-11T00:00:00Z"))
        XCTFail("Expected the unsafe Hermes ledger to be rejected", file: file, line: line)
    } catch let error as HermesUsageLedgerError {
        switch error {
        case .invalidLedger, .ledgerTooLarge:
            break
        case .invalidObservation, .couldNotPersist, .durabilityNotConfirmed:
            XCTFail("Unexpected Hermes ledger error", file: file, line: line)
        }
    } catch {
        XCTFail("Unexpected error type", file: file, line: line)
    }
}

struct HermesSessionFixture {
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

struct HermesModelUsageFixture {
    let sessionID: String
    let model: String
    let task: String
    let apiCallCount: Int
    let inputTokens: Int
    let outputTokens: Int
    let cacheReadTokens: Int
    let cacheWriteTokens: Int
    let reasoningTokens: Int
    let estimatedCost: Double
    let actualCost: Double
}

private let hermesTestSQLiteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

func createHermesStateDB(
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
        );
        CREATE TABLE messages (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            session_id TEXT NOT NULL,
            timestamp REAL NOT NULL
        );
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

func insertHermesModelUsage(
    databaseURL: URL,
    rows: [HermesModelUsageFixture]) throws {
    var database: OpaquePointer?
    guard sqlite3_open(databaseURL.path, &database) == SQLITE_OK, let database else {
        throw NSError(domain: "HermesReaderTests", code: 12)
    }
    defer { sqlite3_close(database) }

    guard sqlite3_exec(
        database,
        """
        CREATE TABLE IF NOT EXISTS session_model_usage (
            session_id TEXT NOT NULL,
            model TEXT NOT NULL,
            billing_provider TEXT NOT NULL DEFAULT '',
            billing_base_url TEXT NOT NULL DEFAULT '',
            task TEXT NOT NULL DEFAULT '',
            api_call_count INTEGER NOT NULL DEFAULT 0,
            input_tokens INTEGER NOT NULL DEFAULT 0,
            output_tokens INTEGER NOT NULL DEFAULT 0,
            cache_read_tokens INTEGER NOT NULL DEFAULT 0,
            cache_write_tokens INTEGER NOT NULL DEFAULT 0,
            reasoning_tokens INTEGER NOT NULL DEFAULT 0,
            estimated_cost_usd REAL NOT NULL DEFAULT 0,
            actual_cost_usd REAL NOT NULL DEFAULT 0
        );
        """,
        nil,
        nil,
        nil) == SQLITE_OK else {
        throw NSError(domain: "HermesReaderTests", code: 13)
    }

    var statement: OpaquePointer?
    guard sqlite3_prepare_v2(
        database,
        """
        INSERT INTO session_model_usage(
            session_id,
            model,
            task,
            api_call_count,
            input_tokens,
            output_tokens,
            cache_read_tokens,
            cache_write_tokens,
            reasoning_tokens,
            estimated_cost_usd,
            actual_cost_usd
        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        """,
        -1,
        &statement,
        nil) == SQLITE_OK, let statement else {
        throw NSError(domain: "HermesReaderTests", code: 14)
    }
    defer { sqlite3_finalize(statement) }

    for row in rows {
        sqlite3_reset(statement)
        sqlite3_clear_bindings(statement)
        guard sqlite3_bind_text(statement, 1, row.sessionID, -1, hermesTestSQLiteTransient) == SQLITE_OK,
              sqlite3_bind_text(statement, 2, row.model, -1, hermesTestSQLiteTransient) == SQLITE_OK,
              sqlite3_bind_text(statement, 3, row.task, -1, hermesTestSQLiteTransient) == SQLITE_OK,
              sqlite3_bind_int64(statement, 4, Int64(row.apiCallCount)) == SQLITE_OK,
              sqlite3_bind_int64(statement, 5, Int64(row.inputTokens)) == SQLITE_OK,
              sqlite3_bind_int64(statement, 6, Int64(row.outputTokens)) == SQLITE_OK,
              sqlite3_bind_int64(statement, 7, Int64(row.cacheReadTokens)) == SQLITE_OK,
              sqlite3_bind_int64(statement, 8, Int64(row.cacheWriteTokens)) == SQLITE_OK,
              sqlite3_bind_int64(statement, 9, Int64(row.reasoningTokens)) == SQLITE_OK,
              sqlite3_bind_double(statement, 10, row.estimatedCost) == SQLITE_OK,
              sqlite3_bind_double(statement, 11, row.actualCost) == SQLITE_OK,
              sqlite3_step(statement) == SQLITE_DONE else {
            throw NSError(domain: "HermesReaderTests", code: 15)
        }
    }
}

func createIncompleteHermesModelUsageTable(databaseURL: URL) throws {
    var database: OpaquePointer?
    guard sqlite3_open(databaseURL.path, &database) == SQLITE_OK, let database else {
        throw NSError(domain: "HermesReaderTests", code: 16)
    }
    defer { sqlite3_close(database) }

    guard sqlite3_exec(
        database,
        "CREATE TABLE session_model_usage (session_id TEXT NOT NULL);",
        nil,
        nil,
        nil) == SQLITE_OK else {
        throw NSError(domain: "HermesReaderTests", code: 17)
    }
}

func updateHermesModelUsage(
    databaseURL: URL,
    sessionID: String,
    task: String,
    inputTokens: Int) throws {
    var database: OpaquePointer?
    guard sqlite3_open(databaseURL.path, &database) == SQLITE_OK, let database else {
        throw NSError(domain: "HermesReaderTests", code: 18)
    }
    defer { sqlite3_close(database) }

    var statement: OpaquePointer?
    guard sqlite3_prepare_v2(
        database,
        """
        UPDATE session_model_usage
        SET input_tokens = ?
        WHERE session_id = ? AND task = ?
        """,
        -1,
        &statement,
        nil) == SQLITE_OK, let statement else {
        throw NSError(domain: "HermesReaderTests", code: 19)
    }
    defer { sqlite3_finalize(statement) }

    guard sqlite3_bind_int64(statement, 1, Int64(inputTokens)) == SQLITE_OK,
          sqlite3_bind_text(statement, 2, sessionID, -1, hermesTestSQLiteTransient) == SQLITE_OK,
          sqlite3_bind_text(statement, 3, task, -1, hermesTestSQLiteTransient) == SQLITE_OK,
          sqlite3_step(statement) == SQLITE_DONE,
          sqlite3_changes(database) == 1 else {
        throw NSError(domain: "HermesReaderTests", code: 20)
    }
}

func updateHermesSession(
    databaseURL: URL,
    id: String,
    model: String,
    inputTokens: Int,
    outputTokens: Int = 0,
    cacheReadTokens: Int = 0,
    cacheWriteTokens: Int = 0,
    reasoningTokens: Int = 0) throws {
    var database: OpaquePointer?
    guard sqlite3_open(databaseURL.path, &database) == SQLITE_OK, let database else {
        throw NSError(domain: "HermesReaderTests", code: 6)
    }
    defer { sqlite3_close(database) }

    var statement: OpaquePointer?
    guard sqlite3_prepare_v2(
        database,
        """
        UPDATE sessions
        SET model = ?, input_tokens = ?, output_tokens = ?, cache_read_tokens = ?,
            cache_write_tokens = ?, reasoning_tokens = ?
        WHERE id = ?
        """,
        -1,
        &statement,
        nil) == SQLITE_OK, let statement else {
        throw NSError(domain: "HermesReaderTests", code: 7)
    }
    defer { sqlite3_finalize(statement) }

    guard sqlite3_bind_text(statement, 1, model, -1, hermesTestSQLiteTransient) == SQLITE_OK,
          sqlite3_bind_int64(statement, 2, Int64(inputTokens)) == SQLITE_OK,
          sqlite3_bind_int64(statement, 3, Int64(outputTokens)) == SQLITE_OK,
          sqlite3_bind_int64(statement, 4, Int64(cacheReadTokens)) == SQLITE_OK,
          sqlite3_bind_int64(statement, 5, Int64(cacheWriteTokens)) == SQLITE_OK,
          sqlite3_bind_int64(statement, 6, Int64(reasoningTokens)) == SQLITE_OK,
          sqlite3_bind_text(statement, 7, id, -1, hermesTestSQLiteTransient) == SQLITE_OK,
          sqlite3_step(statement) == SQLITE_DONE else {
        throw NSError(domain: "HermesReaderTests", code: 8)
    }
}

func insertHermesMessage(
    databaseURL: URL,
    sessionID: String,
    timestamp: Date) throws {
    var database: OpaquePointer?
    guard sqlite3_open(databaseURL.path, &database) == SQLITE_OK, let database else {
        throw NSError(domain: "HermesReaderTests", code: 9)
    }
    defer { sqlite3_close(database) }

    var statement: OpaquePointer?
    guard sqlite3_prepare_v2(
        database,
        "INSERT INTO messages(session_id, timestamp) VALUES (?, ?)",
        -1,
        &statement,
        nil) == SQLITE_OK, let statement else {
        throw NSError(domain: "HermesReaderTests", code: 10)
    }
    defer { sqlite3_finalize(statement) }

    guard sqlite3_bind_text(statement, 1, sessionID, -1, hermesTestSQLiteTransient) == SQLITE_OK,
          sqlite3_bind_double(statement, 2, timestamp.timeIntervalSince1970) == SQLITE_OK,
          sqlite3_step(statement) == SQLITE_DONE else {
        throw NSError(domain: "HermesReaderTests", code: 11)
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
