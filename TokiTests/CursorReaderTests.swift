import SQLite3
import XCTest
@testable import Toki

final class CursorReaderUsageTests: XCTestCase {
    func test_cursorReader_aggregatesTokenUsageByUsageUuidAndModel() {
        let payloads = [
            cursorModelBubble(
                bubbleId: "model-gpt",
                requestId: "usage-gpt",
                createdAt: "2026-04-10T00:00:01Z",
                modelName: "gpt-5.2"),
            cursorTokenBubble(
                bubbleId: "token-gpt",
                usageUuid: "usage-gpt",
                createdAt: "2026-04-10T00:00:02Z",
                input: 120,
                output: 30),
            cursorModelBubble(
                bubbleId: "model-claude",
                requestId: "usage-claude",
                createdAt: "2026-04-10T02:00:00Z",
                modelName: "claude-4.5-sonnet-thinking"),
            cursorTokenBubble(
                bubbleId: "token-claude",
                usageUuid: "usage-claude",
                createdAt: "2026-04-10T02:00:05Z",
                input: 80,
                output: 20),
            cursorTokenBubble(
                bubbleId: "token-outside-range",
                usageUuid: "usage-old",
                createdAt: "2026-04-09T23:59:59Z",
                input: 999,
                output: 999),
        ]

        let usage = CursorReader.usage(
            fromBubblePayloads: payloads,
            from: tokiTestISODate("2026-04-10T00:00:00Z"),
            to: tokiTestISODate("2026-04-11T00:00:00Z"))

        XCTAssertEqual(usage.inputTokens, 200)
        XCTAssertEqual(usage.outputTokens, 50)
        XCTAssertEqual(usage.totalTokens, 250)
        XCTAssertEqual(usage.perModel["gpt-5.2"]?.totalTokens, 150)
        XCTAssertEqual(usage.perModel["claude-4.5-sonnet-thinking"]?.totalTokens, 100)
        XCTAssertEqual(usage.cost, 0.00117, accuracy: 0.000001)
    }

    func test_cursorReader_deduplicatesTokenBearingBubblesPerUsageUuid() {
        let payloads = [
            cursorModelBubble(
                bubbleId: "model-1",
                requestId: "usage-1",
                createdAt: "2026-04-10T09:00:00Z",
                modelName: "gpt-5.4-xhigh"),
            cursorTokenBubble(
                bubbleId: "token-1",
                usageUuid: "usage-1",
                createdAt: "2026-04-10T09:00:01Z",
                input: 100,
                output: 40),
            cursorTokenBubble(
                bubbleId: "token-1-duplicate",
                usageUuid: "usage-1",
                createdAt: "2026-04-10T09:00:02Z",
                input: 100,
                output: 40),
        ]

        let usage = CursorReader.usage(
            fromBubblePayloads: payloads,
            from: tokiTestISODate("2026-04-10T00:00:00Z"),
            to: tokiTestISODate("2026-04-11T00:00:00Z"))

        XCTAssertEqual(usage.inputTokens, 100)
        XCTAssertEqual(usage.outputTokens, 40)
        XCTAssertEqual(usage.totalTokens, 140)
        XCTAssertEqual(usage.perModel["gpt-5.4-xhigh"]?.totalTokens, 140)
        XCTAssertEqual(usage.cost, 0.00085, accuracy: 0.000001)
    }

    func test_cursorReader_prefersLatestTokenBubblePerUsageUuid() {
        let payloads = [
            cursorModelBubble(
                bubbleId: "model-1",
                requestId: "usage-1",
                createdAt: "2026-04-10T09:00:00Z",
                modelName: "gpt-5.4-xhigh"),
            cursorTokenBubble(
                bubbleId: "token-earlier",
                usageUuid: "usage-1",
                createdAt: "2026-04-10T09:00:01Z",
                input: 100,
                output: 40),
            cursorTokenBubble(
                bubbleId: "token-later",
                usageUuid: "usage-1",
                createdAt: "2026-04-10T09:00:02Z",
                input: 120,
                output: 50),
        ]

        let usage = CursorReader.usage(
            fromBubblePayloads: payloads,
            from: tokiTestISODate("2026-04-10T00:00:00Z"),
            to: tokiTestISODate("2026-04-11T00:00:00Z"))

        XCTAssertEqual(usage.inputTokens, 120)
        XCTAssertEqual(usage.outputTokens, 50)
        XCTAssertEqual(usage.totalTokens, 170)
        XCTAssertEqual(usage.perModel["gpt-5.4-xhigh"]?.totalTokens, 170)
    }

