import Foundation
import TokiUsageCore
import XCTest
@testable import TokiUsageReaders

#if os(Linux)
    import CSQLite
#else
    import SQLite3
#endif

/// Isolated synthetic reproduction of review findings. No personal files or production mutations.
final class HermesReviewReproductionTests: XCTestCase {
    func test_inaccessibleProfileIsNotReportedAsCompleteCollection() async throws {
        let fixture = try HermesM1Fixture()
        defer { fixture.remove() }
        let hiddenDatabase = fixture.database("inaccessible")
        try fixture.createDatabase(at: fixture.database())
        try fixture.insert(at: fixture.database(), tokens: 10)
        try await fixture.seedLedger(at: fixture.ledgerURL())
        try fixture.createDatabase(at: hiddenDatabase)
        try fixture.insert(at: hiddenDatabase, tokens: 200)
        try await fixture.seedLedger(at: fixture.ledgerURL(for: hiddenDatabase))
        let directory = hiddenDatabase.deletingLastPathComponent()
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: directory.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path) }
        // Prove this is an access failure, not a fixture with an absent database.
        try XCTSkipIf(
            FileManager.default.fileExists(atPath: hiddenDatabase.path),
            "The test process can bypass directory traversal permissions")
        XCTAssertTrue(FileManager.default.fileExists(atPath: directory.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: hiddenDatabase.path))
        XCTAssertThrowsError(try FileManager.default.attributesOfItem(atPath: hiddenDatabase.path))
        let reader = fixture.reader()
        let usage = try await reader.readUsage(from: fixture.start, to: fixture.end)
        XCTAssertEqual(usage.inputTokens, 10, "The readable default source remains usable")
        XCTAssertEqual(
            usage.supplemental.first { $0.id == "hermes-profile-read-errors" }?.value,
            1,
            "An inaccessible profile must not disappear as if absent")
        XCTAssertEqual(try reader.coverageStatus().profileReadErrorCount, 1)
        do {
            _ = try await HermesSnapshotReader(reader: reader).readUsage(from: fixture.start, to: fixture.end)
            XCTFail("Snapshot export must not claim a complete read while a profile cannot be inspected")
        } catch HermesProfileCollectionError.incompleteCollection {}
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        let restored = try await fixture.reader().readUsage(from: fixture.start, to: fixture.end)
        XCTAssertEqual(restored.inputTokens, 210, "Restoring access proves the omitted source contains usage")
        XCTAssertNil(restored.supplemental.first { $0.id == "hermes-profile-read-errors" })
    }

    func test_hardlinkDedupPreservesCommittedWALFromProducerAlias() async throws {
        let fixture = try HermesM1Fixture()
        defer { fixture.remove() }
        let producer = fixture.database("z-producer")
        let alias = fixture.database("a-alias")
        try fixture.createDatabase(at: producer)
        try FileManager.default.createDirectory(
            at: alias.deletingLastPathComponent(),
            withIntermediateDirectories: true)
        try FileManager.default.linkItem(at: producer, to: alias)
        try await fixture.seedLedger(at: fixture.ledgerURL(for: alias))
        let pinnedRead = try fixture.open(at: producer)
        defer { sqlite3_close(pinnedRead) }
        try fixture.execute("PRAGMA journal_mode = WAL; PRAGMA wal_autocheckpoint = 0", in: pinnedRead)
        try fixture.execute("BEGIN DEFERRED TRANSACTION; SELECT COUNT(*) FROM sessions", in: pinnedRead)
        defer { _ = sqlite3_exec(pinnedRead, "ROLLBACK", nil, nil, nil) }
        let checkpointed = try Data(contentsOf: producer)
        try fixture.insert(at: producer, tokens: 37)
        XCTAssertEqual(try Data(contentsOf: producer), checkpointed, "Committed insertion must remain WAL-only")
        XCTAssertEqual(try Data(contentsOf: alias), checkpointed)
        XCTAssertTrue(FileManager.default.fileExists(atPath: producer.path + "-wal"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: alias.path + "-wal"))
        let collected = try await fixture.reader().readUsage(from: fixture.start, to: fixture.end)
        // This assertion demonstrates the data-loss finding through the real multi-profile reader.
        XCTAssertEqual(collected.inputTokens, 37, "Dedup must not choose a stale hardlink snapshot")
        XCTAssertEqual(collected.tokenEvents.count, 1)
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: fixture.ledgerURL(for: producer).path),
            "Selecting the producer's read path must preserve the alias ledger")
        let repeated = try await fixture.reader().readUsage(from: fixture.start, to: fixture.end)
        XCTAssertEqual(repeated.inputTokens, 37)
        XCTAssertEqual(repeated.tokenEvents, collected.tokenEvents)
        let directLedger = fixture.root.appendingPathComponent("direct-control-ledger.json")
        try await fixture.seedLedger(at: directLedger)
        let direct = try await HermesReader(
            dbPathOverride: producer.path,
            usageLedger: HermesUsageLedger(fileURL: directLedger),
            now: { [now = fixture.now] in now })
            .readUsage(from: fixture.start, to: fixture.end)
        XCTAssertEqual(direct.inputTokens, 37, "The producer path exposes committed WAL usage")
    }
}

