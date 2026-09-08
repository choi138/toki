import Foundation

#if os(Linux)
    import CSQLite
#else
    import SQLite3
#endif

/// Actual schema/projection: upstream sessions/openclaw.rs at the pin in LANE_REPORT.md.
enum OpenClawSQLiteReader {
    static func read(
        source: OpenClawSource,
        budget: OpenClawReadBudget,
        _ consume: (OpenClawUsageEvent) -> Void) throws {
        try Task.checkCancellation()
        let snapshot = try OpenClawDatabaseSnapshot(source: source.url, budget: budget)
        defer { snapshot.remove() }
        var pointer: OpaquePointer?
        let path = snapshot.hasWAL ? snapshot.databaseURL.path : snapshot.databaseURL.absoluteString + "?immutable=1"
        let status = sqlite3_open_v2(path, &pointer, SQLITE_OPEN_READONLY | SQLITE_OPEN_URI, nil)
        guard status == SQLITE_OK, let database = pointer else {
            sqlite3_close(pointer)
            throw OpenClawReadError.sqlite(status)
        }
        defer { sqlite3_close(database) }
        sqlite3_busy_timeout(database, 1500)
        sqlite3_limit(
            database, SQLITE_LIMIT_LENGTH,
            Int32(min(budget.limits.maximumRecordBytes + 16384, Int(Int32.max))))
        let context = Unmanaged.passUnretained(budget).toOpaque()
        sqlite3_progress_handler(database, 1000, { context in
            guard let context else { return 1 }
            let budget = Unmanaged<OpenClawReadBudget>.fromOpaque(context).takeUnretainedValue()
            return budget.sqliteShouldInterrupt() ? 1 : 0
        }, context)
        defer { sqlite3_progress_handler(database, 0, nil, nil) }
        try execute("PRAGMA query_only=ON; PRAGMA trusted_schema=OFF; PRAGMA temp_store=MEMORY; BEGIN", in: database)
        defer { sqlite3_exec(database, "ROLLBACK", nil, nil, nil) }
        let metadata = try metadataStatements(in: database)
        defer { metadata.forEach { sqlite3_finalize($0) } }
        // Sort only stored transcript columns. Repeated metadata must not amplify
        // SQLite's sorter before the per-record and aggregate read guards run.
        let query = """
        SELECT session_id, event_json, created_at FROM transcript_events ORDER BY session_id, seq
        """
        var statement: OpaquePointer?
        try check(sqlite3_prepare_v2(database, query, -1, &statement, nil))
        defer { sqlite3_finalize(statement) }
        var parser = OpenClawMessageParser(sessionID: "")
        var session: String?
        while true {
            try Task.checkCancellation()
            let step = sqlite3_step(statement)
            if step == SQLITE_DONE { break }
            try check(step, allowingRow: true)
            try budget.record()
            guard let sessionID = try text(statement, column: 0, budget: budget), !sessionID.isEmpty,
                  let data = try data(statement, column: 1, budget: budget) else {
                parser.recordMalformedRow()
                continue
            }
            if session != sessionID {
                // A malformed row must not stop other sessions from being read.
                session = sessionID
                parser.beginSession(sessionID)
            }
            let createdAt = sqlite3_column_type(statement, 2)
            let date = createdAt == SQLITE_INTEGER || createdAt == SQLITE_FLOAT
                ? OpenClawMessageParser.date(sqlite3_column_double(statement, 2)) : nil
            let sessionMetadata = try self.metadata(metadata, sessionID: sessionID, budget: budget)
            if let event = parser.parse(
                data, fallbackDate: date,
                sessionModel: sessionMetadata.model,
                sessionProvider: sessionMetadata.provider) {
                consume(event)
            }
        }
        try parser.validate()
    }

    private static func metadataStatements(in database: OpaquePointer) throws -> [OpaquePointer?] {
        let required: Set = ["session_id", "seq", "event_json", "created_at"]
        guard try required.isSubset(of: columns("transcript_events", in: database)) else {
            throw OpenClawReadError.unsupportedSchema
        }
        var statements: [OpaquePointer?] = []
        for table in ["session_windows", "sessions"]
            where try Set(["session_id", "model_provider", "model"]).isSubset(of: columns(table, in: database)) {
            // Fixed, schema-checked identifiers only. LIMIT keeps duplicate metadata
            // rows in older/non-STRICT schemas from multiplying transcript events.
            let query = "SELECT model_provider, model FROM \(table) WHERE session_id = ? LIMIT 1"
            var statement: OpaquePointer?
            let status = sqlite3_prepare_v2(database, query, -1, &statement, nil)
            guard status == SQLITE_OK else {
                sqlite3_finalize(statement)
                statements.forEach { sqlite3_finalize($0) }
                try check(status)
                return []
            }
            statements.append(statement)
        }
        return statements
    }

    private static func metadata(
        _ statements: [OpaquePointer?], sessionID: String,
        budget: OpenClawReadBudget) throws -> (provider: String?, model: String?) {
        for statement in statements {
            if let row = try metadataRow(statement, sessionID: sessionID, budget: budget) { return row }
        }
        return (nil, nil)
    }

    private static func metadataRow(
        _ statement: OpaquePointer?, sessionID: String,
        budget: OpenClawReadBudget) throws -> (provider: String?, model: String?)? {
        guard let statement else { return nil }
        defer { sqlite3_reset(statement) }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        try check(sqlite3_bind_text(statement, 1, sessionID, -1, transient))
        let step = sqlite3_step(statement)
        if step == SQLITE_DONE { return nil }
        try check(step, allowingRow: true)
        return try (text(statement, column: 0, budget: budget), text(statement, column: 1, budget: budget))
    }

    private static func columns(_ table: String, in database: OpaquePointer) throws -> Set<String> {
        var statement: OpaquePointer?
        try check(sqlite3_prepare_v2(database, "PRAGMA table_info(\(table))", -1, &statement, nil))
        defer { sqlite3_finalize(statement) }
        var names: Set<String> = []
        while true {
            let step = sqlite3_step(statement)
            if step == SQLITE_DONE { return names }
            try check(step, allowingRow: true)
            if let value = sqlite3_column_text(statement, 1) { names.insert(String(cString: value)) }
        }
    }

    private static func text(_ statement: OpaquePointer?, column: Int32, budget: OpenClawReadBudget) throws -> String? {
        guard let data = try data(statement, column: column, budget: budget) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private static func data(_ statement: OpaquePointer?, column: Int32, budget: OpenClawReadBudget) throws -> Data? {
        guard sqlite3_column_type(statement, column) == SQLITE_TEXT else { return nil }
        let count = Int(sqlite3_column_bytes(statement, column))
        guard count <= budget.limits.maximumRecordBytes else { throw OpenClawReadError.limitExceeded }
        try budget.readBytes(count)
        guard let value = sqlite3_column_text(statement, column) else { return nil }
        return Data(bytes: value, count: count)
    }

    private static func execute(_ sql: String, in database: OpaquePointer) throws {
        try check(sqlite3_exec(database, sql, nil, nil, nil))
    }

    private static func check(_ status: Int32, allowingRow: Bool = false) throws {
        guard status != SQLITE_OK, !(allowingRow && status == SQLITE_ROW) else { return }
        try Task.checkCancellation()
        if status == SQLITE_INTERRUPT || status == SQLITE_TOOBIG { throw OpenClawReadError.limitExceeded }
        throw OpenClawReadError.sqlite(status)
    }
}
