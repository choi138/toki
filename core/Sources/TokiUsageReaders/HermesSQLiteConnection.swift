import Foundation

#if os(Linux)
    import CSQLite
#else
    import SQLite3
#endif

final class HermesSQLiteConnection {
    let database: OpaquePointer

    private let immutableSnapshot: SQLiteSourceSnapshot?

    private init(
        database: OpaquePointer,
        immutableSnapshot: SQLiteSourceSnapshot?) {
        self.database = database
        self.immutableSnapshot = immutableSnapshot
    }

    deinit {
        sqlite3_close(database)
    }

    var isSourceStateCurrent: Bool {
        immutableSnapshot?.isCurrent() ?? true
    }

    var isUsingImmutableSnapshot: Bool {
        immutableSnapshot != nil
    }

    static func open(
        atPath path: String,
        fileManager: FileManager = .default) throws -> HermesSQLiteConnection? {
        guard try hermesSourceExists(at: URL(fileURLWithPath: path)) else { return nil }

        do {
            return try openValidatedDatabase(
                path: path,
                flags: SQLITE_OPEN_READONLY,
                immutableSnapshot: nil)
        } catch let error as HermesSQLiteError {
            let databaseURL = URL(fileURLWithPath: path)
            guard sqliteShouldRetryImmutableFallback(after: error.code) else { throw error }
            guard let snapshot = SQLiteSourceSnapshot.captureForImmutableFallback(
                databaseURL: databaseURL,
                fileManager: fileManager) else {
                // The immutable read is refused while a sidecar is present, so this is the
                // one failure the operator cannot act on without knowing which side is wrong.
                throw HermesSQLiteError(
                    operation: error.operation,
                    message: "\(error.message); a sidecar is present, so the read-only WAL "
                        + "fallback was refused. Check that the database still has a -shm.",
                    code: error.code)
            }

            return try openValidatedDatabase(
                path: sqliteImmutableDatabaseURI(for: databaseURL),
                flags: SQLITE_OPEN_READONLY | SQLITE_OPEN_URI,
                immutableSnapshot: snapshot)
        }
    }

    private static func openValidatedDatabase(
        path: String,
        flags: Int32,
        immutableSnapshot: SQLiteSourceSnapshot?) throws -> HermesSQLiteConnection {
        var database: OpaquePointer?
        let openStatus = sqlite3_open_v2(path, &database, flags, nil)
        guard openStatus == SQLITE_OK, let database else {
            let error = HermesSQLiteError(
                operation: "open",
                database: database,
                code: openStatus)
            sqlite3_close(database)
            throw error
        }

        sqlite3_busy_timeout(database, 2000)
        let probeStatus = probeDatabase(database)
        guard probeStatus == SQLITE_OK else {
            let error = HermesSQLiteError(
                operation: "probe",
                database: database,
                code: probeStatus)
            sqlite3_close(database)
            throw error
        }

        return HermesSQLiteConnection(
            database: database,
            immutableSnapshot: immutableSnapshot)
    }

    private static func probeDatabase(_ database: OpaquePointer) -> Int32 {
        var statement: OpaquePointer?
        let prepareStatus = sqlite3_prepare_v2(
            database,
            "PRAGMA schema_version",
            -1,
            &statement,
            nil)
        guard prepareStatus == SQLITE_OK else { return prepareStatus }
        defer { sqlite3_finalize(statement) }

        let stepStatus = sqlite3_step(statement)
        guard stepStatus == SQLITE_ROW || stepStatus == SQLITE_DONE else {
            return stepStatus
        }
        return SQLITE_OK
    }
}

struct HermesSQLiteError: LocalizedError {
    let operation: String
    let message: String
    let code: Int32

    init(
        operation: String,
        database: OpaquePointer?,
        code: Int32? = nil) {
        self.operation = operation
        self.code = code ?? database.map(sqlite3_errcode) ?? SQLITE_ERROR
        if let database, let errorMessage = sqlite3_errmsg(database) {
            message = String(cString: errorMessage)
        } else {
            message = "unknown SQLite error"
        }
    }

    init(operation: String, message: String, code: Int32) {
        self.operation = operation
        self.message = message
        self.code = code
    }

    var errorDescription: String? {
        "Hermes SQLite \(operation) failed: \(message)"
    }
}