extension HermesReviewReproductionTests {
    func test_hardlinkWALReadPreservesEstablishedLedgerAndIdentity() async throws {
        let fixture = try HermesM1Fixture()
        defer { fixture.remove() }
        let anchor = fixture.database("a-ledger")
        let producer = fixture.database("z-producer")
        try fixture.createDatabase(at: anchor)
        try fixture.insert(at: anchor, tokens: 10)
        try await fixture.seedLedger(at: fixture.ledgerURL(for: anchor))
        let initial = try await fixture.reader().readUsage(from: fixture.start, to: fixture.end)
        try FileManager.default.createDirectory(
            at: producer.deletingLastPathComponent(),
            withIntermediateDirectories: true)
        try FileManager.default.linkItem(at: anchor, to: producer)
        let pinnedRead = try fixture.open(at: producer)
        defer { sqlite3_close(pinnedRead) }
        try fixture.execute("PRAGMA journal_mode = WAL; PRAGMA wal_autocheckpoint = 0", in: pinnedRead)
        try fixture.execute("BEGIN DEFERRED TRANSACTION; SELECT COUNT(*) FROM sessions", in: pinnedRead)
        defer { _ = sqlite3_exec(pinnedRead, "ROLLBACK", nil, nil, nil) }
        let checkpointed = try Data(contentsOf: anchor)
        try fixture.sql(at: producer, "UPDATE sessions SET input_tokens = 17")
        XCTAssertEqual(try Data(contentsOf: anchor), checkpointed)
        let updated = try await fixture.reader().readUsage(from: fixture.start, to: fixture.end)
        XCTAssertEqual(updated.inputTokens, 17)
        XCTAssertEqual(
            Set(updated.tokenEvents.compactMap { $0.attribution?.sessionID }),
            Set(initial.tokenEvents.compactMap { $0.attribution?.sessionID }))
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.ledgerURL(for: producer).path))
    }

    func test_conflictingHardlinkJournalsDoNotReturnAnApparentlyCompleteSnapshot() async throws {
        let fixture = try HermesM1Fixture()
        defer { fixture.remove() }
        let first = fixture.database("first")
        let second = fixture.database("second")
        try fixture.createDatabase(at: first)
        try FileManager.default.createDirectory(
            at: second.deletingLastPathComponent(),
            withIntermediateDirectories: true)
        try FileManager.default.linkItem(at: first, to: second)
        // Synthetic sidecars model two aliases with independent journal state, which
        // cannot safely be reduced to one representative by filename or modification time.
        for database in [first, second] {
            try Data(repeating: 1, count: 32).write(to: URL(fileURLWithPath: database.path + "-wal"))
        }
        XCTAssertThrowsError(try discoverHermesDatabaseSources(
            hermesHome: fixture.hermesHome, includesProfiles: true))
        do {
            _ = try await HermesSnapshotReader(reader: fixture.reader())
                .readUsage(from: fixture.start, to: fixture.end)
            XCTFail("Conflicting alias journals must not be exported as complete usage")
        } catch HermesProfileCollectionError.discoveryFailed {}
    }

    func test_absentProfileDatabaseAndDanglingAliasRemainClean() async throws {
        let fixture = try HermesM1Fixture()
        defer { fixture.remove() }
        try fixture.createDatabase(at: fixture.database())
        try fixture.insert(at: fixture.database(), tokens: 10)
        try await fixture.seedLedger(at: fixture.ledgerURL())
        try FileManager.default.createDirectory(
            at: fixture.database("empty").deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(
            at: fixture.database("dangling").deletingLastPathComponent(),
            withDestinationURL: fixture.database("removed").deletingLastPathComponent())
        let reader = fixture.reader()
        let usage = try await HermesSnapshotReader(reader: reader).readUsage(from: fixture.start, to: fixture.end)
        XCTAssertEqual(usage.inputTokens, 10)
        XCTAssertNil(usage.supplemental.first { $0.id == "hermes-profile-read-errors" })
        XCTAssertEqual(try reader.coverageStatus().profileReadErrorCount, 0)
    }

    func test_inaccessibleProfileRetainsHistoryWithoutClaimingCompleteUsage() async throws {
        let fixture = try HermesM1Fixture()
        defer { fixture.remove() }
        let database = fixture.database("unavailable")
        try fixture.createDatabase(at: database)
        try fixture.insert(at: database, tokens: 12)
        try await fixture.seedLedger(at: fixture.ledgerURL(for: database))
        let initial = try await fixture.reader().readUsage(from: fixture.start, to: fixture.end)
        XCTAssertEqual(initial.inputTokens, 12)
        let directory = database.deletingLastPathComponent()
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: directory.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path) }
        try XCTSkipIf(
            FileManager.default.fileExists(atPath: database.path),
            "The test process can bypass directory traversal permissions")
        let unavailable = try await fixture.reader().readUsage(from: fixture.start, to: fixture.end)
        XCTAssertEqual(unavailable.inputTokens, 12)
        XCTAssertEqual(unavailable.tokenEvents, initial.tokenEvents)
        XCTAssertEqual(unavailable.supplemental.first { $0.id == "hermes-profile-read-errors" }?.value, 1)
        XCTAssertThrowsError(try fixture.reader().coverageStatus())
    }
}
