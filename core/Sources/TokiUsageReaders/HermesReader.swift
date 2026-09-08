import Foundation
import TokiUsageCore

#if os(Linux)
    import CSQLite
#else
    import SQLite3
#endif

// swiftlint:disable type_body_length
/// Reads ~/.hermes/state.db cumulative session usage through a durable delta ledger.
public struct HermesReader: TokenReader {
    public static let sourceName = "Hermes"

    public let name = Self.sourceName

    private let dbPathOverride: String?
    private let hermesHomeOverride: URL?
    private let includesProfiles: Bool
    private let usesLegacyDefaultLedger: Bool
    private let usageLedger: HermesUsageLedger
    private let profileLedgerStore: HermesProfileLedgerStore?
    private let now: @Sendable () -> Date

    public init(
        dbPathOverride: String? = nil,
        usageLedger: HermesUsageLedger = .shared,
        now: @escaping @Sendable () -> Date = { Date() }) {
        self.dbPathOverride = dbPathOverride
        hermesHomeOverride = nil
        includesProfiles = false
        usesLegacyDefaultLedger = true
        self.usageLedger = usageLedger
        profileLedgerStore = nil
        self.now = now
    }

    public init(
        hermesHomeURL: URL,
        includesProfiles: Bool,
        usesLegacyDefaultLedger: Bool,
        usageLedger: HermesUsageLedger,
        profileLedgerDirectory: URL,
        now: @escaping @Sendable () -> Date = { Date() }) {
        dbPathOverride = nil
        hermesHomeOverride = hermesHomeURL.standardizedFileURL
        self.includesProfiles = includesProfiles
        self.usesLegacyDefaultLedger = usesLegacyDefaultLedger
        self.usageLedger = usageLedger
        profileLedgerStore = HermesProfileLedgerStore(
            defaultLedger: usageLedger,
            includesDefaultLedger: usesLegacyDefaultLedger,
            directory: profileLedgerDirectory.standardizedFileURL,
            hermesHome: hermesHomeURL,
            includesProfiles: includesProfiles)
        self.now = now
    }

    private var dbPath: String {
        dbPathOverride ?? homeDir().appendingPathComponent(".hermes/state.db").path
    }

    public func readUsage(from startDate: Date, to endDate: Date) async throws -> RawTokenUsage {
        try Task.checkCancellation()
        if let profileLedgerStore {
            return try await readProfileUsage(
                profileLedgerStore: profileLedgerStore,
                from: startDate,
                to: endDate)
        }
        let modelPricingTimestamp = now()
        if let observations = try readDatabaseSnapshot(atPath: dbPath, { database in
            try readSessionObservations(
                from: database,
                modelPricingTimestamp: modelPricingTimestamp)
        }) {
            let observedAt = max(modelPricingTimestamp, now())
            try await usageLedger.refresh(
                observations: observations,
                observedAt: observedAt)
        }

        let events = try await usageLedger.events(from: startDate, to: endDate)
        return accumulate(events: events, clippingEndDate: endDate)
    }

    public func coverageStatus() throws -> HermesUsageCoverageStatus {
        let modelPricingTimestamp = now()
        let sources = try databaseSources()
        var total = 0
        var successfulSourceCount = 0
        var failures: [Error] = []
        for source in sources {
            try Task.checkCancellation()
            do {
                guard let coverage = try readDatabaseSnapshot(atPath: source.databaseURL.path, { database in
                    // A valid SQLite file without the Hermes session schema is not empty coverage.
                    let statement = try preparedUsageStatement(in: database)
                    defer { sqlite3_finalize(statement) }
                    return try readSessionModelUsage(
                        from: database,
                        modelPricingTimestamp: modelPricingTimestamp).coverage
                }) else { continue }
                total = saturatedTokenSum(total, coverage.unmeteredMainAPICallCount)
                successfulSourceCount += 1
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                failures.append(error)
            }
        }
        if successfulSourceCount == 0, let failure = failures.first { throw failure }
        return HermesUsageCoverageStatus(
            unmeteredMainAPICallCount: total,
            profileReadErrorCount: failures.count)
    }

