import Foundation
import TokiDurableStorage
import TokiSyncProtocol
import TokiUsageCore
import XCTest
@testable import TokiUsageReaders

final class HermesProfileBoundaryTests: XCTestCase {
    func test_registryScopesPersistedHistoryAcrossExplicitAThenBThenDefaultAndRestart() async throws {
        let fixture = try HermesM1Fixture()
        defer { fixture.remove() }
        let explicitA = fixture.root.appendingPathComponent("explicit-a/state.db")
        let explicitB = fixture.root.appendingPathComponent("explicit-b/state.db")
        let named = fixture.database("named")
        for database in [fixture.database(), named, explicitA, explicitB] {
            try fixture.createDatabase(at: database)
            try await fixture.seedLedger(at: fixture.ledgerURL(for: database == fixture.database() ? nil : database))
        }
        try fixture.insert(at: fixture.database(), tokens: 1, model: "default-model")
        try fixture.insert(at: named, tokens: 2, model: "named-model")
        try fixture.insert(at: explicitA, tokens: 10, model: "a-model")
        try fixture.insert(at: explicitB, tokens: 20, model: "b-model")

        // Populate default-root named history before switching explicit roots.
        _ = try await fixture.registryReader().readUsage(from: fixture.start, to: fixture.end)
        for (home, expected, models) in [
            (Optional(explicitA.deletingLastPathComponent()), 10, Set(["a-model"])),
            (Optional(explicitB.deletingLastPathComponent()), 20, Set(["b-model"])),
            (Optional(named.deletingLastPathComponent()), 2, Set(["named-model"])),
            (nil, 3, Set(["default-model", "named-model"])),
        ] {
            let reader = try fixture.registryReader(at: home)
            let usage = try await reader.readUsage(from: fixture.start, to: fixture.end)
            let repeated = try await reader.readUsage(from: fixture.start, to: fixture.end)
            let restarted = try await fixture.registryReader(at: home)
                .readUsage(from: fixture.start, to: fixture.end)
            for result in [usage, repeated, restarted] {
                XCTAssertEqual(result.inputTokens, expected)
                XCTAssertEqual(Set(result.perModel.keys), models)
                XCTAssertEqual(result.tokenEvents.count, models.count)
                XCTAssertEqual(result.totalTokens, expected + 14 * models.count)
            }
        }
    }

    func test_removedProfileHistorySurvivesRestartAndRemainsScoped() async throws {
        let fixture = try HermesM1Fixture()
        defer { fixture.remove() }
        let database = fixture.database("removed")
        try fixture.createDatabase(at: database)
        try await fixture.seedLedger(at: fixture.ledgerURL(for: database))
        try fixture.insert(at: database, tokens: 17)
        let initial = try await fixture.reader().readUsage(from: fixture.start, to: fixture.end)
        let ledgerData = try Data(contentsOf: fixture.ledgerURL(for: database))
        try FileManager.default.removeItem(at: database.deletingLastPathComponent())

        let restarted = try await fixture.reader().readUsage(from: fixture.start, to: fixture.end)
        let unrelated = try await fixture.reader(at: fixture.root.appendingPathComponent("unrelated"))
            .readUsage(from: fixture.start, to: fixture.end)

        XCTAssertEqual(initial.inputTokens, 17)
        XCTAssertEqual(restarted.tokenEvents, initial.tokenEvents)
        XCTAssertEqual(restarted.workTime, initial.workTime)
        XCTAssertEqual(unrelated.totalTokens, 0)
        XCTAssertEqual(try Data(contentsOf: fixture.ledgerURL(for: database)), ledgerData)
    }

