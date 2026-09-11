import Foundation

#if os(Linux)
    import CSQLite
#else
    import SQLite3
#endif

/// Read-only connection setup for one OpenCode database, including the sidecar-free
/// immutable fallback. Owns no handle: the caller closes what it receives.
enum OpenCodeSQLiteConnection {
    static func open(
        url: URL,
        budget: OpenCodeReadBudget,
        fileManager: FileManager = .default) throws
        -> (database: OpaquePointer, immutableSnapshot: SQLiteSourceSnapshot?) {
        do {
            let database = try openProbed(path: url.path, flags: SQLITE_OPEN_READONLY, budget: budget)
            return (database, nil)
        } catch let error as OpenCodeReaderError {
            guard case let .sqlite(_, code) = error,
                  sqliteShouldRetryImmutableFallback(after: code),
                  let snapshot = SQLiteSourceSnapshot.captureForImmutableFallback(
                      databaseURL: url,
                      fileManager: fileManager) else {
                throw error
            }
            let database = try openProbed(
                path: sqliteImmutableDatabaseURI(for: url),
                flags: SQLITE_OPEN_READONLY | SQLITE_OPEN_URI,
                budget: budget)
            return (database, snapshot)
        }
    }

    private static func openProbed(
        path: String,
        flags: Int32,
        budget: OpenCodeReadBudget) throws -> OpaquePointer {
        var handle: OpaquePointer?
        let status = sqlite3_open_v2(path, &handle, flags, nil)
        guard status == SQLITE_OK, let handle else {
            sqlite3_close(handle)
            throw OpenCodeReaderError.sqlite(operation: "open", code: status)
        }
        sqlite3_busy_timeout(handle, 2000)
        // SQLite also includes the other row columns in SQLITE_LIMIT_LENGTH.
        let rowLimit = min(budget.limits.maximumRecordBytes, Int(Int32.max) - 131_072) + 131_072
        sqlite3_limit(handle, SQLITE_LIMIT_LENGTH, Int32(rowLimit))
        // A WAL database whose -shm is gone opens fine and only fails once a statement is
        // compiled. Probe before installing the progress handler so the open path, not a
        // later read, decides whether the immutable fallback applies.
        let probeStatus = probe(handle)
        guard probeStatus == SQLITE_OK else {
            sqlite3_close(handle)
            throw OpenCodeReaderError.sqlite(operation: "probe", code: probeStatus)
        }
        sqlite3_progress_handler(handle, 1000, { context in
            guard let context else { return 1 }
            let budget = Unmanaged<OpenCodeReadBudget>.fromOpaque(context).takeUnretainedValue()
            return budget.interruptSQLite() ? 1 : 0
        }, Unmanaged.passUnretained(budget).toOpaque())
        return handle
    }

    private static func probe(_ database: OpaquePointer) -> Int32 {
        var statement: OpaquePointer?
        let status = sqlite3_prepare_v2(database, "PRAGMA schema_version", -1, &statement, nil)
        defer { sqlite3_finalize(statement) }
        guard status == SQLITE_OK else { return status }
        let stepStatus = sqlite3_step(statement)
        return stepStatus == SQLITE_ROW || stepStatus == SQLITE_DONE ? SQLITE_OK : stepStatus
    }
}