    func test_cursorReader_collectsContextOnlyMetricsFromComposerData() {
        let bubblePayloads = [
            cursorModelBubble(
                bubbleId: "bubble-backed-model",
                requestId: "usage-bubble-backed",
                createdAt: "2026-04-10T08:59:59Z",
                modelName: "gpt-5.4-xhigh"),
            cursorTokenBubble(
                bubbleId: "bubble-backed-token",
                usageUuid: "usage-bubble-backed",
                createdAt: "2026-04-10T09:00:00Z",
                input: 40,
                output: 10),
        ]
        let composerPayloads = [
            cursorComposerData(
                composerId: "composer-1",
                createdAtMillis: tokiTestEpochMillis("2026-04-09T09:00:00Z"),
                lastUpdatedAtMillis: tokiTestEpochMillis("2026-04-10T09:00:00Z"),
                modelName: "gpt-5.4-xhigh",
                contextTokensUsed: 51540,
                usageData: ["gpt-5.4-xhigh": (amount: 1, costInCents: 125)],
                linkedBubbleIDs: ["bubble-backed-token"]),
            cursorComposerData(
                composerId: "composer-2",
                createdAtMillis: tokiTestEpochMillis("2026-04-10T10:00:00Z"),
                lastUpdatedAtMillis: nil,
                modelName: "gpt-5.4-medium",
                contextTokensUsed: 9000,
                usageData: [:],
                linkedBubbleIDs: []),
            cursorComposerData(
                composerId: "composer-outside-range",
                createdAtMillis: tokiTestEpochMillis("2026-04-09T10:00:00Z"),
                lastUpdatedAtMillis: tokiTestEpochMillis("2026-04-09T11:00:00Z"),
                modelName: "gpt-5.4-medium",
                contextTokensUsed: 999,
                usageData: [:],
                linkedBubbleIDs: []),
        ]

        let usage = CursorReader.usage(
            fromBubblePayloads: bubblePayloads,
            composerPayloads: composerPayloads,
            from: tokiTestISODate("2026-04-10T00:00:00Z"),
            to: tokiTestISODate("2026-04-11T00:00:00Z"))

        XCTAssertEqual(usage.totalTokens, 50)

        let contextEntries = usage.supplemental.filter { $0.label == "Cursor Context" }
        XCTAssertEqual(contextEntries.map(\.value).sorted(), [9000, 51540])
        XCTAssertEqual(
            Set(contextEntries.compactMap(\.model)),
            Set(["gpt-5.4-medium", "gpt-5.4-xhigh"]))
        XCTAssertTrue(
            contextEntries.allSatisfy {
                !$0.includedInTotals && $0.quality == UsageQuality.contextOnly
            })
        XCTAssertFalse(usage.supplemental.contains { $0.label == "Cursor Sessions" })
        XCTAssertFalse(usage.supplemental.contains { $0.label == "Cursor Reported Cost" })
    }

    func test_cursorReader_includesLiveComposerContextOnlyForTodaySingleDay() {
        let now = tokiTestISODate("2026-04-10T12:00:00Z")
        let todayStart = tokiTestISODate("2026-04-10T00:00:00Z")
        let tomorrowStart = tokiTestISODate("2026-04-11T00:00:00Z")
        let yesterdayStart = tokiTestISODate("2026-04-09T00:00:00Z")
        let twoDaysLater = tokiTestISODate("2026-04-12T00:00:00Z")

        XCTAssertTrue(
            CursorReader.shouldIncludeLiveComposerContext(
                from: todayStart,
                to: tomorrowStart,
                now: now))
        XCTAssertFalse(
            CursorReader.shouldIncludeLiveComposerContext(
                from: yesterdayStart,
                to: todayStart,
                now: now))
        XCTAssertFalse(
            CursorReader.shouldIncludeLiveComposerContext(
                from: todayStart,
                to: twoDaysLater,
                now: now))
        XCTAssertFalse(
            CursorReader.shouldIncludeLiveComposerContext(
                from: tomorrowStart,
                to: twoDaysLater,
                now: now))
    }
}

final class CursorReaderDatabaseTests: XCTestCase {
    func test_cursorReader_readUsage_keepsModelLookupForZeroTokenModelBubbles() async throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let dbURL = tempDir.appendingPathComponent("state.vscdb")
        try createCursorStateDB(
            at: dbURL,
            rows: [
                (
                    "bubbleId:model-gpt",
                    cursorModelBubble(
                        bubbleId: "model-gpt",
                        requestId: "usage-gpt",
                        createdAt: "2026-04-10T00:00:01Z",
                        modelName: "gpt-5.2",
                        includeZeroTokenCount: true)),
                (
                    "bubbleId:token-gpt",
                    cursorTokenBubble(
                        bubbleId: "token-gpt",
                        usageUuid: "usage-gpt",
                        createdAt: "2026-04-10T00:00:02Z",
                        input: 120,
                        output: 30)),
            ])

