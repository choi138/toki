import Foundation

#if os(Linux)
    import CSQLite
#else
    import SQLite3
#endif

final class HermesSQLiteConnection {
    let database: OpaquePointer

    private let immutableSnapshot: HermesDatabaseSourceSnapshot?

    private init(
        database: OpaquePointer,
        immutableSnapshot: HermesDatabaseSourceSnapshot?) {
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
        guard fileManager.fileExists(atPath: path) else { return nil }

        do {
            return try openValidatedDatabase(
                path: path,
                flags: SQLITE_OPEN_READONLY,
                immutableSnapshot: nil)
        } catch let error as HermesSQLiteError {
            let databaseURL = URL(fileURLWithPath: path)
            guard hermesSQLiteShouldRetryImmutableFallback(after: error.code),
                  let snapshot = HermesDatabaseSourceSnapshot.captureForImmutableFallback(
                      databaseURL: databaseURL,
                      fileManager: fileManager) else {
                throw error
            }

            return try openValidatedDatabase(
                path: immutableDatabaseURI(for: databaseURL),
                flags: SQLITE_OPEN_READONLY | SQLITE_OPEN_URI,
                immutableSnapshot: snapshot)
        }
    }

    private static func openValidatedDatabase(
        path: String,
        flags: Int32,
        immutableSnapshot: HermesDatabaseSourceSnapshot?) throws -> HermesSQLiteConnection {
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

    private static func immutableDatabaseURI(for databaseURL: URL) -> String {
        "\(databaseURL.absoluteString)?mode=ro&immutable=1"
    }
}

func hermesSQLiteShouldRetryImmutableFallback(after resultCode: Int32) -> Bool {
    let primaryResultCode = resultCode & 0xFF
    return primaryResultCode == SQLITE_CANTOPEN
        || primaryResultCode == SQLITE_READONLY
}

struct HermesDatabaseSourceSnapshot: Equatable {
    let databaseURL: URL
    let databaseSignature: HermesDatabaseFileSignature

    static func captureForImmutableFallback(
        databaseURL: URL,
        fileManager: FileManager = .default) -> HermesDatabaseSourceSnapshot? {
        guard !hasSQLiteSidecars(databaseURL: databaseURL, fileManager: fileManager),
              let databaseSignature = HermesDatabaseFileSignature.capture(
                  at: databaseURL,
                  fileManager: fileManager),
              !hasSQLiteSidecars(databaseURL: databaseURL, fileManager: fileManager) else {
            return nil
        }
        return HermesDatabaseSourceSnapshot(
            databaseURL: databaseURL,
            databaseSignature: databaseSignature)
    }

    func isCurrent(fileManager: FileManager = .default) -> Bool {
        guard let currentSnapshot = Self.captureForImmutableFallback(
            databaseURL: databaseURL,
            fileManager: fileManager) else {
            return false
        }
        return currentSnapshot == self
    }

    private static func hasSQLiteSidecars(
        databaseURL: URL,
        fileManager: FileManager) -> Bool {
        let path = databaseURL.path
        return fileManager.fileExists(atPath: "\(path)-wal")
            || fileManager.fileExists(atPath: "\(path)-shm")
            || fileManager.fileExists(atPath: "\(path)-journal")
    }
}

struct HermesDatabaseFileSignature: Equatable {
    let systemNumber: UInt64?
    let fileNumber: UInt64?
    let size: UInt64
    let modificationDate: Date?

    static func capture(
        at fileURL: URL,
        fileManager: FileManager = .default) -> HermesDatabaseFileSignature? {
        guard let attributes = try? fileManager.attributesOfItem(atPath: fileURL.path),
              let size = (attributes[.size] as? NSNumber)?.uint64Value else {
            return nil
        }
        return HermesDatabaseFileSignature(
            systemNumber: (attributes[.systemNumber] as? NSNumber)?.uint64Value,
            fileNumber: (attributes[.systemFileNumber] as? NSNumber)?.uint64Value,
            size: size,
            modificationDate: attributes[.modificationDate] as? Date)
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
