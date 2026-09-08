import Foundation
import TokiSyncProtocol
import TokiUsageCore
import XCTest
@testable import TokiAgentCore
@testable import TokiUsageReaders

final class HermesExplicitDefaultHomeTests: XCTestCase {
    func test_explicitDefaultAndAliasesPreserveDatedHistoryAcrossRestartWithoutNamedProfiles() async throws {
        let fixture = try HermesM1Fixture()
        defer { fixture.remove() }
        try fixture.createDatabase(at: fixture.database())
        try fixture.insert(at: fixture.database(), tokens: 13, model: "default-model")
        let original = try await datedLegacyUsage(fixture, scope: .application)
        XCTAssertEqual(original.totalTokens, 27)
        XCTAssertEqual(original.cost, 0.25, accuracy: 0.000_001)
        XCTAssertEqual(original.tokenEvents.map(\.timestamp), [fixture.activityAt])
        let keyURL = hermesUsageLedgerIdentifierKeyURL(for: fixture.ledgerURL())
        let originalKey = try Data(contentsOf: keyURL)
        let selections = try defaultHomeSelections(fixture)
        try await registerNamedHistory(fixture, scope: .application)

        for selectedHome in selections {
            let descriptor = try explicitDescriptor(fixture, home: selectedHome, scope: .application)
            for reader in try [descriptor.reader, descriptor.reader, fixture.registryReader(at: selectedHome)] {
                let usage = try await reader.readUsage(from: fixture.start, to: fixture.end)
                assertDatedUsage(usage, equals: original)
            }
        }
        XCTAssertEqual(try Data(contentsOf: keyURL), originalKey)

        // Legacy history must remain available after the selected source is removed.
        try FileManager.default.removeItem(at: fixture.database())
        let retainedBytes = try Data(contentsOf: fixture.ledgerURL())
        for selectedHome in selections.prefix(2) {
            let usage = try await fixture.registryReader(at: selectedHome)
                .readUsage(from: fixture.start, to: fixture.end)
            assertDatedUsage(usage, equals: original)
        }
        XCTAssertEqual(try Data(contentsOf: fixture.ledgerURL()), retainedBytes)
    }

    func test_explicitDefaultAndAliasesPreserveAgentSnapshotTotalsAndIdentitiesAcrossRestart() async throws {
        let fixture = try HermesM1Fixture()
        defer { fixture.remove() }
        try fixture.createDatabase(at: fixture.database())
        try fixture.insert(at: fixture.database(), tokens: 13, model: "default-model")
        let original = try await datedLegacyUsage(fixture, scope: .agent)
        let configuration = try fixture.configuration()
        let baseline = try await AgentSnapshotBuilder(
            home: fixture.home, environment: fixture.environment,
            readerDescriptors: [fixture.agentDescriptor()])
            .build(configuration: configuration, now: fixture.now)
        XCTAssertEqual(baseline.tokenEvents.map(\.totalTokens), [27])
        XCTAssertEqual(baseline.tokenEvents.compactMap(\.cost), [0.25])
        XCTAssertEqual(baseline.activityEvents.count, 1)
        let keyURL = hermesUsageLedgerIdentifierKeyURL(for: fixture.ledgerURL(scope: .agent))
        let originalKey = try Data(contentsOf: keyURL)
        let selections = try defaultHomeSelections(fixture)
        try await registerNamedHistory(fixture, scope: .agent)

        for selectedHome in selections {
            let descriptor = try explicitDescriptor(fixture, home: selectedHome, scope: .agent)
            let builder = AgentSnapshotBuilder(
                home: fixture.home, environment: fixture.environment, readerDescriptors: [descriptor])
            for selectedBuilder in try [builder, builder, AgentSnapshotBuilder(
                home: fixture.home, environment: fixture.environment,
                readerDescriptors: [explicitDescriptor(fixture, home: selectedHome, scope: .agent)])] {
                let snapshot = try await selectedBuilder.build(configuration: configuration, now: fixture.now)
                XCTAssertEqual(snapshot.tokenEvents, baseline.tokenEvents)
                XCTAssertEqual(snapshot.costEvents, baseline.costEvents)
                XCTAssertEqual(snapshot.activityEvents, baseline.activityEvents)
            }
            let usage = try await descriptor.reader.readUsage(from: fixture.start, to: fixture.end)
            assertDatedUsage(usage, equals: original)
        }
        XCTAssertEqual(try Data(contentsOf: keyURL), originalKey)
    }
}

