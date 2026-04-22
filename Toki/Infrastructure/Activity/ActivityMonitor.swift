import Foundation
import SQLite3

// Detects whether any AI coding tool is currently active.

enum ActivityMonitor {
    private static let activeWindowSeconds: TimeInterval = 30
    private static let cursorActiveWindowSeconds: TimeInterval = 90
    private static let cursorDBPath = homeDir()
        .appendingPathComponent("Library/Application Support/Cursor/User/globalStorage/state.vscdb")
        .path
    private static let cursorBubbleTimestampFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    static func isAnyToolActive() -> Bool {
        let threshold = Date().addingTimeInterval(-activeWindowSeconds)
        let cursorThreshold = Date().addingTimeInterval(-cursorActiveWindowSeconds)
        // Cheap DB queries first; expensive directory scan last
        return isCodexActive(since: threshold)
            || isCursorActive(since: cursorThreshold)
            || isOpenCodeActive(since: threshold)
            || isClaudeCodeActive(since: threshold)
    }

    // MARK: - Claude Code

    /// Returns true only when Claude Code is actively using tools
    /// (tool_use / tool_result entries in JSONL), not just chatting.
    private static func isClaudeCodeActive(since threshold: Date) -> Bool {
        let projectsURL = homeDir().appendingPathComponent(".claude/projects")
        guard FileManager.default.fileExists(atPath: projectsURL.path),
              let enumerator = FileManager.default.enumerator(
                  at: projectsURL,
                  includingPropertiesForKeys: [.contentModificationDateKey],
                  options: [.skipsHiddenFiles]) else { return false }

        for case let url as URL in enumerator {
            guard url.pathExtension == "jsonl",
                  let mod = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate,
                  mod >= threshold else { continue }

            if hasRecentToolUse(in: url, since: threshold) { return true }
        }
        return false
    }

    // MARK: - Codex

    /// Queries threads.updated_at — only true when a thread was
    /// actually active recently, not just when the app is open.
    private static func isCodexActive(since threshold: Date) -> Bool {
        let dbPath = homeDir().appendingPathComponent(".codex/state_5.sqlite").path
        let epoch = Int64(threshold.timeIntervalSince1970)
        if queryCount(
            db: dbPath,
            sql: "SELECT COUNT(*) FROM threads WHERE updated_at >= ?",
            param: epoch) > 0 {
            return true
        }

        return hasRecentCodexRollout(since: threshold)
    }

    private static func hasRecentCodexRollout(since threshold: Date) -> Bool {
        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())
        let yesterday = cal.date(byAdding: .day, value: -1, to: today) ?? today
        let candidateDays = [yesterday, cal.startOfDay(for: threshold), today]

        let sessionDirs = Set(candidateDays.map { day in
            let comps = cal.dateComponents([.year, .month, .day], from: day)
            return homeDir()
                .appendingPathComponent(".codex/sessions")
                .appendingPathComponent(String(format: "%04d", comps.year ?? 0))
                .appendingPathComponent(String(format: "%02d", comps.month ?? 0))
                .appendingPathComponent(String(format: "%02d", comps.day ?? 0))
                .path
        })

        for dirPath in sessionDirs {
            let dirURL = URL(fileURLWithPath: dirPath)
            guard FileManager.default.fileExists(atPath: dirURL.path),
                  let enumerator = FileManager.default.enumerator(
                      at: dirURL,
                      includingPropertiesForKeys: [.contentModificationDateKey],
                      options: [.skipsHiddenFiles]) else { continue }

            for case let url as URL in enumerator {
                guard url.pathExtension == "jsonl",
                      let mod = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?
                      .contentModificationDate,
                      mod >= threshold else { continue }
                return true
            }
        }

