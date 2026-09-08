import Foundation
import TokiUsageCore
import XCTest
@testable import TokiUsageReaders

#if os(Linux)
    import CSQLite
#else
    import SQLite3
#endif

final class HermesPhysicalDefaultAliasTests: XCTestCase {
    func test_hardlinkPreservesLegacyDatedUsageAcrossRestart() async throws {
        try await assertAlias(kind: "hardlink", existing: true)
    }

    func test_freshHardlinkKeepsDefaultBaselineAndDatesOnlyGrowth() async throws {
        try await assertAlias(kind: "hardlink", existing: false)
    }

    func test_symlinkPreservesLegacyDatedUsageAcrossRestart() async throws {
        try await assertAlias(kind: "symlink", existing: true)
    }

    func test_caseAliasPreservesLegacyDatedUsageAcrossRestart() async throws {
        try await assertAlias(kind: "case", existing: true)
    }

    func test_absentDefaultUsesPathFallbackButUnrelatedDatabaseDoesNotInherit() async throws {
        let fixture = try HermesM1Fixture()
        defer { fixture.remove() }
        let original = try await seedDefault(fixture)
        try FileManager.default.removeItem(at: fixture.database())
        let retained = try await explicitReader(fixture, home: fixture.hermesHome)
            .readUsage(from: fixture.start, to: fixture.end)
        XCTAssertEqual(retained.tokenEvents, original.tokenEvents)
        let unrelated = fixture.root.appendingPathComponent("unrelated/state.db")
        try fixture.createDatabase(at: unrelated)
        try fixture.insert(at: unrelated, tokens: 99)
        for _ in 0..<2 {
            let usage = try await explicitReader(fixture, home: unrelated.deletingLastPathComponent())
                .readUsage(from: fixture.start, to: fixture.end)
            XCTAssertEqual(usage.totalTokens, 0)
        }
    }

    func test_liveHardlinkRetargetIsolatesLegacyHistory() async throws {
        let fixture = try HermesM1Fixture()
        defer { fixture.remove() }
        let original = try await seedDefault(fixture)
        let selected = fixture.root.appendingPathComponent("selected/state.db")
        try FileManager.default.createDirectory(
            at: selected.deletingLastPathComponent(),
            withIntermediateDirectories: true)
        try FileManager.default.linkItem(at: fixture.database(), to: selected)
        let reader = explicitReader(fixture, home: selected.deletingLastPathComponent())
        for linkedToDefault in [true, false, true] {
            if !linkedToDefault {
                try FileManager.default.removeItem(at: selected)
                try fixture.createDatabase(at: selected)
                try fixture.insert(at: selected, tokens: 99)
            } else if !FileManager.default.contentsEqual(atPath: selected.path, andPath: fixture.database().path) {
                try FileManager.default.removeItem(at: selected)
                try FileManager.default.linkItem(at: fixture.database(), to: selected)
            }
            for current in [reader, explicitReader(fixture, home: selected.deletingLastPathComponent())] {
                let usage = try await current.readUsage(from: fixture.start, to: fixture.end)
                XCTAssertEqual(usage.tokenEvents, linkedToDefault ? original.tokenEvents : [])
            }
        }
    }

    func test_defaultJournalOwnerIsReadThroughExplicitHardlink() async throws {
        let fixture = try HermesM1Fixture()
        defer { fixture.remove() }
        _ = try await seedDefault(fixture)
        let selected = fixture.root.appendingPathComponent("selected/state.db")
        try FileManager.default.createDirectory(
            at: selected.deletingLastPathComponent(),
            withIntermediateDirectories: true)
        try FileManager.default.linkItem(at: fixture.database(), to: selected)
        let pinned = try fixture.open(at: fixture.database())
        defer { sqlite3_close(pinned) }
        try fixture.execute("PRAGMA journal_mode = WAL; PRAGMA wal_autocheckpoint = 0", in: pinned)
        try fixture.execute("BEGIN; SELECT COUNT(*) FROM sessions", in: pinned)
        defer { _ = sqlite3_exec(pinned, "ROLLBACK", nil, nil, nil) }
        let before = try Data(contentsOf: fixture.database())
        try fixture.sql(at: fixture.database(), "UPDATE sessions SET input_tokens = 25, actual_cost_usd = 0.5")
        XCTAssertEqual(try Data(contentsOf: fixture.database()), before)
        for _ in 0..<2 {
            let usage = try await explicitReader(fixture, home: selected.deletingLastPathComponent())
                .readUsage(from: fixture.start, to: fixture.end)
            XCTAssertEqual(usage.inputTokens, 25)
            XCTAssertEqual(usage.cost, 0.5)
        }
    }

