import Foundation
import TokiUsageCore
import XCTest
@testable import TokiUsageReaders

final class HermesAliasOwnershipTests: XCTestCase {
    func test_defaultAndNamedHardlinkTransitionRejectsCompetingHistory() async throws {
        try await assertCompetingOwners(defaultOwner: true, symbolic: false)
    }

    func test_defaultAndNamedSymlinkTransitionRejectsCompetingHistory() async throws {
        try await assertCompetingOwners(defaultOwner: true, symbolic: true)
    }

    func test_twoNamedHardlinkTransitionRejectsCompetingHistory() async throws {
        try await assertCompetingOwners(defaultOwner: false, symbolic: false)
    }

    func test_twoNamedSymlinkTransitionRejectsCompetingHistory() async throws {
        try await assertCompetingOwners(defaultOwner: false, symbolic: true)
    }

    func test_twoNamedDirectorySymlinkTransitionRejectsCompetingHistory() async throws {
        try await assertCompetingOwners(defaultOwner: false, symbolic: true, directoryAlias: true)
    }

    func test_namedOnlyOwnerPromotedToDefaultKeepsNamespace() async throws {
        for symbolic in [false, true] {
            let fixture = try HermesM1Fixture()
            defer { fixture.remove() }
            let named = fixture.database("owner")
            try fixture.createDatabase(at: named)
            try await fixture.seedLedger(at: fixture.ledgerURL(for: named))
            try fixture.insert(at: named, tokens: 20)
            let reader = fixture.reader()
            let original = try await reader.readUsage(from: fixture.start, to: fixture.end)
            try link(named, to: fixture.database(), symbolic: symbolic)
            for current in [reader, reader, fixture.reader()] {
                let usage = try await current.readUsage(from: fixture.start, to: fixture.end)
                XCTAssertEqual(usage.tokenEvents, original.tokenEvents)
                XCTAssertEqual(usage.cost, original.cost)
                XCTAssertEqual(usage.totalTokens, 34)
            }
            try fixture.sql(at: named, "UPDATE sessions SET input_tokens = 25, actual_cost_usd = 0.5")
            let growth = try await fixture.reader().readUsage(from: fixture.start, to: fixture.end)
            XCTAssertEqual(growth.inputTokens, 25)
            XCTAssertEqual(growth.cost, 0.5)
            XCTAssertEqual(
                Set(growth.tokenEvents.compactMap { $0.attribution?.sessionID }),
                Set(original.tokenEvents.compactMap { $0.attribution?.sessionID }))
        }
    }