    func test_existingFlatProfileLedgerAndDefaultLegacyIdentityArePreserved() async throws {
        let fixture = try HermesM1Fixture()
        defer { fixture.remove() }
        let profile = fixture.database("existing")
        var originalUsage: [RawTokenUsage] = []
        var originalBytes: [Data] = []
        for database in [fixture.database(), profile] {
            let ledgerURL = fixture.ledgerURL(for: database == profile ? profile : nil)
            try fixture.createDatabase(at: database)
            try await fixture.seedLedger(at: ledgerURL)
            try fixture.insert(at: database, tokens: 13)
            try await originalUsage.append(HermesReader(
                dbPathOverride: database.path, usageLedger: HermesUsageLedger(fileURL: ledgerURL),
                now: { fixture.now }).readUsage(from: fixture.start, to: fixture.end))
            try originalBytes.append(Data(contentsOf: ledgerURL))
        }
        let usage = try await fixture.reader().readUsage(from: fixture.start, to: fixture.end)

        XCTAssertEqual(usage.inputTokens, 26)
        XCTAssertEqual(
            usage.tokenEvents.first?.attribution?.sessionID,
            originalUsage[0].tokenEvents.first?.attribution?.sessionID)
        XCTAssertEqual(try Data(contentsOf: fixture.ledgerURL()), originalBytes[0])
        XCTAssertEqual(try Data(contentsOf: fixture.ledgerURL(for: profile)), originalBytes[1])
        XCTAssertEqual(Set(usage.tokenEvents.compactMap { $0.attribution?.sessionID }).count, 2)
    }

    func test_firstImportIsUndatedThenOnlyCounterGrowthIsDatedAndConserved() async throws {
        let fixture = try HermesM1Fixture()
        defer { fixture.remove() }
        let database = fixture.database("history")
        try fixture.createDatabase(at: database)
        try fixture.insert(at: database, tokens: 100)
        let reader = fixture.reader()
        let first = try await reader.readUsage(from: fixture.start, to: fixture.end)
        let status = try await HermesUsageLedger(fileURL: fixture.ledgerURL(for: database)).status()
        XCTAssertEqual(first.totalTokens, 0)
        XCTAssertEqual(status.unattributedTokens, 114)
        XCTAssertEqual(status.accurateSince, fixture.now)

        try fixture.sql(at: database, "UPDATE sessions SET input_tokens = 110, actual_cost_usd = 0.5")
        let growth = try await reader.readUsage(from: fixture.start, to: fixture.end)
        XCTAssertEqual(growth.inputTokens, 10)
        XCTAssertEqual(growth.totalTokens, 10)
        XCTAssertEqual(growth.cost, 0.25, accuracy: 0.000_001)
        XCTAssertEqual(growth.perModel["fixture-model"]?.totalTokens, 10)
        XCTAssertEqual(growth.tokenEvents.reduce(0) { $0 + $1.totalTokens }, 10)
        let beforeEnd = try await reader.readUsage(from: fixture.start, to: fixture.now)
        XCTAssertEqual(beforeEnd.totalTokens, 0)

        try fixture.sql(at: database, "UPDATE sessions SET input_tokens = 2, actual_cost_usd = 0.01")
        let reset = try await reader.readUsage(from: fixture.start, to: fixture.end)
        XCTAssertEqual(reset.totalTokens, 10)
        try fixture.sql(at: database, "UPDATE sessions SET input_tokens = 5, actual_cost_usd = 0.02")
        let afterReset = try await fixture.reader().readUsage(from: fixture.start, to: fixture.end)
        XCTAssertEqual(afterReset.inputTokens, 13)
        XCTAssertEqual(afterReset.cost, 0.26, accuracy: 0.000_001)
    }

    func test_eachProfileUsesItsOwnCompletedSnapshotObservationTime() async throws {
        let fixture = try HermesM1Fixture()
        defer { fixture.remove() }
        for database in [fixture.database(), fixture.database("later")] {
            try fixture.createDatabase(at: database)
            try await fixture.seedLedger(at: fixture.ledgerURL(for: database == fixture.database() ? nil : database))
            try fixture.insert(at: database, tokens: 10)
        }
        try fixture.sql(
            at: fixture.database("later"),
            "UPDATE sessions SET started_at = \(fixture.now.addingTimeInterval(2).timeIntervalSince1970)")
        let clock = HermesM1Clock([fixture.now, fixture.now.addingTimeInterval(1), fixture.now.addingTimeInterval(3)])
        let reader = HermesReader(
            hermesHomeURL: fixture.hermesHome, includesProfiles: true, usesLegacyDefaultLedger: true,
            usageLedger: HermesUsageLedger(fileURL: fixture.ledgerURL()),
            profileLedgerDirectory: fixture.ledgerDirectory(), now: { clock.next() })
        let usage = try await reader.readUsage(from: fixture.start, to: fixture.end)
        XCTAssertEqual(usage.inputTokens, 20)
        XCTAssertTrue(usage.supplemental.isEmpty)
    }
}

