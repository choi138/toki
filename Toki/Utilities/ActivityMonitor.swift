import Foundation
import SQLite3

// Detects whether any AI coding tool is currently active.
enum ActivityMonitor {

    private static let activeWindowSeconds: TimeInterval = 30

    static func isAnyToolActive() -> Bool {
        let threshold = Date().addingTimeInterval(-activeWindowSeconds)
        // Cheap DB queries first; expensive directory scan last
        return isCodexActive(since: threshold)
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
                  options: [.skipsHiddenFiles]
              ) else { return false }

        for case let url as URL in enumerator {
            guard url.pathExtension == "jsonl",
                  let mod = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate,
                  mod >= threshold
            else { continue }

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
        return queryCount(
            db: dbPath,
            sql: "SELECT COUNT(*) FROM threads WHERE updated_at >= ?",
            param: epoch
        ) > 0
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
            param: epochMs
        ) > 0
    }

    // MARK: - JSONL tool use detection

    private static func hasRecentToolUse(in url: URL, since threshold: Date) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? handle.close() }

        let fileSize = (try? handle.seekToEnd()) ?? 0
        guard fileSize > 0 else { return false }

        let decoder = JSONDecoder()

        // Start at 256 KB; double until recent records are complete or we reach the file start.
        var readSize = UInt64(min(262144, fileSize))
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
                      date >= threshold
                else { return false }
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
