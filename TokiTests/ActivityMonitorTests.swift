import SQLite3
import XCTest
@testable import Toki

private let activityMonitorSQLiteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

final class ActivityMonitorTests: XCTestCase {
    func test_activityMonitor_detectsRecentCursorComposerActivity() throws {
        let dbPath = try makeCursorActivityDatabase(
            lastUpdatedAt: Int64(Date().timeIntervalSince1970 * 1000),
            bubbleCreatedAt: nil)

        XCTAssertTrue(ActivityMonitor.isCursorActive(dbPath: dbPath, since: Date().addingTimeInterval(-30)))
    }

    func test_activityMonitor_ignoresStaleCursorComposerActivity() throws {
        let staleDate = Date().addingTimeInterval(-180)
        let dbPath = try makeCursorActivityDatabase(
            lastUpdatedAt: Int64(staleDate.timeIntervalSince1970 * 1000),
            bubbleCreatedAt: nil)

        XCTAssertFalse(ActivityMonitor.isCursorActive(dbPath: dbPath, since: Date().addingTimeInterval(-30)))
    }

    func test_activityMonitor_detectsRecentCursorBubbleActivity() throws {
        let recentBubbleDate = Date()
        let staleComposerDate = Date().addingTimeInterval(-180)
        let dbPath = try makeCursorActivityDatabase(
            lastUpdatedAt: Int64(staleComposerDate.timeIntervalSince1970 * 1000),
            bubbleCreatedAt: recentBubbleDate)

        XCTAssertTrue(ActivityMonitor.isCursorActive(dbPath: dbPath, since: Date().addingTimeInterval(-30)))
    }

    private func makeCursorActivityDatabase(
        lastUpdatedAt: Int64,
        bubbleCreatedAt: Date?) throws -> String {
        let directoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: directoryURL,
            withIntermediateDirectories: true)
        let dbURL = directoryURL.appendingPathComponent("state.vscdb")

        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(dbURL.path, &db), SQLITE_OK)
        defer { sqlite3_close(db) }

        XCTAssertEqual(
            sqlite3_exec(
                db,
                "CREATE TABLE cursorDiskKV (key TEXT PRIMARY KEY, value BLOB);",
                nil,
                nil,
                nil),
            SQLITE_OK)

        let payload = """
        {"composerId":"composer-1","lastUpdatedAt":\(lastUpdatedAt),"contextTokensUsed":128}
        """
        let insertSQL = "INSERT INTO cursorDiskKV(key, value) VALUES(?, ?);"
        var statement: OpaquePointer?
        XCTAssertEqual(sqlite3_prepare_v2(db, insertSQL, -1, &statement, nil), SQLITE_OK)
        defer { sqlite3_finalize(statement) }

        XCTAssertEqual(
            sqlite3_bind_text(statement, 1, "composerData:test", -1, activityMonitorSQLiteTransient),
            SQLITE_OK)
        XCTAssertEqual(
            sqlite3_bind_text(statement, 2, payload, -1, activityMonitorSQLiteTransient),
            SQLITE_OK)
        XCTAssertEqual(sqlite3_step(statement), SQLITE_DONE)

        if let bubbleCreatedAt {
            let bubblePayload = """
            {"createdAt":"\(ActivityMonitorTests.cursorBubbleFormatter.string(from: bubbleCreatedAt))"}
            """
            var bubbleStatement: OpaquePointer?
            XCTAssertEqual(sqlite3_prepare_v2(db, insertSQL, -1, &bubbleStatement, nil), SQLITE_OK)
            defer { sqlite3_finalize(bubbleStatement) }
            XCTAssertEqual(
                sqlite3_bind_text(
                    bubbleStatement,
                    1,
                    "bubbleId:test",
                    -1,
                    activityMonitorSQLiteTransient),
                SQLITE_OK)
            XCTAssertEqual(
                sqlite3_bind_text(
                    bubbleStatement,
                    2,
                    bubblePayload,
                    -1,
                    activityMonitorSQLiteTransient),
                SQLITE_OK)
            XCTAssertEqual(sqlite3_step(bubbleStatement), SQLITE_DONE)
        }

        return dbURL.path
    }

    private static let cursorBubbleFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()
}
