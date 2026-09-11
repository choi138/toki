import Foundation

#if os(Linux)
    import CSQLite
#else
    import SQLite3
#endif

/// A read-only connection to a WAL database needs an existing `-shm`: SQLite cannot create
/// the shared-memory index without write access, so the first statement fails with
/// `SQLITE_CANTOPEN`. `immutable=1` reads the database file alone, which is correct only
/// while no sidecar exists, because an immutable read would otherwise omit committed WAL rows.
struct SQLiteSourceSnapshot: Equatable {
    let databaseURL: URL
    let databaseSignature: SQLiteFileSignature

    static func captureForImmutableFallback(
        databaseURL: URL,
        fileManager: FileManager = .default) -> SQLiteSourceSnapshot? {
        guard !hasSidecars(databaseURL: databaseURL, fileManager: fileManager),
              let databaseSignature = SQLiteFileSignature.capture(
                  at: databaseURL,
                  fileManager: fileManager),
              !hasSidecars(databaseURL: databaseURL, fileManager: fileManager) else {
            return nil
        }
        return SQLiteSourceSnapshot(
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

    private static func hasSidecars(
        databaseURL: URL,
        fileManager: FileManager) -> Bool {
        let path = databaseURL.path
        return fileManager.fileExists(atPath: "\(path)-wal")
            || fileManager.fileExists(atPath: "\(path)-shm")
            || fileManager.fileExists(atPath: "\(path)-journal")
    }
}

struct SQLiteFileSignature: Equatable {
    let systemNumber: UInt64?
    let fileNumber: UInt64?
    let size: UInt64
    let modificationDate: Date?

    static func capture(
        at fileURL: URL,
        fileManager: FileManager = .default) -> SQLiteFileSignature? {
        guard let attributes = try? fileManager.attributesOfItem(atPath: fileURL.path),
              let size = (attributes[.size] as? NSNumber)?.uint64Value else {
            return nil
        }
        return SQLiteFileSignature(
            systemNumber: (attributes[.systemNumber] as? NSNumber)?.uint64Value,
            fileNumber: (attributes[.systemFileNumber] as? NSNumber)?.uint64Value,
            size: size,
            modificationDate: attributes[.modificationDate] as? Date)
    }
}

func sqliteShouldRetryImmutableFallback(after resultCode: Int32) -> Bool {
    let primaryResultCode = resultCode & 0xFF
    return primaryResultCode == SQLITE_CANTOPEN
        || primaryResultCode == SQLITE_READONLY
}

func sqliteImmutableDatabaseURI(for databaseURL: URL) -> String {
    "\(databaseURL.absoluteString)?mode=ro&immutable=1"
}
