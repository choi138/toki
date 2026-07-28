import Foundation
import TokiSyncProtocol
import XCTest
@testable import TokiUsageReaders

final class HermesUnboundLedgerMigrationTests: XCTestCase {
    func test_explicitMigrationBindsSidecarAndPreservesAccounting() async throws {
        let fixture = try UnboundLedgerFixture()
        defer { fixture.remove() }
        let identifierKey = SnapshotCipher.generateKey()
        let identifier = String(repeating: "a", count: 32)
        let timestamp = Date(timeIntervalSince1970: 1_780_000_000)
        let original = try unboundLedgerData(
            identifierKey: identifierKey,
            identifier: identifier,
            timestamp: timestamp)
        let originalDocument = try JSONDecoder().decode(
            HermesUsageLedgerUnboundPrivateDocument.self,
            from: original)
        try fixture.writeLedger(original, identifierKey: identifierKey)

        do {
            _ = try await HermesUsageLedger(fileURL: fixture.ledgerURL).status()
            XCTFail("An unbound schema-3 ledger must require migration")
        } catch HermesUsageLedgerError.migrationRequired {}

        XCTAssertEqual(
            try HermesUsageLedgerMigrator.migrate(fileURL: fixture.ledgerURL),
            .migrationRequired)
        XCTAssertEqual(try Data(contentsOf: fixture.ledgerURL), original)
        XCTAssertEqual(
            try HermesUsageLedgerMigrator.migrate(fileURL: fixture.ledgerURL, mode: .apply),
            .migrated)

        let migratedData = try Data(contentsOf: fixture.ledgerURL)
        let migrated = try JSONDecoder().decode(HermesUsageLedgerPrivateDocument.self, from: migratedData)
        XCTAssertEqual(migrated.schemaVersion, originalDocument.schemaVersion)
        XCTAssertEqual(migrated.accurateSince, originalDocument.accurateSince)
        XCTAssertEqual(migrated.lastSuccessfulObservationAt, originalDocument.lastSuccessfulObservationAt)
        XCTAssertEqual(migrated.baselines, originalDocument.baselines)
        XCTAssertEqual(migrated.unattributed, originalDocument.unattributed)
        XCTAssertEqual(migrated.events, originalDocument.events)
        _ = try migrated.document(identifierKey: identifierKey)
        XCTAssertEqual(try Data(contentsOf: fixture.keyURL), Data(identifierKey.utf8))
        XCTAssertEqual(
            try HermesUsageLedgerMigrator.migrate(fileURL: fixture.ledgerURL, mode: .apply),
            .notRequired)

        let ledger = HermesUsageLedger(fileURL: fixture.ledgerURL)
        let events = try await ledger.events(
            from: timestamp.addingTimeInterval(-1),
            to: timestamp.addingTimeInterval(1))
        XCTAssertEqual(events.map(\.counters.totalTokens), [16])
    }

    func test_automaticMigrationBindsUnboundLedger() async throws {
        let fixture = try UnboundLedgerFixture()
        defer { fixture.remove() }
        let identifierKey = SnapshotCipher.generateKey()
        let timestamp = Date(timeIntervalSince1970: 1_780_000_000)
        try fixture.writeLedger(
            unboundLedgerData(
                identifierKey: identifierKey,
                identifier: String(repeating: "b", count: 32),
                timestamp: timestamp),
            identifierKey: identifierKey)
        let ledger = HermesUsageLedger(
            fileURL: fixture.ledgerURL,
            automaticallyMigrateLegacy: true)

        let status = try await ledger.status()

        XCTAssertEqual(status.accurateSince, timestamp)
        let migratedData = try Data(contentsOf: fixture.ledgerURL)
        XCTAssertTrue(
            try JSONDecoder().decode(
                HermesUsageLedgerPrivateBindingProbe.self,
                from: migratedData).hasKeyFingerprint)
        _ = try JSONDecoder().decode(HermesUsageLedgerPrivateDocument.self, from: migratedData)
    }

    func test_boundLedgerWithMismatchedKeyIsNotRepaired() throws {
        let fixture = try UnboundLedgerFixture()
        defer { fixture.remove() }
        let identifierKey = SnapshotCipher.generateKey()
        let timestamp = Date(timeIntervalSince1970: 1_780_000_000)
        try fixture.writeLedger(
            boundLedgerData(
                identifierKey: identifierKey,
                identifier: String(repeating: "c", count: 32),
                timestamp: timestamp),
            identifierKey: SnapshotCipher.generateKey())
        let original = try Data(contentsOf: fixture.ledgerURL)

        do {
            _ = try HermesUsageLedgerMigrator.migrate(fileURL: fixture.ledgerURL, mode: .apply)
            XCTFail("A bound ledger with a mismatched key must not be repaired")
        } catch HermesUsageLedgerError.invalidLedger {}
        XCTAssertEqual(try Data(contentsOf: fixture.ledgerURL), original)
    }
}

private struct UnboundLedgerFixture {
    let directory: URL
    let ledgerURL: URL
    let keyURL: URL

    init() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("toki-unbound-ledger-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        ledgerURL = directory.appendingPathComponent("hermes-usage-ledger.json")
        keyURL = hermesUsageLedgerIdentifierKeyURL(for: ledgerURL)
    }

    func writeLedger(_ data: Data, identifierKey: String) throws {
        try writePrivate(data, to: ledgerURL)
        try writePrivate(Data(identifierKey.utf8), to: keyURL)
    }

    func remove() {
        try? FileManager.default.removeItem(at: directory)
    }
}

private func unboundLedgerData(
    identifierKey: String,
    identifier: String,
    timestamp: Date) throws -> Data {
    var object = try XCTUnwrap(
        JSONSerialization.jsonObject(with: boundLedgerData(
            identifierKey: identifierKey,
            identifier: identifier,
            timestamp: timestamp)) as? [String: Any])
    object.removeValue(forKey: "keyFingerprint")
    return try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
}

private func boundLedgerData(
    identifierKey: String,
    identifier: String,
    timestamp: Date) throws -> Data {
    let counters = HermesTokenCounters(
        inputTokens: 10,
        outputTokens: 2,
        cacheReadTokens: 3,
        cacheWriteTokens: 0,
        reasoningTokens: 1)
    let baseline = HermesUsageLedgerBaseline(
        startedAt: timestamp,
        lastActivityAt: timestamp,
        lastObservedAt: timestamp,
        model: "gpt-test",
        counters: counters,
        cost: 0.25,
        projectName: nil,
        attributionQuality: .exact)
    let event = HermesUsageLedgerEvent(
        sessionIdentifier: identifier,
        timestamp: timestamp,
        model: "gpt-test",
        counters: counters,
        cost: 0.25,
        projectName: nil,
        attributionQuality: .exact)
    let document = HermesUsageLedgerDocument(
        schemaVersion: hermesUsageLedgerSchemaVersion,
        identifierKey: identifierKey,
        accurateSince: timestamp,
        lastSuccessfulObservationAt: timestamp,
        baselines: [identifier: baseline],
        unattributed: [:],
        events: [event])
    return try JSONEncoder().encode(HermesUsageLedgerPrivateDocument(document))
}

private func writePrivate(_ data: Data, to url: URL) throws {
    try data.write(to: url)
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
}
