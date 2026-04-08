import Foundation
import SQLite3

// Reads ~/.codex/state_5.sqlite
// Queries threads table for today's token usage
struct CodexReader: TokenReader {
    let name = "Codex"

    private var dbPath: String {
        homeDir().appendingPathComponent(".codex/state_5.sqlite").path
    }

    func readUsage(from startDate: Date, to endDate: Date) async throws -> RawTokenUsage {
        guard FileManager.default.fileExists(atPath: dbPath) else {
            return RawTokenUsage()
        }

        var db: OpaquePointer?
        guard sqlite3_open(dbPath, &db) == SQLITE_OK else {
            return RawTokenUsage()
        }
        defer { sqlite3_close(db) }
        sqlite3_busy_timeout(db, 2000)

        let todayEpoch = startDate.timeIntervalSince1970
        let endEpoch   = endDate.timeIntervalSince1970
        let query = """
            SELECT COALESCE(SUM(tokens_used), 0), COUNT(*)
            FROM threads
            WHERE created_at >= ? AND created_at < ? AND tokens_used > 0
        """

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, query, -1, &stmt, nil) == SQLITE_OK else {
            return RawTokenUsage()
        }
        defer { sqlite3_finalize(stmt) }

        sqlite3_bind_int64(stmt, 1, Int64(todayEpoch))
        sqlite3_bind_int64(stmt, 2, Int64(endEpoch))

        guard sqlite3_step(stmt) == SQLITE_ROW else {
            return RawTokenUsage()
        }

        let totalTokens = Int(sqlite3_column_int64(stmt, 0))
        let messageCount = Int(sqlite3_column_int64(stmt, 1))

        var result = RawTokenUsage(inputTokens: totalTokens)
        // tokens_used is total combined — no per-model breakdown from SQLite, cost skipped
        result.perModel["gpt-5.4", default: PerModelUsage()].totalTokens += totalTokens
        return result
    }
}
