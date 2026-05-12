import Foundation
import SQLite3

/// Reads ~/.local/share/opencode/opencode.db (SQLite)
/// Queries assistant messages with token data
struct OpenCodeReader: TokenReader {
    let name = "OpenCode"

    private var dbPath: String {
        homeDir().appendingPathComponent(".local/share/opencode/opencode.db").path
    }

    func readUsage(from startDate: Date, to endDate: Date) async throws -> RawTokenUsage {
        guard let database = openDatabase() else {
            return RawTokenUsage()
        }
        defer { sqlite3_close(database) }

        guard let statement = preparedUsageStatement(in: database, from: startDate, to: endDate) else {
            return RawTokenUsage()
        }
        defer { sqlite3_finalize(statement) }

        return accumulateUsageRows(from: statement, clippingEndDate: endDate)
    }

    private func openDatabase() -> OpaquePointer? {
        guard FileManager.default.fileExists(atPath: dbPath) else { return nil }

        var database: OpaquePointer?
        guard sqlite3_open_v2(dbPath, &database, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
            sqlite3_close(database)
            return nil
        }

        sqlite3_busy_timeout(database, 2000)
        return database
    }

    private func preparedUsageStatement(
        in database: OpaquePointer,
        from startDate: Date,
        to endDate: Date) -> OpaquePointer? {
        let startEpoch = startDate.timeIntervalSince1970 * 1000
        let endEpoch = endDate.timeIntervalSince1970 * 1000
        let query = """
            SELECT
                session_id,
                time_created,
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

        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, query, -1, &statement, nil) == SQLITE_OK else {
            return nil
        }

        guard sqlite3_bind_int64(statement, 1, Int64(startEpoch)) == SQLITE_OK,
              sqlite3_bind_int64(statement, 2, Int64(endEpoch)) == SQLITE_OK else {
            sqlite3_finalize(statement)
            return nil
        }

        return statement
    }

    private func accumulateUsageRows(
        from statement: OpaquePointer,
        clippingEndDate: Date) -> RawTokenUsage {
        var result = RawTokenUsage()
        var activityEvents: [ActivityTimeEvent<String>] = []

        while sqlite3_step(statement) == SQLITE_ROW {
            let sessionID = sqlite3_column_text(statement, 0).map { String(cString: $0) } ?? ""
            let timestamp = sqlite3_column_int64(statement, 1)
            let input = Int(sqlite3_column_int64(statement, 2))
            let output = Int(sqlite3_column_int64(statement, 3))
            let cacheRead = Int(sqlite3_column_int64(statement, 4))
            let cacheWrite = Int(sqlite3_column_int64(statement, 5))
            let reasoning = Int(sqlite3_column_int64(statement, 6))
            let modelID = sqlite3_column_text(statement, 7).map { String(cString: $0) } ?? ""

            result.inputTokens += input
            result.outputTokens += output
            result.cacheReadTokens += cacheRead
            result.cacheWriteTokens += cacheWrite
            result.reasoningTokens += reasoning

            activityEvents.append(
                ActivityTimeEvent(
                    streamID: sessionID.isEmpty ? "opencode" : sessionID,
                    timestamp: Date(timeIntervalSince1970: TimeInterval(timestamp) / 1000),
                    key: normalizedModelID(modelID)))

            let normalizedModel = normalizedModelID(modelID)
            let messageCost: Double
            if let priceLookupKey = normalizedModel ?? (!modelID.isEmpty ? modelID : nil),
               let price = modelPrice(for: priceLookupKey) {
                messageCost = price.cost(
                    input: input,
                    output: output + reasoning,
                    cacheRead: cacheRead,
                    cacheWrite: cacheWrite)
                result.cost += messageCost
            } else {
                messageCost = 0
            }

            if let normalizedModelID = normalizedModel {
                let messageTokens = input + output + cacheRead + cacheWrite + reasoning
                result.perModel[normalizedModelID, default: PerModelUsage()].totalTokens += messageTokens
                result.perModel[normalizedModelID, default: PerModelUsage()].cost += messageCost
                result.perModel[normalizedModelID, default: PerModelUsage()].sources.insert(name)
            }

            result.recordTokenEvent(
                timestamp: Date(timeIntervalSince1970: TimeInterval(timestamp) / 1000),
                source: name,
                model: normalizedModel,
                inputTokens: input,
                outputTokens: output,
                cacheReadTokens: cacheRead,
                cacheWriteTokens: cacheWrite,
                reasoningTokens: reasoning,
                cost: messageCost)
        }

        result.mergeActivityEvents(activityEvents, source: name, clippingEndDate: clippingEndDate)

        return result
    }
}
