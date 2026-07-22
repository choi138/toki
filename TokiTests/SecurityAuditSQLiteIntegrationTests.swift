import SQLite3
import XCTest
@testable import Toki

final class SecurityAuditSQLiteIntegrationTests: SecurityAuditScannerTestCase {
    func testScannerReadsCursorAndOpenCodeSQLiteTextRows() async throws {
        let sources = SecurityAuditScanner.defaultSources(homeDirectory: tempRoot)
        let cursorRoot = try XCTUnwrap(sources.first { $0.name == "Cursor" }).rootURL
        let openCodeRoot = try XCTUnwrap(sources.first { $0.name == "OpenCode" }).rootURL
        try FileManager.default.createDirectory(at: cursorRoot, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: openCodeRoot, withIntermediateDirectories: true)

        let cursorDB = cursorRoot.appendingPathComponent("state.vscdb")
        let openCodeDB = openCodeRoot.appendingPathComponent("opencode.db")
        try createSecurityAuditSQLiteDB(
            at: cursorDB,
            statements: [
                "CREATE TABLE cursorDiskKV (key TEXT, value BLOB)",
                """
                INSERT INTO cursorDiskKV(key, value)
                VALUES ('bubbleId:secret', '{"text":"\(SecurityAuditTestSecret.githubToken)"}')
                """,
            ])
        try createSecurityAuditSQLiteDB(
            at: openCodeDB,
            statements: [
                "CREATE TABLE message (data TEXT)",
                """
                INSERT INTO message(data)
                VALUES ('{"text":"\(SecurityAuditTestSecret.npmToken)"}')
                """,
            ])

        let result = await scanner(for: ["Cursor", "OpenCode"]).scan()

        XCTAssertEqual(result.scannedFileCount, 2)
        XCTAssertEqual(Set(result.findings.map(\.sourceName)), ["Cursor", "OpenCode"])
        XCTAssertEqual(Set(result.findings.map(\.ruleName)), ["GitHub token", "npm token"])
    }

    func testScannerInvalidatesSQLiteCacheWhenWriteAheadLogChanges() async throws {
        let counter = SecurityAuditValidatorCounter()
        let cursorRoot = try XCTUnwrap(
            SecurityAuditScanner.defaultSources(homeDirectory: tempRoot)
                .first { $0.name == "Cursor" }?
                .rootURL)
        try FileManager.default.createDirectory(at: cursorRoot, withIntermediateDirectories: true)

        let cursorDB = cursorRoot.appendingPathComponent("state.vscdb")
        var database: OpaquePointer?
        guard sqlite3_open(cursorDB.path, &database) == SQLITE_OK, let database else {
            throw NSError(domain: "SecurityAuditScannerTests", code: 1)
        }
        defer { sqlite3_close(database) }

        try executeSecurityAuditSQLiteStatement("PRAGMA journal_mode=WAL", database: database)
        try executeSecurityAuditSQLiteStatement("PRAGMA wal_autocheckpoint=0", database: database)
        try executeSecurityAuditSQLiteStatement(
            "CREATE TABLE cursorDiskKV (key TEXT, value TEXT)",
            database: database)
        try executeSecurityAuditSQLiteStatement(
            "INSERT INTO cursorDiskKV(key, value) VALUES ('first', 'cache-secret-ABCDEFGHIJKLMNOP')",
            database: database)

        let scanner = scanner(
            for: ["Cursor"],
            rules: [countingRule(counter: counter)],
            cacheStore: cache())

        let firstResult = await scanner.scan()
        try executeSecurityAuditSQLiteStatement(
            "INSERT INTO cursorDiskKV(key, value) VALUES ('second', 'cache-secret-ZYXWVUTSRQPONMLK')",
            database: database)
        let secondResult = await scanner.scan()

        XCTAssertTrue(FileManager.default.fileExists(atPath: cursorDB.path + "-wal"))
        XCTAssertEqual(firstResult.findings.count, 1)
        XCTAssertEqual(secondResult.findings.count, 2)
        XCTAssertEqual(counter.count, 3)
    }
}