    public func collectionHistoryStatus() async throws -> HermesCollectionHistoryStatus {
        if let profileLedgerStore {
            let collection = try profileLedgerStore.discoverCollection()
            return try await profileLedgerStore.historyStatus(collection: collection)
        }
        let status = try await usageLedger.status()
        return HermesCollectionHistoryStatus(profiles: [.init(isDefault: true, status: status)])
    }

    private func databaseSources() throws -> [HermesDatabaseSource] {
        guard let hermesHomeOverride else {
            return [HermesDatabaseSource(
                databaseURL: URL(fileURLWithPath: dbPath),
                isDefault: true,
                ledgerIdentifier: "")]
        }
        let sources = try discoverHermesDatabaseSources(
            hermesHome: hermesHomeOverride,
            includesProfiles: includesProfiles)
        guard !usesLegacyDefaultLedger else { return sources }
        return sources.map {
            HermesDatabaseSource(
                databaseURL: $0.databaseURL,
                isDefault: false,
                ledgerIdentifier: $0.ledgerIdentifier)
        }
    }

    private func readProfileUsage(
        profileLedgerStore: HermesProfileLedgerStore,
        from startDate: Date,
        to endDate: Date) async throws -> RawTokenUsage {
        let collection = try profileLedgerStore.discoverCollection()
        let sources = collection.sources
        let ledgers = try await profileLedgerStore.selectedLedgers(collection: collection)
        let modelPricingTimestamp = now()
        var successfulSourceCount = 0
        var failures: [String: Error] = [:]

        for source in sources {
            try Task.checkCancellation()
            do {
                guard let observations = try readDatabaseSnapshot(
                    atPath: source.databaseURL.path,
                    { database in
                        try readSessionObservations(
                            from: database,
                            modelPricingTimestamp: modelPricingTimestamp)
                    }) else { continue }
                let observedAt = max(modelPricingTimestamp, now())
                let ledger = await profileLedgerStore.ledger(for: source)
                try await ledger.refresh(observations: observations, observedAt: observedAt)
                successfulSourceCount += 1
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                failures[source.isDefault ? "default" : source.ledgerIdentifier] = error
            }
        }

        var events: [HermesUsageLedgerEvent] = []
        for ledger in ledgers {
            try Task.checkCancellation()
            do {
                try await events.append(contentsOf: ledger.events(from: startDate, to: endDate))
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                failures[ledger.failureIdentifier] = error
            }
        }
        if successfulSourceCount == 0, events.isEmpty,
           let identifier = failures.keys.sorted().first, let failure = failures[identifier] {
            throw failure
        }

        try Task.checkCancellation()
        var result = accumulate(events: events, clippingEndDate: endDate)
        if !failures.isEmpty {
            result.supplemental.append(SupplementalUsage(
                id: "hermes-profile-read-errors",
                label: "Hermes profile read errors",
                value: failures.count,
                unit: .count,
                source: name,
                model: nil,
                includedInTotals: false,
                quality: .exact))
        }
        return result
    }

    private func readDatabaseSnapshot<Value>(
        atPath path: String,
        _ read: (OpaquePointer) throws -> Value) throws -> Value? {
        for attempt in 0..<2 {
            try Task.checkCancellation()
            guard let connection = try HermesSQLiteConnection.open(atPath: path) else {
                return nil
            }
            let value = try read(connection.database)
            if connection.isSourceStateCurrent {
                return value
            }
            guard attempt == 0 else {
                throw HermesSQLiteError(
                    operation: "read snapshot",
                    message: "database changed during read",
                    code: SQLITE_BUSY)
            }
        }
        return nil
    }