    func test_conflictingExplicitAndDefaultJournalsFailBeforeLedgerMutation() async throws {
        let fixture = try HermesM1Fixture()
        defer { fixture.remove() }
        _ = try await seedDefault(fixture)
        let selected = fixture.root.appendingPathComponent("selected/state.db")
        try FileManager.default.createDirectory(
            at: selected.deletingLastPathComponent(),
            withIntermediateDirectories: true)
        try FileManager.default.linkItem(at: fixture.database(), to: selected)
        let bytes = try hermesLedgerBytes(fixture)
        for database in [selected, fixture.database()] {
            try Data(repeating: 1, count: 32).write(to: URL(fileURLWithPath: database.path + "-wal"))
        }
        let reader = explicitReader(fixture, home: selected.deletingLastPathComponent())
        do {
            _ = try await reader.readUsage(from: fixture.start, to: fixture.end)
            XCTFail("Independent journals must fail closed")
        } catch HermesProfileCollectionError.discoveryFailed {}
        XCTAssertEqual(try hermesLedgerBytes(fixture), bytes)
        XCTAssertThrowsError(try reader.coverageStatus())
    }

    private func assertAlias(kind: String, existing: Bool) async throws {
        let fixture = try HermesM1Fixture()
        defer { fixture.remove() }
        let original: RawTokenUsage
        if existing {
            original = try await seedDefault(fixture)
        } else {
            try fixture.createDatabase(at: fixture.database())
            try fixture.insert(at: fixture.database(), tokens: 20)
            original = RawTokenUsage()
        }
        let selected: URL
        if kind == "case" {
            selected = fixture.home.appendingPathComponent(".HERMES")
            try XCTSkipUnless(
                FileManager.default.fileExists(atPath: selected.appendingPathComponent("state.db").path),
                "Case-sensitive filesystem has no case-only alias")
        } else {
            selected = fixture.root.appendingPathComponent("selected")
            try FileManager.default.createDirectory(at: selected, withIntermediateDirectories: true)
            if kind == "symlink" {
                try FileManager.default.createSymbolicLink(
                    at: selected.appendingPathComponent("state.db"), withDestinationURL: fixture.database())
            } else {
                try FileManager.default.linkItem(
                    at: fixture.database(),
                    to: selected.appendingPathComponent("state.db"))
            }
        }
        let reader = explicitReader(fixture, home: selected)
        for current in [reader, reader, explicitReader(fixture, home: selected)] {
            let usage = try await current.readUsage(from: fixture.start, to: fixture.end)
            XCTAssertEqual(usage.tokenEvents, original.tokenEvents)
            XCTAssertEqual(usage.cost, original.cost)
        }
        let defaultBytes = try Data(contentsOf: fixture.ledgerURL())
        let keyBytes = try Data(contentsOf: hermesUsageLedgerIdentifierKeyURL(for: fixture.ledgerURL()))
        try fixture.sql(at: fixture.database(), "UPDATE sessions SET input_tokens = 25, actual_cost_usd = 0.5")
        let growth = try await explicitReader(fixture, home: selected).readUsage(from: fixture.start, to: fixture.end)
        XCTAssertEqual(growth.inputTokens, existing ? 25 : 5)
        XCTAssertEqual(growth.cost, existing ? 0.5 : 0.25)
        XCTAssertNotEqual(try Data(contentsOf: fixture.ledgerURL()), defaultBytes)
        XCTAssertEqual(try Data(contentsOf: hermesUsageLedgerIdentifierKeyURL(for: fixture.ledgerURL())), keyBytes)
        let restarted = try await explicitReader(fixture, home: selected).readUsage(
            from: fixture.start,
            to: fixture.end)
        XCTAssertEqual(restarted.tokenEvents, growth.tokenEvents)
    }
}

private func explicitReader(_ fixture: HermesM1Fixture, home: URL) -> HermesReader {
    HermesReader(
        hermesHomeURL: home, includesProfiles: false, usesLegacyDefaultLedger: true,
        usageLedger: HermesUsageLedger(fileURL: fixture.ledgerURL()),
        profileLedgerDirectory: fixture.ledgerDirectory(), legacyDefaultDatabaseURL: fixture.database(),
        now: { fixture.now })
}

private func seedDefault(_ fixture: HermesM1Fixture) async throws -> RawTokenUsage {
    try fixture.createDatabase(at: fixture.database())
    try fixture.insert(at: fixture.database(), tokens: 20)
    try await fixture.seedLedger(at: fixture.ledgerURL())
    return try await explicitReader(fixture, home: fixture.hermesHome).readUsage(from: fixture.start, to: fixture.end)
}
