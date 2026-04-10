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
        guard sqlite3_open(dbPath, &db) == SQLITE_OK else {
            return RawTokenUsage()
        }
        defer { sqlite3_close(db) }
        sqlite3_busy_timeout(db, 2000)

        let todayEpoch = startDate.timeIntervalSince1970 * 1000
        let endEpoch   = endDate.timeIntervalSince1970 * 1000
        let query = """
            SELECT data FROM message
            WHERE json_extract(data, '$.role') = 'assistant'
            AND json_extract(data, '$.tokens') IS NOT NULL
        """

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, query, -1, &stmt, nil) == SQLITE_OK else {
            return RawTokenUsage()
        }
        defer { sqlite3_finalize(stmt) }

        var result = RawTokenUsage()
        let decoder = JSONDecoder()

        while sqlite3_step(stmt) == SQLITE_ROW {
            guard let cStr = sqlite3_column_text(stmt, 0) else { continue }
            let jsonStr = String(cString: cStr)
            guard let data = jsonStr.data(using: .utf8),
                  let msg = try? decoder.decode(OpenCodeMessage.self, from: data) else { continue }

            let createdAt = msg.time?.created ?? 0
            guard createdAt >= todayEpoch && createdAt < endEpoch else { continue }

            let input     = msg.tokens?.input ?? 0
            let output    = msg.tokens?.output ?? 0
            let cacheRead = msg.tokens?.cache?.read ?? 0
            let cacheWrite = msg.tokens?.cache?.write ?? 0
            let reasoning = msg.tokens?.reasoning ?? 0

            result.inputTokens     += input
            result.outputTokens    += output
            result.cacheReadTokens += cacheRead
            result.cacheWriteTokens += cacheWrite
            result.reasoningTokens += reasoning

            let msgCost: Double
            if let price = modelPrice(for: msg.modelID ?? "") {
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

            if let modelID = msg.modelID, !modelID.isEmpty {
                let msgTokens = input + output + cacheRead + cacheWrite + reasoning
                result.perModel[modelID, default: PerModelUsage()].totalTokens += msgTokens
                result.perModel[modelID, default: PerModelUsage()].cost += msgCost
                result.perModel[modelID, default: PerModelUsage()].sources.insert(name)
            }
        }

        return result
    }
}

// MARK: - Private Types

private struct OpenCodeMessage: Decodable {
    let tokens: Tokens?
    let time: MessageTime?
    let modelID: String?

    struct Tokens: Decodable {
        let input: Int?
        let output: Int?
        let reasoning: Int?
        let cache: Cache?

        struct Cache: Decodable {
            let read: Int?
            let write: Int?
        }
    }

    struct MessageTime: Decodable {
        let created: Double?
    }
}
