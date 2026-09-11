import Foundation
import TokiUsageCore

#if os(Linux)
    import CSQLite
#else
    import SQLite3
#endif

/// OpenCode-only schema probes. No JSON SQL functions, other application tables, or writable fallback.
final class OpenCodeSQLiteReader {
    private let database: OpaquePointer
    private let budget: OpenCodeReadBudget
    private let immutableSnapshot: SQLiteSourceSnapshot?

    init(url: URL, budget: OpenCodeReadBudget, fileManager: FileManager = .default) throws {
        try Task.checkCancellation()
        self.budget = budget
        let connection = try OpenCodeSQLiteConnection.open(url: url, budget: budget, fileManager: fileManager)
        database = connection.database
        immutableSnapshot = connection.immutableSnapshot
    }

    deinit {
        sqlite3_progress_handler(database, 0, nil, nil)
        sqlite3_close(database)
    }

    /// False once a writer reappeared under an immutable read, whose snapshot would then
    /// be missing WAL rows. Always true for an ordinary read-only connection.
    var isSourceStateCurrent: Bool {
        immutableSnapshot?.isCurrent() ?? true
    }

    func read(store: OpenCodeDatabaseStore) throws -> [OpenCodeMessage] {
        // A deferred read transaction pins schema, session metadata and both generations to
        // one SQLite snapshot. immutable=1 belongs only to the sidecar-free fallback in
        // init, where there is no WAL to omit; never select it for a live database.
        try execute("BEGIN", operation: "begin")
        defer { sqlite3_exec(database, "ROLLBACK", nil, nil, nil) }
        let tables = try tableNames()
        guard tables.contains("message") || tables.contains("session_message") else {
            throw OpenCodeReaderError.unsupportedSchema
        }
        var messages: [OpenCodeMessageIdentity: OpenCodeMessage] = [:]
        var hasDecodedRecords = false
        var hasUndecodableRecords = false
        // v2 wins an ID-proven overlap with v1. Counts, timestamps and model names are
        // deliberately never used as evidence that independent events are duplicates.
        for table in ["session_message", "message"] where tables.contains(table) {
            try Task.checkCancellation()
            let columns = try columnNames(table)
            let v2 = table == "session_message"
            guard columns.isSuperset(of: ["session_id", "data"]),
                  v2 ? columns.isSuperset(of: ["id", "type"]) : columns.contains("id") || columns
                  .contains("time_created") else { throw OpenCodeReaderError.unsupportedSchema }
            let metadata = try metadataExpressions(v2: v2, tables: tables)
            let id = columns.contains("id") ? "CAST(m.id AS TEXT)" : "NULL"
            let physicalID = try physicalIDExpression(table, columns: columns)
            let time = columns.contains("time_created") ? "m.time_created" : "NULL"
            let role = v2 ? "m.type" : "NULL"
            let query = """
            SELECT \(id), m.session_id, m.data, \(time), \(role), \(metadata.path), \(metadata.title), \(physicalID)
            FROM \(table) m
            """
            let statement = try prepare(query)
            defer { sqlite3_finalize(statement) }
            var rowNumber = 0
            while try step(statement) {
                try budget.consumeRow()
                rowNumber += 1
                let bytes = Int(sqlite3_column_bytes(statement, 2))
                guard bytes <= budget.limits.maximumRecordBytes else { throw OpenCodeReaderError.limitExceeded }
                // SQLite has already materialized the row, including ignored v2 roles.
                // Charge every text/blob projection before deciding whether it contributes usage.
                for column in [Int32(0), 1, 2, 4, 5, 6, 7] {
                    try budget.consumeBytes(Int(sqlite3_column_bytes(statement, column)))
                }
                let ignoresUsage = v2 && text(statement, 4) != "assistant"
                if ignoresUsage, hasDecodedRecords { continue }
                guard let pointer = sqlite3_column_blob(statement, 2), bytes > 0,
                      let payload = (try? JSONSerialization.jsonObject(with: Data(bytes: pointer, count: bytes)))
                      as? [String: Any] else {
                    hasUndecodableRecords = true
                    continue
                }
                // Valid user/unmetered records prove the store is decodable even without usage.
                hasDecodedRecords = true
                if ignoresUsage { continue }
                let rowID = text(statement, 0)
                var context = OpenCodeMessage.Context(
                    namespace: store.namespace,
                    originID: "\(table):" + (rowID.map { "id:\($0)" }
                        ?? text(statement, 7).map { "rowid:\($0)" } ?? "ordinal:\(rowNumber)"))
                // Only a genuine SQL ID may follow the payload ID as a migration identity.
                context.rowID = rowID
                context.sessionID = text(statement, 1)
                let dateType = sqlite3_column_type(statement, 3)
                if dateType == SQLITE_INTEGER || dateType == SQLITE_FLOAT {
                    context.timestampMilliseconds = sqlite3_column_double(statement, 3)
                }
                context.assistantType = v2
                context.projectPath = text(statement, 5)
                context.sessionLabel = text(statement, 6)
                guard let message = OpenCodeMessage.parse(payload, context: context) else { continue }
                if let existing = messages[message.identity] {
                    if existing.originID.hasPrefix("\(table):"), message.originID < existing.originID {
                        messages[message.identity] = message
                    }
                } else {
                    messages[message.identity] = message
                }
            }
        }
        try Task.checkCancellation()
        if hasUndecodableRecords, !hasDecodedRecords { throw OpenCodeReaderError.unreadableSource }
        return Array(messages.values)
    }

