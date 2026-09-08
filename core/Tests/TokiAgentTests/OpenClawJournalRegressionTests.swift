import Foundation
import XCTest
@testable import TokiUsageReaders

#if os(Linux)
    import CSQLite
#else
    import SQLite3
#endif

final class OpenClawJournalRegressionTests: XCTestCase {
    func test_committedClosedTruncateJournalRemainsReadableWithoutSourceMutation() async throws {
        try await assertCommittedJournalReadable(mode: "TRUNCATE")
    }

    func test_committedClosedPersistJournalRemainsReadableWithoutSourceMutation() async throws {
        try await assertCommittedJournalReadable(mode: "PERSIST")
    }

    func test_activeRollbackJournalsRemainRejectedWithoutSourceMutation() async throws {
        for mode in ["TRUNCATE", "PERSIST", "DELETE"] {
            let fixture = try OpenClawFixture()
            defer { fixture.remove() }
            let database = try fixture.database()
            defer { sqlite3_close(database) }
            try fixture.execute("PRAGMA journal_mode=\(mode)", in: database)
            try fixture.insert(OpenClawFixture.event(), into: database)
            try fixture.execute("BEGIN IMMEDIATE", in: database)
            try fixture.insert(OpenClawFixture.event(id: "uncommitted"), into: database, seq: 1)
            let url = databaseURL(fixture)
            let before = try sourceBytes(url)
            XCTAssertGreaterThan(try XCTUnwrap(before["-journal"]).count, 28)
            do {
                _ = try await fixture.read()
                XCTFail("An active \(mode) journal must not produce a complete snapshot")
            } catch {
                XCTAssertEqual(error as? OpenClawReadError, .activeRollbackJournal)
            }
            XCTAssertEqual(try sourceBytes(url), before)
            try fixture.execute("ROLLBACK", in: database)
        }
    }

    func test_rolledBackJournalsResumeReadingCommittedUsageWithoutSourceMutation() async throws {
        for mode in ["TRUNCATE", "PERSIST"] {
            let fixture = try OpenClawFixture()
            defer { fixture.remove() }
            let database = try fixture.database()
            defer { sqlite3_close(database) }
            try fixture.execute("PRAGMA journal_mode=\(mode)", in: database)
            try fixture.insert(OpenClawFixture.event(), into: database)
            try fixture.execute("BEGIN IMMEDIATE", in: database)
            try fixture.insert(OpenClawFixture.event(id: "rolled-back"), into: database, seq: 1)
            try fixture.execute("ROLLBACK", in: database)
            let url = databaseURL(fixture)
            let before = try sourceBytes(url)
            let usage = try await fixture.read()
            XCTAssertEqual(usage.totalTokens, 360)
            XCTAssertEqual(try sourceBytes(url), before)
        }
    }

    func test_partialAndNonzeroJournalHeadersRemainRejectedWithoutSourceMutation() async throws {
        let fixture = try OpenClawFixture()
        defer { fixture.remove() }
        let url = try committedDatabase(fixture, mode: "DELETE")
        let journal = URL(fileURLWithPath: url.path + "-journal")
        var unsyncedHeader = Data(repeating: 0, count: 512)
        unsyncedHeader[12] = 1 // SQLite can write the initial header before its magic is synchronized.
        var hotHeader = Data(repeating: 0, count: 512)
        hotHeader.replaceSubrange(0..<8, with: [0xD9, 0xD5, 0x05, 0xF9, 0x20, 0xA1, 0x63, 0xD7])
        for data in [Data([0]), Data(repeating: 0, count: 27), unsyncedHeader, hotHeader] {
            try data.write(to: journal)
            let before = try sourceBytes(url)
            do {
                _ = try await fixture.read()
                XCTFail("An ambiguous or active journal header must remain rejected")
            } catch {
                XCTAssertEqual(error as? OpenClawReadError, .activeRollbackJournal)
            }
            XCTAssertEqual(try sourceBytes(url), before)
        }
    }

    func test_inactiveJournalHeaderReadsConsumeTheSharedByteBudget() throws {
        let fixture = try OpenClawFixture()
        defer { fixture.remove() }
        let url = try committedDatabase(fixture, mode: "PERSIST")
        let before = try sourceBytes(url)
        let databaseBytes = try XCTUnwrap(before[""]).count
        // The copy fits exactly; its two 28-byte journal checks must also fit.
        let limits = OpenClawReadLimits(maximumTotalBytes: databaseBytes + 55)
        XCTAssertThrowsError(try OpenClawDatabaseSnapshot(
            source: url, budget: OpenClawReadBudget(limits: limits))) { error in
                XCTAssertEqual(error as? OpenClawReadError, .limitExceeded)
            }
        XCTAssertEqual(try sourceBytes(url), before)
    }
}

private extension OpenClawJournalRegressionTests {
    func assertCommittedJournalReadable(mode: String) async throws {
        let fixture = try OpenClawFixture()
        defer { fixture.remove() }
        let url = try committedDatabase(fixture, mode: mode)
        let before = try sourceBytes(url)
        let journal = try XCTUnwrap(before["-journal"])
        if mode == "TRUNCATE" {
            XCTAssertTrue(journal.isEmpty)
        } else {
            XCTAssertGreaterThan(journal.count, 28)
            XCTAssertEqual(journal.prefix(28), Data(repeating: 0, count: 28))
            XCTAssertTrue(journal.dropFirst(28).contains { $0 != 0 })
        }
        let usage = try await fixture.read()
        XCTAssertEqual(usage.totalTokens, 360)
        XCTAssertEqual(usage.tokenEvents.count, 1)
        XCTAssertEqual(try sourceBytes(url), before)
    }

    func committedDatabase(_ fixture: OpenClawFixture, mode: String) throws -> URL {
        let database = try fixture.database()
        defer { XCTAssertEqual(sqlite3_close(database), SQLITE_OK) }
        try fixture.execute("PRAGMA journal_mode=\(mode)", in: database)
        try fixture.insert(OpenClawFixture.event(), into: database)
        return databaseURL(fixture)
    }

    func databaseURL(_ fixture: OpenClawFixture) -> URL {
        fixture.agents.appendingPathComponent("main/agent/openclaw-agent.sqlite")
    }

    func sourceBytes(_ url: URL) throws -> [String: Data] {
        var bytes: [String: Data] = [:]
        for suffix in ["", "-wal", "-shm", "-journal"] {
            let file = URL(fileURLWithPath: url.path + suffix)
            if FileManager.default.fileExists(atPath: file.path) { bytes[suffix] = try Data(contentsOf: file) }
        }
        return bytes
    }
}
