import Foundation
import TokiSyncProtocol
import XCTest
@testable import TokiUsageReaders

final class HermesCollectionRetargetTests: XCTestCase {
    func test_rootRetargetAfterDiscoveryKeepsMembershipAndRestartedUsageIsolated() async throws {
        let fixture = try HermesM1Fixture()
        defer { fixture.remove() }
        let firstHome = fixture.root.appendingPathComponent("collection-a")
        let secondHome = fixture.root.appendingPathComponent("collection-b")
        let selectedHome = fixture.root.appendingPathComponent("selected-home")
        let firstDatabase = firstHome.appendingPathComponent("state.db")
        let secondDatabase = secondHome.appendingPathComponent("state.db")
        for (database, tokens, model) in [
            (firstDatabase, 11, "a-model"),
            (secondDatabase, 23, "b-model"),
        ] {
            try fixture.createDatabase(at: database)
            try await fixture.seedLedger(at: fixture.ledgerURL(for: database))
            try fixture.insert(at: database, tokens: tokens, model: model)
        }
        // Populate A's retained ledger without registering collection membership.
        let firstUsage = try await HermesReader(
            dbPathOverride: firstDatabase.path,
            usageLedger: HermesUsageLedger(fileURL: fixture.ledgerURL(for: firstDatabase)),
            now: { fixture.now }).readUsage(from: fixture.start, to: fixture.end)
        XCTAssertEqual(firstUsage.inputTokens, 11)
        try FileManager.default.createSymbolicLink(at: selectedHome, withDestinationURL: firstHome)
        let selected = fixture.reader(at: selectedHome)
        let store = HermesProfileLedgerStore(
            defaultLedger: HermesUsageLedger(fileURL: fixture.ledgerURL()),
            includesDefaultLedger: false, directory: fixture.ledgerDirectory(),
            hermesHome: selectedHome, includesProfiles: false)
        let collection = try store.discoverCollection()
        XCTAssertEqual(collection.sources.map(\.databaseURL), [firstDatabase.resolvingSymlinksInPath()])

        // Deterministically reproduce the handoff before the ledger actor starts selection.
        try retarget(selectedHome, to: secondHome)
        _ = try await store.selectedLedgers(collection: collection)
        let secondMembership = membershipURL(home: secondHome, directory: fixture.ledgerDirectory())
        XCTAssertFalse(FileManager.default.fileExists(atPath: secondMembership.path))
        let firstMembership = membershipURL(home: firstHome, directory: fixture.ledgerDirectory())
        XCTAssertTrue(FileManager.default.fileExists(atPath: firstMembership.path))
        let locations = try store.sourceLocations(collection: collection)
        XCTAssertTrue(locations.contains(.file(firstMembership, includesSQLiteSidecars: false)))
        XCTAssertFalse(locations.contains(.file(secondMembership, includesSQLiteSidecars: false)))

        // Removing A's source makes any leaked usage provably come from retained membership.
        try FileManager.default.removeItem(at: firstDatabase)
        let secondUsage = try await selected.readUsage(from: fixture.start, to: fixture.end)
        let restartedSecond = try await fixture.reader(at: selectedHome)
            .readUsage(from: fixture.start, to: fixture.end)
        for usage in [secondUsage, restartedSecond] {
            XCTAssertEqual(usage.inputTokens, 23)
            XCTAssertEqual(Set(usage.perModel.keys), ["b-model"])
            XCTAssertEqual(usage.tokenEvents.count, 1)
        }
        let membership = try JSONDecoder().decode(Membership.self, from: Data(contentsOf: secondMembership))
        let secondIdentifier = SnapshotCipher.digest(
            "toki.hermes.profile-ledger.v1:\(secondDatabase.resolvingSymlinksInPath().standardizedFileURL.path)")
        XCTAssertEqual(membership.ledgerIdentifiers, [secondIdentifier])

        try retarget(selectedHome, to: firstHome)
        let reusedFirst = try await selected.readUsage(from: fixture.start, to: fixture.end)
        let restartedFirst = try await fixture.reader(at: selectedHome)
            .readUsage(from: fixture.start, to: fixture.end)
        for usage in [reusedFirst, restartedFirst] {
            XCTAssertEqual(usage.inputTokens, 11)
            XCTAssertEqual(Set(usage.perModel.keys), ["a-model"])
            XCTAssertEqual(usage.tokenEvents.count, 1)
        }
    }

    private func retarget(_ alias: URL, to home: URL) throws {
        try FileManager.default.removeItem(at: alias)
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: home)
    }

    private func membershipURL(home: URL, directory: URL) -> URL {
        let identifier = SnapshotCipher.digest(
            "toki.hermes.profile-collection.v1:false:false:\(home.resolvingSymlinksInPath().standardizedFileURL.path)")
        return directory.appendingPathComponent("hermes-profile-collection-\(identifier).json")
    }

    private struct Membership: Decodable {
        let ledgerIdentifiers: [String]
    }
}
