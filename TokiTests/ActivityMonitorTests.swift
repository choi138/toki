import SQLite3
import XCTest
@testable import Toki

final class ActivityMonitorTests: XCTestCase {
    func test_activityMonitor_detectsRecentCursorComposerActivity() throws {
        let dbPath = try makeCursorActivityDatabase(
            lastUpdatedAt: Int64(Date().timeIntervalSince1970 * 1000),
            bubbleCreatedAt: nil,
            bubblePayloadOverride: nil)

        XCTAssertTrue(ActivityMonitor.isCursorActive(dbPath: dbPath, since: Date().addingTimeInterval(-30)))
    }

    func test_activityMonitor_ignoresStaleCursorComposerActivity() throws {
        let staleDate = Date().addingTimeInterval(-180)
        let dbPath = try makeCursorActivityDatabase(
            lastUpdatedAt: Int64(staleDate.timeIntervalSince1970 * 1000),
            bubbleCreatedAt: nil,
            bubblePayloadOverride: nil)

        XCTAssertFalse(ActivityMonitor.isCursorActive(dbPath: dbPath, since: Date().addingTimeInterval(-30)))
    }

    func test_activityMonitor_detectsRecentCursorBubbleActivity() throws {
        let recentBubbleDate = Date()
        let staleComposerDate = Date().addingTimeInterval(-180)
        let dbPath = try makeCursorActivityDatabase(
            lastUpdatedAt: Int64(staleComposerDate.timeIntervalSince1970 * 1000),
            bubbleCreatedAt: recentBubbleDate,
            bubblePayloadOverride: nil)

        XCTAssertTrue(ActivityMonitor.isCursorActive(dbPath: dbPath, since: Date().addingTimeInterval(-30)))
    }

    func test_activityMonitor_ignoresStaleCursorBubbleActivity() throws {
        let staleBubbleDate = Date().addingTimeInterval(-180)
        let staleComposerDate = Date().addingTimeInterval(-180)
        let dbPath = try makeCursorActivityDatabase(
            lastUpdatedAt: Int64(staleComposerDate.timeIntervalSince1970 * 1000),
            bubbleCreatedAt: staleBubbleDate,
            bubblePayloadOverride: nil)

        XCTAssertFalse(ActivityMonitor.isCursorActive(dbPath: dbPath, since: Date().addingTimeInterval(-30)))
    }