        let reader = CursorReader(dbPathOverride: dbURL.path)
        let usage = try await reader.readUsage(
            from: tokiTestISODate("2026-04-10T00:00:00Z"),
            to: tokiTestISODate("2026-04-11T00:00:00Z"))

        XCTAssertEqual(usage.inputTokens, 120)
        XCTAssertEqual(usage.outputTokens, 30)
        XCTAssertEqual(usage.perModel["gpt-5.2"]?.totalTokens, 150)
        XCTAssertEqual(usage.cost, 0.00063, accuracy: 0.000001)
    }
}

private func tokiTestEpochMillis(_ value: String) -> Int64 {
    Int64(tokiTestISODate(value).timeIntervalSince1970 * 1000)
}

private func cursorTokenBubble(
    bubbleId: String,
    usageUuid: String,
    createdAt: String,
    input: Int,
    output: Int) -> String {
    """
    {"bubbleId":"\(bubbleId)","usageUuid":"\(usageUuid)","createdAt":"\(createdAt)","tokenCount":{"inputTokens":\(
        input),"outputTokens":\(output)}}
    """
}

private func cursorModelBubble(
    bubbleId: String,
    requestId: String,
    createdAt: String,
    modelName: String,
    includeZeroTokenCount: Bool = false) -> String {
    let tokenCountJSON = includeZeroTokenCount
        ? #","tokenCount":{"inputTokens":0,"outputTokens":0}"#
        : ""
    return """
    {"bubbleId":"\(bubbleId)","requestId":"\(requestId)","createdAt":"\(createdAt)","modelInfo":{"modelName":"\(
        modelName)"}\(tokenCountJSON)}
    """
}

private func cursorComposerData(
    composerId: String,
    createdAtMillis: Int64,
    lastUpdatedAtMillis: Int64?,
    modelName: String,
    contextTokensUsed: Int,
    usageData: [String: (amount: Int, costInCents: Int)],
    linkedBubbleIDs: [String]) -> String {
    let usageJSON = usageData
        .map { key, value in
            "\"\(key)\":{\"amount\":\(value.amount),\"costInCents\":\(value.costInCents)}"
        }
        .sorted()
        .joined(separator: ",")
    let lastUpdatedAtJSON = lastUpdatedAtMillis.map { ",\"lastUpdatedAt\":\($0)" } ?? ""
    let linkedBubbleIDsJSON = linkedBubbleIDs
        .map { #"{"bubbleId":"\#($0)","type":2}"# }
        .joined(separator: ",")

    return """
    {"composerId":"\(composerId)",
    "createdAt":\(createdAtMillis)\(lastUpdatedAtJSON),
    "modelConfig":{"modelName":"\(modelName)"},
    "contextTokensUsed":\(contextTokensUsed),
    "usageData":{\(usageJSON)},
    "fullConversationHeadersOnly":[\(linkedBubbleIDsJSON)]}
    """
}

private let cursorTestSQLiteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

private func createCursorStateDB(
    at url: URL,
    rows: [(key: String, value: String)]) throws {
    var db: OpaquePointer?
    guard sqlite3_open(url.path, &db) == SQLITE_OK, let db else {
        throw NSError(domain: "CursorReaderTests", code: 1)
    }
    defer { sqlite3_close(db) }

    guard sqlite3_exec(
        db,
        "CREATE TABLE cursorDiskKV (key TEXT, value BLOB)",
        nil,
        nil,
        nil) == SQLITE_OK else {
        throw NSError(domain: "CursorReaderTests", code: 2)
    }

    var stmt: OpaquePointer?
    guard sqlite3_prepare_v2(
        db,
        "INSERT INTO cursorDiskKV(key, value) VALUES (?, ?)",
        -1,
        &stmt,
        nil) == SQLITE_OK, let stmt else {
        throw NSError(domain: "CursorReaderTests", code: 3)
    }
    defer { sqlite3_finalize(stmt) }

    for row in rows {
        sqlite3_reset(stmt)
        sqlite3_clear_bindings(stmt)
        guard sqlite3_bind_text(stmt, 1, row.key, -1, cursorTestSQLiteTransient) == SQLITE_OK,
              sqlite3_bind_text(stmt, 2, row.value, -1, cursorTestSQLiteTransient) == SQLITE_OK,
              sqlite3_step(stmt) == SQLITE_DONE else {
            throw NSError(domain: "CursorReaderTests", code: 4)
        }
    }
}
