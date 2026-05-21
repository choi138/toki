import Foundation
import SQLite3

func createSecurityAuditSQLiteDB(at url: URL, statements: [String]) throws {
    var database: OpaquePointer?
    guard sqlite3_open(url.path, &database) == SQLITE_OK, let database else {
        throw NSError(domain: "SecurityAuditScannerTests", code: 1)
    }
    defer { sqlite3_close(database) }

    for statement in statements {
        try executeSecurityAuditSQLiteStatement(statement, database: database)
    }
}

func executeSecurityAuditSQLiteStatement(_ statement: String, database: OpaquePointer?) throws {
    var errorMessage: UnsafeMutablePointer<CChar>?
    defer { sqlite3_free(errorMessage) }

    guard sqlite3_exec(database, statement, nil, nil, &errorMessage) == SQLITE_OK else {
        let message = errorMessage.map { String(cString: $0) } ?? "SQLite statement failed"
        throw NSError(
            domain: "SecurityAuditScannerTests",
            code: 2,
            userInfo: [NSLocalizedDescriptionKey: message])
    }
}