    private func readSessionObservations(
        from database: OpaquePointer,
        modelPricingTimestamp: Date) throws -> [HermesSessionObservation] {
        guard sqlite3_exec(database, "BEGIN DEFERRED TRANSACTION", nil, nil, nil) == SQLITE_OK else {
            throw HermesSQLiteError(operation: "begin read transaction", database: database)
        }
        do {
            let observations = try readSessionObservationsInSnapshot(
                from: database,
                modelPricingTimestamp: modelPricingTimestamp)
            guard sqlite3_exec(database, "COMMIT", nil, nil, nil) == SQLITE_OK else {
                throw HermesSQLiteError(operation: "commit read transaction", database: database)
            }
            return observations
        } catch {
            sqlite3_exec(database, "ROLLBACK", nil, nil, nil)
            throw error
        }
    }

    private func readSessionObservationsInSnapshot(
        from database: OpaquePointer,
        modelPricingTimestamp: Date) throws -> [HermesSessionObservation] {
        let modelUsageBySessionID = try readSessionModelUsage(
            from: database,
            modelPricingTimestamp: modelPricingTimestamp).usageBySessionID
        let statement = try preparedUsageStatement(in: database)
        defer { sqlite3_finalize(statement) }

        var observations: [HermesSessionObservation] = []
        var stepStatus = sqlite3_step(statement)
        while stepStatus == SQLITE_ROW {
            try Task.checkCancellation()
            let session = HermesSessionUsageRow(statement: statement).observation
            let observation = try HermesUsageResolver.resolve(
                session: session,
                modelUsage: modelUsageBySessionID[session.sessionID] ?? [])
            observations.append(observation)
            stepStatus = sqlite3_step(statement)
        }
        guard stepStatus == SQLITE_DONE else {
            throw HermesSQLiteError(operation: "query", database: database)
        }
        return observations
    }

    private func preparedUsageStatement(in database: OpaquePointer) throws -> OpaquePointer {
        let hasMessages = try table(
            "messages",
            hasColumns: ["session_id", "timestamp"],
            in: database)
        let activityJoin = hasMessages
            ? """
            LEFT JOIN (
                SELECT
                    session_id,
                    MIN(timestamp) AS earliest_activity_at,
                    MAX(timestamp) AS latest_activity_at
                FROM messages
                GROUP BY session_id
            ) AS recent_activity ON recent_activity.session_id = sessions.id
            """
            : ""
        let earliestActivityColumn = hasMessages ? "recent_activity.earliest_activity_at" : "NULL"
        let latestActivityColumn = hasMessages ? "recent_activity.latest_activity_at" : "NULL"
        let query = """
            SELECT
                sessions.id,
                sessions.started_at,
                COALESCE(sessions.model, ''),
                COALESCE(sessions.cwd, ''),
                COALESCE(sessions.git_repo_root, ''),
                COALESCE(sessions.input_tokens, 0),
                COALESCE(sessions.output_tokens, 0),
                COALESCE(sessions.cache_read_tokens, 0),
                COALESCE(sessions.cache_write_tokens, 0),
                COALESCE(sessions.reasoning_tokens, 0),
                COALESCE(sessions.estimated_cost_usd, 0),
                COALESCE(sessions.actual_cost_usd, 0),
                \(earliestActivityColumn),
                \(latestActivityColumn)
            FROM sessions
            \(activityJoin)
            ORDER BY sessions.started_at ASC, sessions.id ASC
        """
        return try prepareStatement(query, in: database)
    }

