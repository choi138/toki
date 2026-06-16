import Foundation
import SQLite3

struct SecurityFileScanResult {
    let findings: [SecurityFinding]
    let lineCount: Int
    let isCacheable: Bool

    init(findings: [SecurityFinding], lineCount: Int, isCacheable: Bool = true) {
        self.findings = findings
        self.lineCount = lineCount
        self.isCacheable = isCacheable
    }
}

extension SecurityAuditScanner {
    func sqliteWALModificationDate(
        for source: SecurityAuditFileSource,
        fileURL: URL,
        fileManager: FileManager) -> Date? {
        guard !source.sqliteTextQueries.isEmpty else { return nil }

        let walURL = URL(fileURLWithPath: fileURL.path + "-wal")
        let attributes = try? fileManager.attributesOfItem(atPath: walURL.path)
        return attributes?[.modificationDate] as? Date
    }

    func sqliteWALSignature(
        for source: SecurityAuditFileSource,
        fileURL: URL,
        fileManager: FileManager) -> SecurityAuditSQLiteWALSignature? {
        guard !source.sqliteTextQueries.isEmpty else { return nil }

        let walURL = URL(fileURLWithPath: fileURL.path + "-wal")
        guard let attributes = try? fileManager.attributesOfItem(atPath: walURL.path) else {
            return SecurityAuditSQLiteWALSignature(
                exists: false,
                fileSize: 0,
                modificationDate: nil,
                signature: nil)
        }

        let fileSize = (attributes[.size] as? NSNumber)?.int64Value ?? 0
        let modificationDate = attributes[.modificationDate] as? Date
        return SecurityAuditSQLiteWALSignature(
            exists: true,
            fileSize: fileSize,
            modificationDate: modificationDate,
            signature: SecurityAuditCacheSignature.signature(for: walURL, byteOffset: fileSize))
    }

    func scanSQLiteFile(
        _ fileURL: URL,
        sourceName: String,
        queries: [String],
        fallbackDetectedAt: Date?) -> SecurityFileScanResult {
        var database: OpaquePointer?
        guard sqlite3_open_v2(fileURL.path, &database, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
            sqlite3_close(database)
            return SecurityFileScanResult(findings: [], lineCount: 0, isCacheable: false)
        }
        defer { sqlite3_close(database) }

        sqlite3_busy_timeout(database, 2000)

        var findings: [SecurityFinding] = []
        var lineNumber = 0

        for query in queries {
            guard !Task.isCancelled else {
                return SecurityFileScanResult(
                    findings: findings,
                    lineCount: lineNumber,
                    isCacheable: false)
            }

            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(database, query, -1, &statement, nil) == SQLITE_OK else {
                sqlite3_finalize(statement)
                return SecurityFileScanResult(
                    findings: findings,
                    lineCount: lineNumber,
                    isCacheable: false)
            }
            defer { sqlite3_finalize(statement) }

            var isQueryComplete = false
            while !isQueryComplete {
                guard !Task.isCancelled else {
                    return SecurityFileScanResult(
                        findings: findings,
                        lineCount: lineNumber,
                        isCacheable: false)
                }

                switch sqlite3_step(statement) {
                case SQLITE_ROW:
                    for column in 0..<sqlite3_column_count(statement) {
                        guard let text = sqliteColumnText(statement, column: column) else { continue }

                        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
                        for line in lines {
                            guard !Task.isCancelled else {
                                return SecurityFileScanResult(
                                    findings: findings,
                                    lineCount: lineNumber,
                                    isCacheable: false)
                            }

                            lineNumber += 1
                            findings.append(
                                contentsOf: scanTextLine(
                                    String(line),
                                    sourceName: sourceName,
                                    fileURL: fileURL,
                                    lineNumber: lineNumber,
                                    fallbackDetectedAt: fallbackDetectedAt))
                        }
                    }
                case SQLITE_DONE:
                    isQueryComplete = true
                default:
                    return SecurityFileScanResult(
                        findings: findings,
                        lineCount: lineNumber,
                        isCacheable: false)
                }
            }
        }

        return SecurityFileScanResult(findings: findings, lineCount: lineNumber)
    }

    func sqliteColumnText(_ statement: OpaquePointer?, column: Int32) -> String? {
        guard let textPointer = sqlite3_column_text(statement, column) else { return nil }

        let byteCount = Int(sqlite3_column_bytes(statement, column))
        guard byteCount > 0 else { return nil }

        let data = Data(bytes: textPointer, count: byteCount)
        return String(data: data, encoding: .utf8)
    }
}
