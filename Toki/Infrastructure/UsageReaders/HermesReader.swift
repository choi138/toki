import Foundation
import SQLite3

/// Reads ~/.hermes/state.db session usage totals.
struct HermesReader: TokenReader {
    static let sourceName = "Hermes"

    let name = Self.sourceName

    private static let totalTokensExpression = """
        COALESCE(input_tokens, 0)
        + COALESCE(output_tokens, 0)
        + COALESCE(cache_read_tokens, 0)
        + COALESCE(cache_write_tokens, 0)
        + COALESCE(reasoning_tokens, 0)
    """

    private let dbPathOverride: String?

    init(dbPathOverride: String? = nil) {
        self.dbPathOverride = dbPathOverride
    }

    private var dbPath: String {
        dbPathOverride ?? homeDir().appendingPathComponent(".hermes/state.db").path
    }

    func readUsage(from startDate: Date, to endDate: Date) async throws -> RawTokenUsage {
        guard let database = try openDatabase() else {
            return RawTokenUsage()
        }
        defer { sqlite3_close(database) }

        let statement = try preparedUsageStatement(in: database, from: startDate, to: endDate)
        defer { sqlite3_finalize(statement) }

        return try accumulateUsageRows(from: statement, clippingEndDate: endDate)
    }

    func readTotalTokens(from startDate: Date, to endDate: Date) async throws -> Int {
        try readSummedInteger(
            expression: Self.totalTokensExpression,
            from: startDate,
            to: endDate)
    }

    func readOutputTokens(from startDate: Date, to endDate: Date) async throws -> Int {
        try readSummedInteger(
            expression: "COALESCE(output_tokens, 0)",
            from: startDate,
            to: endDate)
    }

    private func openDatabase() throws -> OpaquePointer? {
        guard FileManager.default.fileExists(atPath: dbPath) else { return nil }

        var database: OpaquePointer?
        guard sqlite3_open_v2(dbPath, &database, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
            let error = HermesSQLiteError(operation: "open", database: database)
            sqlite3_close(database)
            throw error
        }

        sqlite3_busy_timeout(database, 2000)
        return database
    }

    private func preparedUsageStatement(
        in database: OpaquePointer,
        from startDate: Date,
        to endDate: Date) throws -> OpaquePointer {
        let query = """
            SELECT
                id,
                started_at,
                COALESCE(model, ''),
                COALESCE(cwd, ''),
                COALESCE(git_repo_root, ''),
                COALESCE(input_tokens, 0),
                COALESCE(output_tokens, 0),
                COALESCE(cache_read_tokens, 0),
                COALESCE(cache_write_tokens, 0),
                COALESCE(reasoning_tokens, 0),
                COALESCE(estimated_cost_usd, 0),
                COALESCE(actual_cost_usd, 0)
            FROM sessions
            WHERE started_at >= ?
            AND started_at < ?
            AND \(Self.totalTokensExpression) > 0
            ORDER BY started_at ASC, id ASC
        """

        let statement = try prepareStatement(query, in: database)
        try bindDateRange(statement, database: database, from: startDate, to: endDate)
        return statement
    }

    private func readSummedInteger(
        expression: String,
        from startDate: Date,
        to endDate: Date) throws -> Int {
        guard let database = try openDatabase() else { return 0 }
        defer { sqlite3_close(database) }

        let query = """
            SELECT COALESCE(SUM(\(expression)), 0)
            FROM sessions
            WHERE started_at >= ?
            AND started_at < ?
            AND \(Self.totalTokensExpression) > 0
        """

        let statement = try prepareStatement(query, in: database)
        defer { sqlite3_finalize(statement) }
        try bindDateRange(statement, database: database, from: startDate, to: endDate)

        let stepStatus = sqlite3_step(statement)
        guard stepStatus == SQLITE_ROW else {
            throw HermesSQLiteError(operation: "query", database: database)
        }

        return Int(sqlite3_column_int64(statement, 0))
    }