    // swiftlint:disable:next function_body_length
    private func readSessionModelUsage(
        from database: OpaquePointer,
        modelPricingTimestamp: Date) throws -> HermesSessionModelUsageReadResult {
        guard try tableExists("session_model_usage", in: database) else { return .empty }
        let requiredColumns: Set = [
            "session_id",
            "model",
            "task",
            "api_call_count",
            "input_tokens",
            "output_tokens",
            "cache_read_tokens",
            "cache_write_tokens",
            "reasoning_tokens",
            "estimated_cost_usd",
            "actual_cost_usd",
        ]
        guard try table("session_model_usage", hasColumns: requiredColumns, in: database) else {
            // Older Hermes schemas still expose supported session totals.
            return .empty
        }

        let statement = try prepareStatement(
            """
            SELECT
                session_id,
                COALESCE(model, ''),
                COALESCE(task, ''),
                COALESCE(api_call_count, 0),
                COALESCE(input_tokens, 0),
                COALESCE(output_tokens, 0),
                COALESCE(cache_read_tokens, 0),
                COALESCE(cache_write_tokens, 0),
                COALESCE(reasoning_tokens, 0),
                COALESCE(estimated_cost_usd, 0),
                COALESCE(actual_cost_usd, 0)
            FROM session_model_usage
            ORDER BY session_id ASC, model ASC, task ASC
            """,
            in: database)
        defer { sqlite3_finalize(statement) }

        var usageBySessionID: [String: [HermesSessionModelUsage]] = [:]
        var unmeteredMainAPICallCount = 0
        var stepStatus = sqlite3_step(statement)
        while stepStatus == SQLITE_ROW {
            try Task.checkCancellation()
            let sessionID = hermesSQLiteText(statement, at: 0)
            let model = normalizedModelID(hermesSQLiteText(statement, at: 1))
            let task = hermesSQLiteText(statement, at: 2)
            let apiCallCount = max(0, Int(sqlite3_column_int64(statement, 3)))
            let counters = HermesTokenCounters(
                inputTokens: max(0, Int(sqlite3_column_int64(statement, 4))),
                outputTokens: max(0, Int(sqlite3_column_int64(statement, 5))),
                cacheReadTokens: max(0, Int(sqlite3_column_int64(statement, 6))),
                cacheWriteTokens: max(0, Int(sqlite3_column_int64(statement, 7))),
                reasoningTokens: max(0, Int(sqlite3_column_int64(statement, 8))))
            guard counters.isValid() else {
                throw HermesUsageLedgerError.invalidObservation
            }
            // session_model_usage rows carry no event time; fall back to
            // read-time pricing for the rare rows without a reported cost.
            let resolvedCost = hermesUsageCost(
                model: model,
                counters: counters,
                estimatedCost: max(0, sqlite3_column_double(statement, 9)),
                actualCost: max(0, sqlite3_column_double(statement, 10)),
                timestamp: modelPricingTimestamp)
            usageBySessionID[sessionID, default: []].append(
                HermesSessionModelUsage(
                    model: model,
                    counters: counters,
                    cost: resolvedCost.value,
                    costIsDerivedFromModelPricing: resolvedCost.isDerivedFromModelPricing,
                    modelPricingTimestamp: resolvedCost.modelPricingTimestamp))
            let hasReportedTokens = counters.inputTokens > 0
                || counters.outputTokens > 0
                || counters.cacheReadTokens > 0
                || counters.cacheWriteTokens > 0
                || counters.reasoningTokens > 0
            if task.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
               !hasReportedTokens {
                unmeteredMainAPICallCount = saturatedTokenSum(
                    unmeteredMainAPICallCount,
                    apiCallCount)
            }
            stepStatus = sqlite3_step(statement)
        }
        guard stepStatus == SQLITE_DONE else {
            throw HermesSQLiteError(operation: "query", database: database)
        }
        return HermesSessionModelUsageReadResult(
            usageBySessionID: usageBySessionID,
            coverage: HermesUsageCoverageStatus(
                unmeteredMainAPICallCount: unmeteredMainAPICallCount))
    }

    private func table(
        _ tableName: String,
        hasColumns requiredColumns: Set<String>,
        in database: OpaquePointer) throws -> Bool {
        let statement = try prepareStatement(
            "SELECT name FROM pragma_table_info(?)",
            in: database)
        defer { sqlite3_finalize(statement) }
        guard sqlite3_bind_text(statement, 1, tableName, -1, hermesSQLiteTransient) == SQLITE_OK else {
            throw HermesSQLiteError(operation: "bind", database: database)
        }

        var columns: Set<String> = []
        var stepStatus = sqlite3_step(statement)
        while stepStatus == SQLITE_ROW {
            columns.insert(hermesSQLiteText(statement, at: 0))
            stepStatus = sqlite3_step(statement)
        }
        guard stepStatus == SQLITE_DONE else {
            throw HermesSQLiteError(operation: "query", database: database)
        }
        return requiredColumns.isSubset(of: columns)
    }

