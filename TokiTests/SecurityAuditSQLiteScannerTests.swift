import SQLite3
import XCTest
@testable import Toki

final class SecurityAuditSQLiteScannerTests: XCTestCase {
    private var tempRoot: URL!

    override func setUpWithError() throws {
        tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("TokiSecurityAuditSQLiteTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: tempRoot,
            withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempRoot)
    }

    func testSQLiteScanFailuresAreNotCachedAsCleanResults() async throws {
        let source = try cursorSource()
        let cursorDB = try prepareCursorDatabaseRoot(for: source)
        try createSecurityAuditSQLiteDB(
            at: cursorDB,
            statements: ["CREATE TABLE unrelated (value TEXT)"])
        let cacheStore = cache()
        let scanner = SecurityAuditScanner(sources: [source], cacheStore: cacheStore)

        let firstResult = await scanner.scan()
        XCTAssertTrue(firstResult.findings.isEmpty)
        XCTAssertNil(cacheStore.load().entriesByPath[cursorDB.standardizedFileURL.path])

        try await withSQLiteDatabase(at: cursorDB) { database in
            try executeSecurityAuditSQLiteStatement(
                "CREATE TABLE cursorDiskKV (key TEXT, value TEXT)",
                database: database)
            try executeSecurityAuditSQLiteStatement(
                """
                INSERT INTO cursorDiskKV(key, value)
                VALUES ('fixed', '{"text":"\(SecurityAuditTestSQLiteSecret.githubToken)"}')
                """,
                database: database)
        }
        let secondResult = await scanner.scan()

        XCTAssertEqual(secondResult.findings.map(\.ruleName), ["GitHub token"])
    }

    func testModifiedAfterDiscoveryIncludesSQLiteWALChanges() async throws {
        let source = try cursorSource()
        let cursorDB = try prepareCursorDatabaseRoot(for: source)
        try await withSQLiteDatabase(at: cursorDB) { database in
            try executeSecurityAuditSQLiteStatement("PRAGMA journal_mode=WAL", database: database)
            try executeSecurityAuditSQLiteStatement("PRAGMA wal_autocheckpoint=0", database: database)
            try executeSecurityAuditSQLiteStatement(
                "CREATE TABLE cursorDiskKV (key TEXT, value TEXT)",
                database: database)

            let oldDate = Date(timeIntervalSince1970: 1000)
            try FileManager.default.setAttributes(
                [.modificationDate: oldDate],
                ofItemAtPath: cursorDB.path)
            let modifiedAfter = Date()
            try await Task.sleep(for: .milliseconds(10))
            try executeSecurityAuditSQLiteStatement(
                """
                INSERT INTO cursorDiskKV(key, value)
                VALUES ('wal-only', '{"text":"\(SecurityAuditTestSQLiteSecret.githubToken)"}')
                """,
                database: database)

            let scanner = SecurityAuditScanner(sources: [source], cacheStore: cache())
            let result = await scanner.scan(request: SecurityAuditRequest(modifiedAfter: modifiedAfter))

            XCTAssertEqual(result.scannedFileCount, 1)
            XCTAssertEqual(result.findings.map(\.ruleName), ["GitHub token"])
        }
    }

    private func cursorSource() throws -> SecurityAuditFileSource {
        try XCTUnwrap(
            SecurityAuditScanner.defaultSources(homeDirectory: tempRoot)
                .first { $0.name == "Cursor" })
    }

    private func prepareCursorDatabaseRoot(for source: SecurityAuditFileSource) throws -> URL {
        try FileManager.default.createDirectory(at: source.rootURL, withIntermediateDirectories: true)
        return source.rootURL.appendingPathComponent("state.vscdb")
    }

    private func cache() -> SecurityAuditCacheStore {
        SecurityAuditCacheStore(cacheURL: tempRoot.appendingPathComponent("SecurityAuditSQLiteCache.json"))
    }
}

private enum SecurityAuditTestSQLiteSecret {
    static var githubToken: String {
        "gh" + "p_" + "abcdefghijklmnopqrstuvwxyzABCDEFGHIJ"
    }
}

private func withSQLiteDatabase(at url: URL, _ body: (OpaquePointer?) async throws -> Void) async throws {
    var database: OpaquePointer?
    guard sqlite3_open(url.path, &database) == SQLITE_OK, let database else {
        throw NSError(domain: "SecurityAuditSQLiteScannerTests", code: 1)
    }
    defer { sqlite3_close(database) }

    try await body(database)
}