extension HermesProfileBoundaryTests {
    func test_profileAndRootSymlinksCountPhysicalDatabaseOnceAndKeepHistory() async throws {
        let fixture = try HermesM1Fixture()
        defer { fixture.remove() }
        let database = fixture.database("real")
        try fixture.createDatabase(at: database)
        try await fixture.seedLedger(at: fixture.ledgerURL(for: database))
        try fixture.insert(at: database, tokens: 11)
        try FileManager.default.createSymbolicLink(
            at: fixture.database("alias").deletingLastPathComponent(),
            withDestinationURL: database.deletingLastPathComponent())
        let usage = try await fixture.reader().readUsage(from: fixture.start, to: fixture.end)
        XCTAssertEqual(usage.inputTokens, 11)
        XCTAssertEqual(usage.tokenEvents.count, 1)
        let rootAlias = fixture.root.appendingPathComponent("root-alias")
        try FileManager.default.createSymbolicLink(at: rootAlias, withDestinationURL: fixture.hermesHome)
        try FileManager.default.removeItem(at: database.deletingLastPathComponent())
        let aliasReader = HermesReader(
            hermesHomeURL: rootAlias, includesProfiles: true, usesLegacyDefaultLedger: true,
            usageLedger: HermesUsageLedger(fileURL: fixture.ledgerURL()),
            profileLedgerDirectory: fixture.ledgerDirectory(), now: { fixture.now })
        let retained = try await aliasReader.readUsage(from: fixture.start, to: fixture.end)
        XCTAssertEqual(retained.inputTokens, 11)
    }

    func test_cancellationFromLedgerIsNotConvertedIntoPartialSuccess() async throws {
        let fixture = try HermesM1Fixture()
        defer { fixture.remove() }
        try fixture.createDatabase(at: fixture.database())
        try fixture.createDatabase(at: fixture.database("healthy"))
        let ledger = HermesUsageLedger(fileURL: fixture.ledgerURL(), privateFileWriter: { _, _ in
            throw CancellationError()
        })
        do {
            _ = try await fixture.reader(ledger: ledger).readUsage(from: fixture.start, to: fixture.end)
            XCTFail("Cancellation must abort collection")
        } catch is CancellationError {}
    }