final class HermesExplicitDefaultRetargetTests: XCTestCase {
    func test_liveAliasRetargetKeepsDefaultAndUnrelatedHistoryIsolatedInBothScopes() async throws {
        let fixture = try HermesM1Fixture()
        defer { fixture.remove() }
        try fixture.createDatabase(at: fixture.database())
        try fixture.insert(at: fixture.database(), tokens: 13, model: "default-model")
        let unrelatedHome = fixture.root.appendingPathComponent("unrelated")
        let unrelatedDatabase = unrelatedHome.appendingPathComponent("state.db")
        try fixture.createDatabase(at: unrelatedDatabase)
        try fixture.insert(at: unrelatedDatabase, tokens: 31, model: "unrelated-model")
        let alias = fixture.root.appendingPathComponent("selected-home")
        let configuration = try fixture.configuration()

        let selections: [(LocalUsageCacheScope, Bool)] = [
            (.application, false), (.agent, false), (.application, true), (.agent, true),
        ]
        for (scope, databaseAlias) in selections {
            let original = try await datedLegacyUsage(fixture, scope: scope)
            try await fixture.seedLedger(at: fixture.ledgerURL(for: unrelatedDatabase, scope: scope))
            let unrelatedDescriptor = try explicitDescriptor(fixture, home: unrelatedHome, scope: scope)
            let unrelated = try await unrelatedDescriptor.reader.readUsage(from: fixture.start, to: fixture.end)
            XCTAssertEqual(unrelated.totalTokens, 45)
            XCTAssertEqual(Set(unrelated.perModel.keys), ["unrelated-model"])
            let link = databaseAlias ? alias.appendingPathComponent("state.db") : alias
            if databaseAlias {
                try FileManager.default.createDirectory(at: alias, withIntermediateDirectories: true)
            }
            try FileManager.default.createSymbolicLink(
                at: link, withDestinationURL: databaseAlias ? fixture.database() : fixture.hermesHome)
            let descriptor = try explicitDescriptor(fixture, home: alias, scope: scope)
            let builder = AgentSnapshotBuilder(
                home: fixture.home, environment: fixture.environment, readerDescriptors: [descriptor])
            let originalSnapshot = try await builder.build(configuration: configuration, now: fixture.now)

            for selectedHome in [unrelatedHome, fixture.hermesHome, unrelatedHome, fixture.hermesHome] {
                try FileManager.default.removeItem(at: link)
                try FileManager.default.createSymbolicLink(
                    at: link,
                    withDestinationURL: databaseAlias ? selectedHome.appendingPathComponent("state.db") : selectedHome)
                let expected = selectedHome == fixture.hermesHome ? original : unrelated
                let restarted = try explicitDescriptor(fixture, home: alias, scope: scope)
                for reader in [descriptor.reader, restarted.reader] {
                    let usage = try await reader.readUsage(from: fixture.start, to: fixture.end)
                    assertDatedUsage(usage, equals: expected)
                }
                let snapshot = try await builder.build(configuration: configuration, now: fixture.now)
                XCTAssertEqual(snapshot.tokenEvents.map(\.totalTokens), [expected.totalTokens])
                if selectedHome == fixture.hermesHome {
                    XCTAssertEqual(snapshot.tokenEvents, originalSnapshot.tokenEvents)
                    XCTAssertEqual(snapshot.activityEvents, originalSnapshot.activityEvents)
                } else {
                    XCTAssertNotEqual(snapshot.activityEvents, originalSnapshot.activityEvents)
                }
            }
            try FileManager.default.removeItem(at: alias)
        }
    }

    func test_capturedDefaultOwnershipSurvivesRetargetBeforeLedgerSelection() async throws {
        let fixture = try HermesM1Fixture()
        defer { fixture.remove() }
        try fixture.createDatabase(at: fixture.database())
        try fixture.insert(at: fixture.database(), tokens: 13)
        _ = try await datedLegacyUsage(fixture, scope: .application)
        let unrelatedHome = fixture.root.appendingPathComponent("unrelated")
        let unrelatedDatabase = unrelatedHome.appendingPathComponent("state.db")
        try fixture.createDatabase(at: unrelatedDatabase)
        try fixture.insert(at: unrelatedDatabase, tokens: 31)
        try await fixture.seedLedger(at: fixture.ledgerURL(for: unrelatedDatabase))
        _ = try await fixture.registryReader(at: unrelatedHome).readUsage(from: fixture.start, to: fixture.end)
        let alias = fixture.root.appendingPathComponent("selected-home")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: fixture.hermesHome)
        let store = HermesProfileLedgerStore(
            defaultLedger: HermesUsageLedger(fileURL: fixture.ledgerURL()), includesDefaultLedger: true,
            directory: fixture.ledgerDirectory(), hermesHome: alias, includesProfiles: false,
            legacyDefaultDatabaseURL: fixture.database())

