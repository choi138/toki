import Foundation
import SQLite3

// Reads ~/.local/share/opencode/opencode.db (SQLite)
// Queries assistant messages with token data
struct OpenCodeReader: TokenReader {
    let name = "OpenCode"

    private var dbPath: String {
        homeDir().appendingPathComponent(".local/share/opencode/opencode.db").path
    }

    func readUsage(from startDate: Date, to endDate: Date) async throws -> RawTokenUsage {
        guard FileManager.default.fileExists(atPath: dbPath) else {
            return RawTokenUsage()
        }

        var db: OpaquePointer?
        defer { sqlite3_close(db) }
        guard sqlite3_open_v2(dbPath, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
            return RawTokenUsage()
        }
        sqlite3_busy_timeout(db, 2000)

        let startEpoch = startDate.timeIntervalSince1970 * 1000
        let endEpoch   = endDate.timeIntervalSince1970 * 1000
        let query = """
            SELECT
                COALESCE(CAST(json_extract(data, '$.tokens.input') AS INTEGER), 0),
                COALESCE(CAST(json_extract(data, '$.tokens.output') AS INTEGER), 0),
                COALESCE(CAST(json_extract(data, '$.tokens.cache.read') AS INTEGER), 0),
                COALESCE(CAST(json_extract(data, '$.tokens.cache.write') AS INTEGER), 0),
                COALESCE(CAST(json_extract(data, '$.tokens.reasoning') AS INTEGER), 0),
                COALESCE(json_extract(data, '$.modelID'), '')
            FROM message
            WHERE json_extract(data, '$.role') = 'assistant'
            AND json_extract(data, '$.tokens') IS NOT NULL
            AND time_created >= ?
            AND time_created < ?
        """

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, query, -1, &stmt, nil) == SQLITE_OK else {
            return RawTokenUsage()
        }
        defer { sqlite3_finalize(stmt) }

        guard sqlite3_bind_int64(stmt, 1, Int64(startEpoch)) == SQLITE_OK,
              sqlite3_bind_int64(stmt, 2, Int64(endEpoch)) == SQLITE_OK else {
            return RawTokenUsage()
        }

        var result = RawTokenUsage()

        while sqlite3_step(stmt) == SQLITE_ROW {
            let input = Int(sqlite3_column_int64(stmt, 0))
            let output = Int(sqlite3_column_int64(stmt, 1))
            let cacheRead = Int(sqlite3_column_int64(stmt, 2))
            let cacheWrite = Int(sqlite3_column_int64(stmt, 3))
            let reasoning = Int(sqlite3_column_int64(stmt, 4))
            let modelID = sqlite3_column_text(stmt, 5).map { String(cString: $0) } ?? ""

            result.inputTokens     += input
            result.outputTokens    += output
            result.cacheReadTokens += cacheRead
            result.cacheWriteTokens += cacheWrite
            result.reasoningTokens += reasoning

            let msgCost: Double
            if let price = modelPrice(for: modelID) {
                msgCost = price.cost(
                    input: input,
                    output: output,
                    cacheRead: cacheRead,
                    cacheWrite: cacheWrite
                )
                result.cost += msgCost
            } else {
                msgCost = 0
            }

            if !modelID.isEmpty {
                let msgTokens = input + output + cacheRead + cacheWrite + reasoning
                result.perModel[modelID, default: PerModelUsage()].totalTokens += msgTokens
                result.perModel[modelID, default: PerModelUsage()].cost += msgCost
                result.perModel[modelID, default: PerModelUsage()].sources.insert(name)
            }
        }

        return result
    }
}