    func test_preCancelledReadDoesNotInitializeAnyLedger() async throws {
        let fixture = try HermesM1Fixture()
        defer { fixture.remove() }
        try fixture.createDatabase(at: fixture.database("healthy"))
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await fixture.reader().readUsage(from: fixture.start, to: fixture.end)
        }
        do {
            _ = try await task.value
            XCTFail("Cancelled reads must throw")
        } catch is CancellationError {}
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.ledgerDirectory().path))
    }

    func test_discoveryLimitFailsWithoutReturningTruncatedSuccess() throws {
        let fixture = try HermesM1Fixture()
        defer { fixture.remove() }
        try fixture.createDatabase(at: fixture.database("first"))
        try fixture.createDatabase(at: fixture.database("second"))
        XCTAssertThrowsError(try discoverHermesDatabaseSources(
            hermesHome: fixture.hermesHome, includesProfiles: true, maximumProfileCount: 1))
    }

    func test_hardLinkedDatabasesAreCollectedOnce() async throws {
        let fixture = try HermesM1Fixture()
        defer { fixture.remove() }
        let database = fixture.database("a-original")
        let alias = fixture.database("z-hardlink")
        try fixture.createDatabase(at: database)
        try await fixture.seedLedger(at: fixture.ledgerURL(for: database))
        try fixture.insert(at: database, tokens: 14)
        try FileManager.default.createDirectory(
            at: alias.deletingLastPathComponent(),
            withIntermediateDirectories: true)
        try FileManager.default.linkItem(at: database, to: alias)
        let usage = try await fixture.reader().readUsage(from: fixture.start, to: fixture.end)
        XCTAssertEqual(usage.inputTokens, 14)
        XCTAssertEqual(usage.tokenEvents.count, 1)
    }

    func test_replacedDatabaseAtSamePathKeepsPriorHistoryAndOnlyDatesSubsequentGrowth() async throws {
        let fixture = try HermesM1Fixture()
        defer { fixture.remove() }
        let database = fixture.database("replaced")
        try fixture.createDatabase(at: database)
        try await fixture.seedLedger(at: fixture.ledgerURL(for: database))
        try fixture.insert(at: database, tokens: 40)
        _ = try await fixture.reader().readUsage(from: fixture.start, to: fixture.end)
        try FileManager.default.removeItem(at: database)
        try fixture.createDatabase(at: database)
        try fixture.insert(at: database, tokens: 2)
        let restarted = fixture.reader()
        let replacement = try await restarted.readUsage(from: fixture.start, to: fixture.end)
        XCTAssertEqual(replacement.inputTokens, 40)
        try fixture.sql(at: database, "UPDATE sessions SET input_tokens = 5")
        let growth = try await restarted.readUsage(from: fixture.start, to: fixture.end)
        XCTAssertEqual(growth.inputTokens, 43)
        XCTAssertEqual(Set(growth.tokenEvents.compactMap { $0.attribution?.sessionID }).count, 1)
    }

    func test_addingEarlierHardlinkAliasDoesNotSwitchLedgerOrLoseGrowth() async throws {
        let fixture = try HermesM1Fixture()
        defer { fixture.remove() }
        let database = fixture.database("z-original")
        let alias = fixture.database("a-new-alias")
        try fixture.createDatabase(at: database)
        try await fixture.seedLedger(at: fixture.ledgerURL(for: database))
        try fixture.insert(at: database, tokens: 10)
        let reader = fixture.reader()
        let original = try await reader.readUsage(from: fixture.start, to: fixture.end)
        try FileManager.default.createDirectory(
            at: alias.deletingLastPathComponent(),
            withIntermediateDirectories: true)
        try FileManager.default.linkItem(at: database, to: alias)
        try fixture.sql(at: database, "UPDATE sessions SET input_tokens = 15")
        let restarted = try await fixture.reader().readUsage(from: fixture.start, to: fixture.end)
        XCTAssertEqual(restarted.inputTokens, 15)
        XCTAssertEqual(
            Set(restarted.tokenEvents.compactMap { $0.attribution?.sessionID }),
            Set(original.tokenEvents.compactMap { $0.attribution?.sessionID }))
    }

    func test_defaultV2LedgerMigrationRetainsHistoryAndIdentityAcrossRestart() async throws {
        let fixture = try HermesM1Fixture()
        defer { fixture.remove() }
        let key = Data(repeating: 7, count: 32).base64EncodedString()
        let identifier = try SnapshotCipher.makeOpaqueIdentifierHasher(key: key).identifier(for: "legacy-session")
        let legacy = HermesUsageLedgerDocument(
            schemaVersion: hermesUsageLedgerPreviousSchemaVersion, identifierKey: key,
            accurateSince: fixture.start, lastSuccessfulObservationAt: fixture.now,
            baselines: [:], unattributed: [:], events: [HermesUsageLedgerEvent(
                sessionIdentifier: identifier, timestamp: fixture.activityAt, model: "legacy-model",
                counters: HermesTokenCounters(
                    inputTokens: 8,
                    outputTokens: 2,
                    cacheReadTokens: 0,
                    cacheWriteTokens: 0,
                    reasoningTokens: 1),
                cost: 0.5, projectName: nil, attributionQuality: .unknown)])
        try DurableFileIO.writePrivate(JSONEncoder().encode(legacy), to: fixture.ledgerURL())

        let reader = try fixture.registryReader()
        let usage = try await reader.readUsage(from: fixture.start, to: fixture.end)
        let migratedData = try Data(contentsOf: fixture.ledgerURL())
        let migrated = try JSONDecoder().decode(HermesUsageLedgerPrivateDocument.self, from: migratedData)
        XCTAssertEqual(usage.totalTokens, 11)
        XCTAssertEqual(usage.cost, 0.5)
        XCTAssertEqual(usage.tokenEvents.first?.attribution?.sessionID, identifier)
        XCTAssertEqual(migrated.events.map(\.event), legacy.events)
        XCTAssertEqual(migrated.accurateSince, legacy.accurateSince)
        let restarted = try await fixture.registryReader().readUsage(from: fixture.start, to: fixture.end)
        XCTAssertEqual(restarted.tokenEvents, usage.tokenEvents)
        XCTAssertEqual(try Data(contentsOf: fixture.ledgerURL()), migratedData)
    }
}