    func test_flatNamedOwnerWithNewEarlierAliasKeepsEstablishedHistory() async throws {
        let fixture = try HermesM1Fixture()
        defer { fixture.remove() }
        let named = fixture.database("z-owner")
        let alias = fixture.database("a-alias")
        try fixture.createDatabase(at: named)
        try await fixture.seedLedger(at: fixture.ledgerURL(for: named))
        try fixture.insert(at: named, tokens: 20)
        _ = try await HermesReader(
            dbPathOverride: named.path, usageLedger: HermesUsageLedger(fileURL: fixture.ledgerURL(for: named)),
            now: { fixture.now }).readUsage(from: fixture.start, to: fixture.end)
        try FileManager.default.createDirectory(
            at: alias.deletingLastPathComponent(),
            withIntermediateDirectories: true)
        try link(named, to: alias, symbolic: false)
        for _ in 0..<2 {
            let usage = try await fixture.reader().readUsage(from: fixture.start, to: fixture.end)
            XCTAssertEqual(
                usage.inputTokens,
                20,
                "Existing flat ledgers are owners even before collection registration")
            XCTAssertEqual(usage.cost, 0.25)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.ledgerURL(for: alias).path))
    }

    func test_flatDefaultAndNamedOwnersRejectAliasBeforeCollectionRegistration() async throws {
        let fixture = try HermesM1Fixture()
        defer { fixture.remove() }
        let named = fixture.database("named")
        for database in [fixture.database(), named] {
            let ledgerURL = fixture.ledgerURL(for: database == named ? named : nil)
            try fixture.createDatabase(at: database)
            try await fixture.seedLedger(at: ledgerURL)
            try fixture.insert(at: database, tokens: database == named ? 30 : 10)
            _ = try await HermesReader(
                dbPathOverride: database.path, usageLedger: HermesUsageLedger(fileURL: ledgerURL),
                now: { fixture.now }).readUsage(from: fixture.start, to: fixture.end)
        }
        let bytes = try hermesLedgerBytes(fixture)
        try FileManager.default.removeItem(at: fixture.database())
        try link(named, to: fixture.database(), symbolic: false)
        do {
            _ = try await fixture.reader().readUsage(from: fixture.start, to: fixture.end)
            XCTFail("Existing flat owners must not be silently merged")
        } catch HermesProfileCollectionError.invalidMembership {}
        XCTAssertEqual(try hermesLedgerBytes(fixture), bytes)
    }

    private func assertCompetingOwners(
        defaultOwner: Bool, symbolic: Bool, directoryAlias: Bool = false) async throws {
        let fixture = try HermesM1Fixture()
        defer { fixture.remove() }
        let first = fixture.database(defaultOwner ? nil : "first")
        let second = fixture.database("second")
        for (database, tokens) in [(first, 10), (second, 30)] {
            try fixture.createDatabase(at: database)
            try await fixture.seedLedger(at: fixture.ledgerURL(for: database == fixture.database() ? nil : database))
            try fixture.insert(at: database, tokens: tokens)
            if database == second {
                try fixture.sql(at: database, "UPDATE sessions SET actual_cost_usd = 0.75")
            }
        }
        let reader = fixture.reader()
        let original = try await reader.readUsage(from: fixture.start, to: fixture.end)
        XCTAssertEqual(original.inputTokens, 40)
        XCTAssertEqual(original.totalTokens, 68)
        XCTAssertEqual(original.cost, 1)
        XCTAssertEqual(original.tokenEvents.map(\.timestamp), [fixture.activityAt, fixture.activityAt])
        XCTAssertEqual(Set(original.tokenEvents.compactMap { $0.attribution?.sessionID }).count, 2)
        let bytes = try hermesLedgerBytes(fixture)
        // Replace the lower baseline with the higher one: refreshing it again dates duplicate growth.
        let aliasURL = directoryAlias ? first.deletingLastPathComponent() : first
        let targetURL = directoryAlias ? second.deletingLastPathComponent() : second
        try FileManager.default.removeItem(at: aliasURL)
        try link(targetURL, to: aliasURL, symbolic: symbolic)
        for current in [reader, reader, fixture.reader()] {
            do {
                let usage = try await current.readUsage(from: fixture.start, to: fixture.end)
                XCTFail("Competing durable owners must fail closed; exported input tokens: \(usage.inputTokens)")
            } catch HermesProfileCollectionError.invalidMembership {}
            XCTAssertEqual(try hermesLedgerBytes(fixture), bytes, "Rejected aliases must not refresh or rewrite keys")
        }
        // Recover the original physical layout and prove retained events/namespaces are unchanged.
        try FileManager.default.removeItem(at: aliasURL)
        try fixture.createDatabase(at: first)
        try fixture.insert(at: first, tokens: 10)
        let restored = try await fixture.reader().readUsage(from: fixture.start, to: fixture.end)
        XCTAssertEqual(restored.tokenEvents, original.tokenEvents)
        XCTAssertEqual(restored.cost, original.cost)
    }

    private func link(_ source: URL, to alias: URL, symbolic: Bool) throws {
        if symbolic {
            try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: source)
        } else {
            try FileManager.default.linkItem(at: source, to: alias)
        }
    }
}

func hermesLedgerBytes(_ fixture: HermesM1Fixture) throws -> [String: Data] {
    let directory = fixture.ledgerURL().deletingLastPathComponent()
    let enumerator = try XCTUnwrap(FileManager.default.enumerator(
        at: directory, includingPropertiesForKeys: [.isRegularFileKey]))
    var bytes: [String: Data] = [:]
    for case let url as URL in enumerator
        where try url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true {
        bytes[url.path] = try Data(contentsOf: url)
    }
    return bytes
}