    private func tableNames() throws -> Set<String> {
        let statement = try prepare("""
        SELECT name FROM sqlite_master WHERE type = 'table'
        AND name IN ('message', 'session_message', 'session', 'session_v2')
        """)
        defer { sqlite3_finalize(statement) }
        var names: Set<String> = []
        while try step(statement) {
            if let name = text(statement, 0) { names.insert(name) }
        }
        return names
    }

    private func columnNames(_ table: String) throws -> Set<String> {
        // table is selected only from the four fixed schema names above.
        // table_xinfo includes generated columns, which can also shadow hidden rowid aliases.
        let statement = try prepare("PRAGMA table_xinfo(\(table))")
        defer { sqlite3_finalize(statement) }
        var names: Set<String> = []
        while try step(statement) {
            if let name = text(statement, 1) { names.insert(name.lowercased()) }
        }
        return names
    }

    private func physicalIDExpression(_ table: String, columns: Set<String>) throws -> String {
        guard let alias = ["rowid", "_rowid_", "oid"].first(where: { !columns.contains($0) }) else {
            return "NULL"
        }
        try Task.checkCancellation()
        // All identifiers are fixed allowlisted names. Prepare without stepping to detect
        // WITHOUT ROWID without parsing CREATE TABLE SQL or reading another snapshot.
        var statement: OpaquePointer?
        let status = sqlite3_prepare_v2(database, "SELECT m.\(alias) FROM \(table) m LIMIT 0", -1, &statement, nil)
        defer { sqlite3_finalize(statement) }
        if status == SQLITE_OK { return "CAST(m.\(alias) AS TEXT)" }
        if status != SQLITE_ERROR { try fail(operation: "probe rowid", code: status) }
        // WITHOUT ROWID or all-shadowed tables use a per-table ordinal, bounded by the
        // row budget. It is unique only within this read snapshot, never a migration ID
        // or persisted cursor; identical payloads still represent independent rows.
        return "NULL"
    }

    private func metadataExpressions(v2: Bool, tables: Set<String>) throws -> (path: String, title: String) {
        let candidates = v2 ? ["session_v2", "session"] : ["session"]
        for table in candidates where tables.contains(table) {
            let columns = try columnNames(table)
            guard columns.contains("id"), columns.contains("directory") || columns.contains("title") else { continue }
            // Correlated, bounded lookups avoid multiplying message rows if a damaged
            // metadata table contains repeated session IDs.
            let path = columns.contains("directory")
                ? "(SELECT s.directory FROM \(table) s WHERE s.id = m.session_id LIMIT 1)" : "NULL"
            let title = columns.contains("title")
                ? "(SELECT s.title FROM \(table) s WHERE s.id = m.session_id LIMIT 1)" : "NULL"
            return (path, title)
        }
        return ("NULL", "NULL")
    }

    private func prepare(_ query: String) throws -> OpaquePointer {
        try Task.checkCancellation()
        var statement: OpaquePointer?
        let status = sqlite3_prepare_v2(database, query, -1, &statement, nil)
        guard status == SQLITE_OK, let statement else {
            sqlite3_finalize(statement)
            try fail(operation: "prepare", code: status)
        }
        return statement
    }

    private func step(_ statement: OpaquePointer) throws -> Bool {
        try Task.checkCancellation()
        let status = sqlite3_step(statement)
        if status == SQLITE_ROW { return true }
        if status == SQLITE_DONE { return false }
        try fail(operation: "query", code: status)
    }

    private func execute(_ query: String, operation: String) throws {
        let status = sqlite3_exec(database, query, nil, nil, nil)
        guard status == SQLITE_OK else { try fail(operation: operation, code: status) }
    }

    private func fail(operation: String, code: Int32) throws -> Never {
        try Task.checkCancellation()
        if budget.sqliteLimitExceeded || code == SQLITE_TOOBIG { throw OpenCodeReaderError.limitExceeded }
        throw OpenCodeReaderError.sqlite(operation: operation, code: code)
    }

    private func text(_ statement: OpaquePointer, _ column: Int32) -> String? {
        guard sqlite3_column_type(statement, column) == SQLITE_TEXT,
              let pointer = sqlite3_column_text(statement, column) else { return nil }
        let size = Int(sqlite3_column_bytes(statement, column))
        return String(bytes: UnsafeBufferPointer(start: pointer, count: size), encoding: .utf8)?.trimmedNonEmpty
    }
}