        return false
    }

    // MARK: - Cursor

    /// Cursor agent/composer activity updates the mutable composerData snapshot.
    /// Internal visibility keeps the DB path injectable for focused unit tests.
    static func isCursorActive(
        dbPath: String = cursorDBPath,
        since threshold: Date) -> Bool {
        let epochMs = Int64(threshold.timeIntervalSince1970 * 1000)
        let thresholdText = cursorBubbleTimestampFormatter.string(from: threshold)
        return queryCursorComposerActivity(dbPath: dbPath, epochMs: epochMs)
            || queryCursorBubbleActivity(dbPath: dbPath, thresholdText: thresholdText)
    }

    private static func queryCursorComposerActivity(dbPath: String, epochMs: Int64) -> Bool {
        queryExists(
            db: dbPath,
            sql: """
                SELECT 1
                FROM cursorDiskKV
                WHERE key LIKE 'composerData:%'
                AND json_valid(CAST(value AS TEXT))
                AND CAST(COALESCE(
                    json_extract(CAST(value AS TEXT), '$.lastUpdatedAt'),
                    json_extract(CAST(value AS TEXT), '$.createdAt'),
                    0
                ) AS INTEGER) >= ?
                LIMIT 1
            """,
            int64Param: epochMs)
    }

    private static func queryCursorBubbleActivity(dbPath: String, thresholdText: String) -> Bool {
        queryExists(
            db: dbPath,
            sql: """
                SELECT 1
                FROM (
                    SELECT value
                    FROM cursorDiskKV
                    WHERE key LIKE 'bubbleId:%'
                    ORDER BY rowid DESC
                    LIMIT 50
                ) AS recentBubbles
                WHERE json_valid(CAST(value AS TEXT))
                AND json_extract(CAST(value AS TEXT), '$.createdAt') IS NOT NULL
                AND julianday(json_extract(CAST(value AS TEXT), '$.createdAt')) >= julianday(?)
                LIMIT 1
            """,
            textParam: thresholdText)
    }

    // MARK: - OpenCode

    /// Queries the indexed message timestamp (milliseconds) — only true
    /// when a message was created recently (active session).
    private static func isOpenCodeActive(since threshold: Date) -> Bool {
        let dbPath = homeDir().appendingPathComponent(".local/share/opencode/opencode.db").path
        let epochMs = Int64(threshold.timeIntervalSince1970 * 1000)
        return queryCount(
            db: dbPath,
            sql: "SELECT COUNT(*) FROM message WHERE time_created >= ?",
            param: epochMs) > 0
    }

    // MARK: - JSONL tool use detection

    private static func hasRecentToolUse(in url: URL, since threshold: Date) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? handle.close() }

        let fileSize = (try? handle.seekToEnd()) ?? 0
        guard fileSize > 0 else { return false }

        let decoder = JSONDecoder()

        // Start at 256 KB; double until recent records are complete or we reach the file start.
        var readSize = UInt64(min(262_144, fileSize))
        while true {
            let readOffset = fileSize - readSize
            let startsAtRecordBoundary = isJSONLRecordBoundary(handle: handle, offset: readOffset)
            try? handle.seek(toOffset: readOffset)
            var data = handle.readDataToEndOfFile()

            // If the window starts mid-record, skip the truncated prefix for this pass,
            // but keep growing until that newest omitted record becomes complete.
            if !startsAtRecordBoundary,
               let firstNewline = data.firstIndex(of: UInt8(ascii: "\n")) {
                data = Data(data[(firstNewline + 1)...])
            }

            // If Claude is mid-write the last record may be incomplete.
            // Fall back to trimming up to the last complete newline and retrying.
            let text: String
            if let decoded = String(data: data, encoding: .utf8) {
                text = decoded
            } else if let lastNewline = data.lastIndex(of: UInt8(ascii: "\n")),
                      let decoded = String(data: Data(data[...lastNewline]), encoding: .utf8) {
                text = decoded
            } else if readSize < fileSize {
                readSize = min(readSize * 2, fileSize)
                continue
            } else {
                return false
            }

            let lines = text.components(separatedBy: .newlines).filter { !$0.isEmpty }

            // No complete lines in the window — grow and retry if possible.
            let hasCompleteLine = lines.contains { $0.hasPrefix("{") }
            if !hasCompleteLine, readSize < fileSize {
                readSize = min(readSize * 2, fileSize)
                continue
            }

            if lines.reversed().contains(where: { line in
                guard let lineData = line.data(using: .utf8),
                      let entry = try? decoder.decode(JSONLEntry.self, from: lineData),
                      let tsStr = entry.timestamp,
                      let date = DateParser.parse(tsStr),
                      date >= threshold else { return false }
                return entry.hasToolActivity
            }) {
                return true
            }

            // Later lines were complete but the newest omitted record was still truncated.
            // Keep expanding so a large recent tool_use/tool_result line is retried.
            if !startsAtRecordBoundary, readSize < fileSize {
                readSize = min(readSize * 2, fileSize)
                continue
            }

            return false
        }
    }

    private static func isJSONLRecordBoundary(handle: FileHandle, offset: UInt64) -> Bool {
        guard offset > 0 else { return true }

        try? handle.seek(toOffset: offset - 1)
        return handle.readData(ofLength: 1).first == UInt8(ascii: "\n")
    }

    // MARK: - SQLite helper

    private static func queryCount(db path: String, sql: String, param: Int64) -> Int {
        guard FileManager.default.fileExists(atPath: path) else { return 0 }

        var db: OpaquePointer?
        // sqlite3_close(NULL) is a no-op, so defer is safe even on open failure.
        // sqlite3_open may return a non-NULL handle even when it fails — always close it.
        defer { sqlite3_close(db) }
        guard sqlite3_open_v2(path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else { return 0 }
        sqlite3_busy_timeout(db, 1000)

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return 0 }
        defer { sqlite3_finalize(stmt) }

        sqlite3_bind_int64(stmt, 1, param)
        guard sqlite3_step(stmt) == SQLITE_ROW else { return 0 }
        return Int(sqlite3_column_int64(stmt, 0))
    }
}

private func queryExists(db path: String, sql: String, int64Param: Int64) -> Bool {
    guard FileManager.default.fileExists(atPath: path) else { return false }

    var db: OpaquePointer?
    defer { sqlite3_close(db) }
    guard sqlite3_open_v2(path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else { return false }
    sqlite3_busy_timeout(db, 1000)

    var statement: OpaquePointer?
    guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return false }
    defer { sqlite3_finalize(statement) }

    guard sqlite3_bind_int64(statement, 1, int64Param) == SQLITE_OK else { return false }
    return sqlite3_step(statement) == SQLITE_ROW
}

private func queryExists(db path: String, sql: String, textParam: String) -> Bool {
    guard FileManager.default.fileExists(atPath: path) else { return false }

    var db: OpaquePointer?
    defer { sqlite3_close(db) }
    guard sqlite3_open_v2(path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else { return false }
    sqlite3_busy_timeout(db, 1000)

    var statement: OpaquePointer?
    guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return false }
    defer { sqlite3_finalize(statement) }

    guard sqlite3_bind_text(statement, 1, textParam, -1, sqliteTransient) == SQLITE_OK else {
        return false
    }
    return sqlite3_step(statement) == SQLITE_ROW
}

// MARK: - Claude Code JSONL entry

private struct JSONLEntry: Decodable {
    let timestamp: String?
    let message: Message?

    struct Message: Decodable {
        let content: [ContentItem]?
    }

    struct ContentItem: Decodable {
        let type: String?
    }

    var hasToolActivity: Bool {
        guard let items = message?.content else { return false }
        return items.contains { $0.type == "tool_use" || $0.type == "tool_result" }
    }
}
