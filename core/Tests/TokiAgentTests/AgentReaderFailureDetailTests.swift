import Foundation
import XCTest
@testable import TokiAgentCore
@testable import TokiUsageReaders

#if os(Linux)
    import CSQLite
#else
    import SQLite3
#endif

final class AgentReaderFailureDetailTests: XCTestCase {
    func test_readerDeclaredDescriptionIsForwarded() {
        let detail = AgentReaderFailureDetail.describe(OpenCodeReaderError.sqlite(operation: "probe", code: 14))

        XCTAssertEqual(detail, "OpenCode SQLite probe failed (code 14).")
    }

    func test_foundationErrorIsReducedToDomainAndCodeSoPathsDoNotLeak() {
        let error = NSError(
            domain: NSCocoaErrorDomain,
            code: 257,
            userInfo: [NSLocalizedDescriptionKey: "/Users/someone/.hermes/state.db could not be opened."])

        let detail = AgentReaderFailureDetail.describe(error)

        XCTAssertEqual(detail, "\(NSCocoaErrorDomain) (code 257)")
        XCTAssertFalse(detail.contains("/Users/someone"))
    }

    func test_snapshotBuilderErrorNamesTheReaderAndItsDetail() {
        let message = AgentSnapshotBuilderError
            .readerFailed("Hermes", detail: "Hermes SQLite probe failed: unable to open database file")
            .errorDescription

        XCTAssertEqual(
            message,
            "The Hermes usage reader failed: Hermes SQLite probe failed: unable to open database file "
                + "The previous remote snapshot was preserved.")
    }

    func test_refusedImmutableFallbackExplainsTheSidecar() throws {
        let root = FileManager.default.temporaryDirectory
            .resolvingSymlinksInPath()
            .appendingPathComponent("toki-hermes-sidecar-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: root.path)
            try? FileManager.default.removeItem(at: root)
        }
        let database = root.appendingPathComponent("state.db")
        do {
            var handle: OpaquePointer?
            XCTAssertEqual(sqlite3_open(database.path, &handle), SQLITE_OK)
            defer { sqlite3_close(handle) }
            XCTAssertEqual(
                sqlite3_exec(handle, "PRAGMA journal_mode=WAL; CREATE TABLE t (id TEXT);", nil, nil, nil),
                SQLITE_OK)
        }
        // Closing the writer removes both sidecars. A stray empty -wal without its -shm is the
        // state the Agent hits on a read-only mount: SQLite cannot recreate the -shm, and the
        // immutable fallback refuses because the -wal may still hold unmerged pages.
        for suffix in ["-wal", "-shm"] {
            try? FileManager.default.removeItem(atPath: database.path + suffix)
        }
        XCTAssertTrue(FileManager.default.createFile(atPath: database.path + "-wal", contents: Data()))
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: root.path)

        XCTAssertThrowsError(try HermesSQLiteConnection.open(atPath: database.path)) { error in
            let message = (error as? HermesSQLiteError)?.errorDescription ?? ""
            XCTAssertTrue(message.contains("a sidecar is present"), message)
            XCTAssertTrue(message.contains("-shm"), message)
        }
    }
}