    private func tableExists(_ tableName: String, in database: OpaquePointer) throws -> Bool {
        let statement = try prepareStatement(
            "SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = ? LIMIT 1",
            in: database)
        defer { sqlite3_finalize(statement) }
        guard sqlite3_bind_text(statement, 1, tableName, -1, hermesSQLiteTransient) == SQLITE_OK else {
            throw HermesSQLiteError(operation: "bind", database: database)
        }
        let status = sqlite3_step(statement)
        guard status == SQLITE_ROW || status == SQLITE_DONE else {
            throw HermesSQLiteError(operation: "query", database: database)
        }
        return status == SQLITE_ROW
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

    private func accumulate(
        events: [HermesUsageLedgerEvent],
        clippingEndDate: Date) -> RawTokenUsage {
        var result = RawTokenUsage()

        for event in events {
            let counters = event.counters
            result.inputTokens += counters.inputTokens
            result.outputTokens += counters.outputTokens
            result.cacheReadTokens += counters.cacheReadTokens
            result.cacheWriteTokens += counters.cacheWriteTokens
            result.reasoningTokens += counters.reasoningTokens
            result.cost += event.cost

            result.accumulatePerModelUsage(
                model: event.model,
                source: name,
                totalTokens: counters.totalTokens,
                cost: event.cost)

            result.recordTokenEvent(
                timestamp: event.timestamp,
                source: name,
                model: event.model,
                inputTokens: counters.inputTokens,
                outputTokens: counters.outputTokens,
                cacheReadTokens: counters.cacheReadTokens,
                cacheWriteTokens: counters.cacheWriteTokens,
                reasoningTokens: counters.reasoningTokens,
                cost: event.cost,
                attribution: UsageAttribution(
                    projectName: event.projectName,
                    sessionID: event.sessionIdentifier,
                    quality: event.attributionQuality))
        }

        let activityEvents = Self.activityEvents(from: events)
        result.mergeActivityEvents(activityEvents, source: name, clippingEndDate: clippingEndDate)
        return result
    }

    private static func activityEvents(
        from events: [HermesUsageLedgerEvent]) -> [ActivityTimeEvent<String>] {
        Dictionary(grouping: events.filter { $0.counters.totalTokens > 0 }) { event in
            HermesActivityEventIdentity(
                streamID: event.sessionIdentifier,
                timestamp: event.timestamp)
        }
        .map { identity, groupedEvents in
            let models = Set(groupedEvents.map(\.model))
            let model = models.count == 1
                ? models.first ?? nil
                : UsageModelGrouping.mixedOrUnattributedKey
            return ActivityTimeEvent(
                streamID: identity.streamID,
                timestamp: identity.timestamp,
                key: UsageModelGrouping.groupingKey(for: model))
        }
        .sorted { lhs, rhs in
            if lhs.timestamp != rhs.timestamp { return lhs.timestamp < rhs.timestamp }
            if lhs.streamID != rhs.streamID { return lhs.streamID < rhs.streamID }
            return (lhs.key ?? "") < (rhs.key ?? "")
        }
    }
}

// swiftlint:enable type_body_length

private struct HermesSessionModelUsageReadResult {
    static let empty = HermesSessionModelUsageReadResult(
        usageBySessionID: [:],
        coverage: HermesUsageCoverageStatus(unmeteredMainAPICallCount: 0))

    let usageBySessionID: [String: [HermesSessionModelUsage]]
    let coverage: HermesUsageCoverageStatus
}

private struct HermesActivityEventIdentity: Hashable {
    let streamID: String
    let timestamp: Date
}

private let hermesSQLiteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