    func test_activityMonitor_ignoresCursorBubbleWithoutCreatedAt() throws {
        let staleComposerDate = Date().addingTimeInterval(-180)
        let dbPath = try makeCursorActivityDatabase(
            lastUpdatedAt: Int64(staleComposerDate.timeIntervalSince1970 * 1000),
            bubbleCreatedAt: nil,
            bubblePayloadOverride: #"{"createdAt":null}"#)

        XCTAssertFalse(ActivityMonitor.isCursorActive(dbPath: dbPath, since: Date().addingTimeInterval(-30)))
    }

    func test_tokenVelocityMonitor_firstSampleStartsAtZeroVelocity() async throws {
        let reader = TokenTotalSequence([120])
        let monitor = TokenVelocityMonitor(readDailyTokenTotal: { _, _ in
            await reader.next()
        })

        let sample = await monitor.sample(at: tokiTestISODate("2026-04-10T10:00:00Z"))

        XCTAssertEqual(sample.totalTokens, 120)
        XCTAssertEqual(sample.tokensPerSecond, 0)
    }

    func test_tokenVelocityMonitor_calculatesTokenVelocityFromDailyTotalDelta() async throws {
        let reader = TokenTotalSequence([120, 180])
        let monitor = TokenVelocityMonitor(
            smoothingWeight: 1,
            readDailyTokenTotal: { _, _ in
                await reader.next()
            })

        _ = await monitor.sample(at: tokiTestISODate("2026-04-10T10:00:00Z"))
        let sample = await monitor.sample(at: tokiTestISODate("2026-04-10T10:00:05Z"))

        XCTAssertEqual(sample.totalTokens, 180)
        XCTAssertEqual(sample.tokensPerSecond, 12, accuracy: 0.000001)
    }

    func test_tokenVelocityMonitor_clampsNegativeTokenDeltasToZero() async throws {
        let reader = TokenTotalSequence([180, 120])
        let monitor = TokenVelocityMonitor(readDailyTokenTotal: { _, _ in
            await reader.next()
        })

        _ = await monitor.sample(at: tokiTestISODate("2026-04-10T10:00:00Z"))
        let sample = await monitor.sample(at: tokiTestISODate("2026-04-10T10:00:05Z"))

        XCTAssertEqual(sample.totalTokens, 120)
        XCTAssertEqual(sample.tokensPerSecond, 0)
    }

    func test_tokenVelocityMonitor_decaysVelocityWhenTokenTotalIsUnchanged() async throws {
        let reader = TokenTotalSequence([100, 200, 200])
        let monitor = TokenVelocityMonitor(
            smoothingWeight: 0.5,
            readDailyTokenTotal: { _, _ in
                await reader.next()
            })

        _ = await monitor.sample(at: tokiTestISODate("2026-04-10T10:00:00Z"))
        let activeSample = await monitor.sample(at: tokiTestISODate("2026-04-10T10:00:05Z"))
        let quietSample = await monitor.sample(at: tokiTestISODate("2026-04-10T10:00:10Z"))

        XCTAssertEqual(activeSample.tokensPerSecond, 20, accuracy: 0.000001)
        XCTAssertEqual(quietSample.tokensPerSecond, 10, accuracy: 0.000001)
    }

    func test_tokenVelocityMonitor_resetsVelocityAcrossCalendarDays() async throws {
        let reader = TokenTotalSequence([1_000, 20])
        let monitor = TokenVelocityMonitor(readDailyTokenTotal: { _, _ in
            await reader.next()
        })

        _ = await monitor.sample(at: tokiTestISODate("2026-04-10T23:59:58Z"))
        let sample = await monitor.sample(at: tokiTestISODate("2026-04-11T00:00:03Z"))

        XCTAssertEqual(sample.totalTokens, 20)
        XCTAssertEqual(sample.tokensPerSecond, 0)
    }

    func test_tokenVelocityMonitor_resetDropsPreviousSample() async throws {
        let reader = TokenTotalSequence([100, 140])
        let monitor = TokenVelocityMonitor(readDailyTokenTotal: { _, _ in
            await reader.next()
        })

        _ = await monitor.sample(at: tokiTestISODate("2026-04-10T10:00:00Z"))
        await monitor.reset()
        let sample = await monitor.sample(at: tokiTestISODate("2026-04-10T10:00:05Z"))

        XCTAssertEqual(sample.totalTokens, 140)
        XCTAssertEqual(sample.tokensPerSecond, 0)
    }

    func test_rabbitRunAnimationSpeedAcceleratesAsVelocityIncreases() {
        let idle = RabbitRunAnimationSpeed.frameInterval(tokensPerSecond: 0)
        let medium = RabbitRunAnimationSpeed.frameInterval(tokensPerSecond: 20)
        let fast = RabbitRunAnimationSpeed.frameInterval(tokensPerSecond: 200)
        let veryFast = RabbitRunAnimationSpeed.frameInterval(tokensPerSecond: 1_000)
        let flood = RabbitRunAnimationSpeed.frameInterval(tokensPerSecond: 5_000)
        let burst = RabbitRunAnimationSpeed.frameInterval(tokensPerSecond: 10_000)
        let clampedBurst = RabbitRunAnimationSpeed.frameInterval(tokensPerSecond: 20_000)

        XCTAssertEqual(idle, RabbitRunAnimationSpeed.defaultFrameInterval)
        XCTAssertLessThan(medium, idle)
        XCTAssertLessThan(fast, medium)
        XCTAssertLessThan(veryFast, fast)
        XCTAssertLessThan(flood, veryFast)
        XCTAssertLessThan(burst, flood)
        XCTAssertEqual(clampedBurst, burst)
    }

    private func makeCursorActivityDatabase(
        lastUpdatedAt: Int64,
        bubbleCreatedAt: Date?,
        bubblePayloadOverride: String?) throws -> String {
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
            sqlite3_bind_text(statement, 1, "composerData:test", -1, sqliteTransient),
            SQLITE_OK)
        XCTAssertEqual(
            sqlite3_bind_text(statement, 2, payload, -1, sqliteTransient),
            SQLITE_OK)
        XCTAssertEqual(sqlite3_step(statement), SQLITE_DONE)

        let bubblePayload = bubblePayloadOverride ?? bubbleCreatedAt.map { bubbleCreatedAt in
            """
            {"createdAt":"\(ActivityMonitorTests.cursorBubbleFormatter.string(from: bubbleCreatedAt))"}
            """
        }

        if let bubblePayload {
            var bubbleStatement: OpaquePointer?
            XCTAssertEqual(sqlite3_prepare_v2(db, insertSQL, -1, &bubbleStatement, nil), SQLITE_OK)
            defer { sqlite3_finalize(bubbleStatement) }
            XCTAssertEqual(
                sqlite3_bind_text(
                    bubbleStatement,
                    1,
                    "bubbleId:test",
                    -1,
                    sqliteTransient),
                SQLITE_OK)
            XCTAssertEqual(
                sqlite3_bind_text(
                    bubbleStatement,
                    2,
                    bubblePayload,
                    -1,
                    sqliteTransient),
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

private actor TokenTotalSequence {
    private var values: [Int]

    init(_ values: [Int]) {
        self.values = values
    }

    func next() -> Int {
        guard !values.isEmpty else { return 0 }
        return values.removeFirst()
    }
}
