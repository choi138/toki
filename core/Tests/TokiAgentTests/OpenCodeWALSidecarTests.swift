import Foundation
import TokiUsageCore
import XCTest
@testable import TokiUsageReaders

#if os(Linux)
    import CSQLite
#else
    import SQLite3
#endif

final class OpenCodeWALSidecarTests: XCTestCase {
    func test_walDatabaseWithoutSidecarsStillReadsAfterWriterExits() async throws {
        let fixture = try OpenCodeFixture()
        defer { fixture.remove() }
        let url = fixture.root.appendingPathComponent("opencode.db")
        do {
            let database = try OpenCodeTestDatabase(at: url)
            try database.execute("PRAGMA journal_mode=WAL;")
            try database.insert(fixture.payload())
        }
        for suffix in ["-wal", "-shm"] {
            try? FileManager.default.removeItem(atPath: url.path + suffix)
            XCTAssertFalse(FileManager.default.fileExists(atPath: url.path + suffix))
        }

        let usage = try await read(OpenCodeReader(dataRoots: [fixture.root]))

        XCTAssertEqual(usage.totalTokens, 158)
        XCTAssertEqual(usage.tokenEvents.count, 1)
    }

    func test_immutableFallbackIsRefusedWhileASidecarExists() throws {
        let fixture = try OpenCodeFixture()
        defer { fixture.remove() }
        let url = fixture.root.appendingPathComponent("opencode.db")
        let database = try OpenCodeTestDatabase(at: url)
        try database.execute("PRAGMA journal_mode=WAL; PRAGMA wal_autocheckpoint=0;")
        try database.insert(fixture.payload())

        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path + "-wal"))
        XCTAssertNil(SQLiteSourceSnapshot.captureForImmutableFallback(databaseURL: url))
    }

    func test_openFailuresOutsideTheSidecarCaseAreNotRetried() {
        XCTAssertTrue(sqliteShouldRetryImmutableFallback(after: SQLITE_CANTOPEN))
        XCTAssertTrue(sqliteShouldRetryImmutableFallback(after: SQLITE_READONLY))
        XCTAssertFalse(sqliteShouldRetryImmutableFallback(after: SQLITE_CORRUPT))
        XCTAssertFalse(sqliteShouldRetryImmutableFallback(after: SQLITE_NOTADB))
    }

    private func read(_ reader: OpenCodeReader) async throws -> RawTokenUsage {
        try await reader.readUsage(
            from: OpenCodeFixture.date.addingTimeInterval(-1), to: OpenCodeFixture.date.addingTimeInterval(120))
    }
}