        let defaultCollection = try store.discoverCollection()
        try FileManager.default.removeItem(at: alias)
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: unrelatedHome)
        try await assertCapturedUsage(store, collection: defaultCollection, fixture: fixture, totalTokens: 27)
        let defaultHistory = try await store.historyStatus(collection: defaultCollection)
        XCTAssertEqual(defaultHistory.profiles.map(\.isDefault), [true])
        XCTAssertTrue(try store.sourceLocations(collection: defaultCollection)
            .contains(.file(fixture.ledgerURL(), includesSQLiteSidecars: false)))

        let unrelatedCollection = try store.discoverCollection()
        try FileManager.default.removeItem(at: alias)
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: fixture.hermesHome)
        try await assertCapturedUsage(store, collection: unrelatedCollection, fixture: fixture, totalTokens: 45)
        let unrelatedHistory = try await store.historyStatus(collection: unrelatedCollection)
        XCTAssertEqual(unrelatedHistory.profiles.map(\.isDefault), [false])
        XCTAssertFalse(try store.sourceLocations(collection: unrelatedCollection)
            .contains(.file(fixture.ledgerURL(), includesSQLiteSidecars: false)))
    }
}

private func assertCapturedUsage(
    _ store: HermesProfileLedgerStore,
    collection: HermesProfileCollection,
    fixture: HermesM1Fixture,
    totalTokens: Int) async throws {
    let ledgers = try await store.selectedLedgers(collection: collection)
    var events: [HermesUsageLedgerEvent] = []
    for ledger in ledgers {
        try await events.append(contentsOf: ledger.events(from: fixture.start, to: fixture.end))
    }
    XCTAssertEqual(events.map(\.counters.totalTokens), [totalTokens])
    XCTAssertEqual(events.map(\.cost), [0.25])
}

private func explicitDescriptor(
    _ fixture: HermesM1Fixture,
    home: URL,
    scope: LocalUsageCacheScope) throws -> LocalUsageReaderDescriptor {
    var environment = fixture.environment
    environment["HERMES_HOME"] = home.path
    return try XCTUnwrap(LocalUsageReaderRegistry.descriptors(
        home: fixture.home, environment: environment, cacheScope: scope)
        .first { $0.name == HermesReader.sourceName })
}

private func datedLegacyUsage(_ fixture: HermesM1Fixture, scope: LocalUsageCacheScope) async throws -> RawTokenUsage {
    let ledgerURL = fixture.ledgerURL(scope: scope)
    try await fixture.seedLedger(at: ledgerURL)
    return try await HermesReader(
        dbPathOverride: fixture.database().path,
        usageLedger: HermesUsageLedger(fileURL: ledgerURL), now: { fixture.now })
        .readUsage(from: fixture.start, to: fixture.end)
}

private func defaultHomeSelections(_ fixture: HermesM1Fixture) throws -> [URL] {
    let alias = fixture.root.appendingPathComponent("default-alias")
    try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: fixture.hermesHome)
    let databaseAliasHome = fixture.root.appendingPathComponent("database-alias")
    try FileManager.default.createDirectory(at: databaseAliasHome, withIntermediateDirectories: true)
    try FileManager.default.createSymbolicLink(
        at: databaseAliasHome.appendingPathComponent("state.db"), withDestinationURL: fixture.database())
    return [fixture.hermesHome, alias, databaseAliasHome]
}

private func registerNamedHistory(_ fixture: HermesM1Fixture, scope: LocalUsageCacheScope) async throws {
    let named = fixture.database("named")
    try fixture.createDatabase(at: named)
    try fixture.insert(at: named, tokens: 29, model: "named-model")
    try await fixture.seedLedger(at: fixture.ledgerURL(for: named, scope: scope))
    let descriptor = try XCTUnwrap(LocalUsageReaderRegistry.descriptors(
        home: fixture.home, environment: fixture.environment, cacheScope: scope)
        .first { $0.name == HermesReader.sourceName })
    let usage = try await descriptor.reader.readUsage(from: fixture.start, to: fixture.end)
    XCTAssertEqual(usage.inputTokens, 42)
    // Explicit default selection must exclude both discovered and retained named history.
    try FileManager.default.removeItem(at: named.deletingLastPathComponent())
}

private func assertDatedUsage(
    _ actual: RawTokenUsage,
    equals expected: RawTokenUsage,
    file: StaticString = #filePath,
    line: UInt = #line) {
    XCTAssertEqual(actual.tokenEvents, expected.tokenEvents, file: file, line: line)
    XCTAssertEqual(actual.totalTokens, expected.totalTokens, file: file, line: line)
    XCTAssertEqual(actual.cost, expected.cost, accuracy: 0.000_001, file: file, line: line)
    XCTAssertEqual(
        actual.perModel.mapValues(\.totalTokens),
        expected.perModel.mapValues(\.totalTokens),
        file: file,
        line: line)
    XCTAssertEqual(actual.workTime, expected.workTime, file: file, line: line)
}