    private func prepareStatement(_ query: String, in database: OpaquePointer) throws -> OpaquePointer {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, query, -1, &statement, nil) == SQLITE_OK else {
            throw HermesSQLiteError(operation: "prepare", database: database)
        }
        guard let statement else {
            throw HermesSQLiteError(operation: "prepare", database: database)
        }
        return statement
    }

    private func bindDateRange(
        _ statement: OpaquePointer,
        database: OpaquePointer,
        from startDate: Date,
        to endDate: Date) throws {
        guard sqlite3_bind_double(statement, 1, startDate.timeIntervalSince1970) == SQLITE_OK,
              sqlite3_bind_double(statement, 2, endDate.timeIntervalSince1970) == SQLITE_OK else {
            throw HermesSQLiteError(operation: "bind", database: database)
        }
    }

    private func accumulateUsageRows(
        from statement: OpaquePointer,
        clippingEndDate: Date) throws -> RawTokenUsage {
        var result = RawTokenUsage()
        var activityEvents: [ActivityTimeEvent<String>] = []

        var stepStatus = sqlite3_step(statement)
        while stepStatus == SQLITE_ROW {
            let row = HermesSessionUsageRow(statement: statement)
            result.inputTokens += row.inputTokens
            result.outputTokens += row.outputTokens
            result.cacheReadTokens += row.cacheReadTokens
            result.cacheWriteTokens += row.cacheWriteTokens
            result.reasoningTokens += row.reasoningTokens
            result.cost += row.cost

            if let model = row.model {
                result.perModel[model, default: PerModelUsage()].totalTokens += row.totalTokens
                result.perModel[model, default: PerModelUsage()].cost += row.cost
                result.perModel[model, default: PerModelUsage()].sources.insert(name)
            }

            activityEvents.append(
                ActivityTimeEvent(
                    streamID: row.sessionID,
                    timestamp: row.startedAt,
                    key: row.model))

            result.recordTokenEvent(
                timestamp: row.startedAt,
                source: name,
                model: row.model,
                inputTokens: row.inputTokens,
                outputTokens: row.outputTokens,
                cacheReadTokens: row.cacheReadTokens,
                cacheWriteTokens: row.cacheWriteTokens,
                reasoningTokens: row.reasoningTokens,
                cost: row.cost,
                attribution: row.attribution)

            stepStatus = sqlite3_step(statement)
        }

        guard stepStatus == SQLITE_DONE else {
            throw HermesSQLiteError(operation: "query", database: sqlite3_db_handle(statement))
        }

        result.mergeActivityEvents(activityEvents, source: name, clippingEndDate: clippingEndDate)
        return result
    }
}

private struct HermesSessionUsageRow {
    let sessionID: String
    let startedAt: Date
    let model: String?
    let inputTokens: Int
    let outputTokens: Int
    let cacheReadTokens: Int
    let cacheWriteTokens: Int
    let reasoningTokens: Int
    let cost: Double
    let attribution: UsageAttribution

    init(statement: OpaquePointer) {
        sessionID = hermesSQLiteText(statement, at: 0).nilIfBlank ?? "hermes"
        startedAt = Date(timeIntervalSince1970: sqlite3_column_double(statement, 1))
        model = normalizedModelID(hermesSQLiteText(statement, at: 2))
        let cwd = hermesSQLiteText(statement, at: 3).nilIfBlank
        let gitRepoRoot = hermesSQLiteText(statement, at: 4).nilIfBlank
        inputTokens = max(0, Int(sqlite3_column_int64(statement, 5)))
        outputTokens = max(0, Int(sqlite3_column_int64(statement, 6)))
        cacheReadTokens = max(0, Int(sqlite3_column_int64(statement, 7)))
        cacheWriteTokens = max(0, Int(sqlite3_column_int64(statement, 8)))
        reasoningTokens = max(0, Int(sqlite3_column_int64(statement, 9)))

        let estimatedCost = max(0, sqlite3_column_double(statement, 10))
        let actualCost = max(0, sqlite3_column_double(statement, 11))
        cost = Self.cost(
            model: model,
            inputTokens: inputTokens,
            outputTokens: outputTokens,
            cacheReadTokens: cacheReadTokens,
            cacheWriteTokens: cacheWriteTokens,
            reasoningTokens: reasoningTokens,
            estimatedCost: estimatedCost,
            actualCost: actualCost)

        attribution = UsageAttribution(
            projectPath: cwd ?? gitRepoRoot,
            sessionID: sessionID,
            quality: cwd == nil && gitRepoRoot != nil ? .inferred : .exact)
    }

    var totalTokens: Int {
        inputTokens + outputTokens + cacheReadTokens + cacheWriteTokens + reasoningTokens
    }

    private static func cost(
        model: String?,
        inputTokens: Int,
        outputTokens: Int,
        cacheReadTokens: Int,
        cacheWriteTokens: Int,
        reasoningTokens: Int,
        estimatedCost: Double,
        actualCost: Double) -> Double {
        if actualCost > 0 { return actualCost }
        if estimatedCost > 0 { return estimatedCost }

        guard let model, let price = modelPrice(for: model) else { return 0 }
        return price.cost(
            input: inputTokens,
            output: outputTokens + reasoningTokens,
            cacheRead: cacheReadTokens,
            cacheWrite: cacheWriteTokens)
    }
}

private struct HermesSQLiteError: LocalizedError {
    let operation: String
    let message: String

    init(operation: String, database: OpaquePointer?) {
        self.operation = operation
        if let database, let errorMessage = sqlite3_errmsg(database) {
            message = String(cString: errorMessage)
        } else {
            message = "unknown SQLite error"
        }
    }

    var errorDescription: String? {
        "Hermes SQLite \(operation) failed: \(message)"
    }
}

private func hermesSQLiteText(_ statement: OpaquePointer?, at index: Int32) -> String {
    sqlite3_column_text(statement, index).map { String(cString: $0) } ?? ""
}

private extension String {
    var nilIfBlank: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
