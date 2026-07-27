import Foundation
import TokiDurableStorage
import TokiSyncProtocol
import XCTest
@testable import TokiAgentCore
@testable import TokiUsageReaders

final class HermesLedgerMigrationTests: XCTestCase {
    func test_migrationRequiredRemedyIncludesApplyFlag() {
        XCTAssertTrue(
            HermesUsageLedgerError.migrationRequired.localizedDescription
                .contains("toki-agent migrate-hermes-ledger --apply"))
    }

    func test_automaticMigrationReloadsWhenAnotherMigratorWinsRace() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("toki-hermes-migration-race-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try DurableFileIO.preparePrivateDirectory(directory)
        let ledgerURL = directory.appendingPathComponent("hermes-usage-ledger.json")
        let legacy = HermesUsageLedgerDocument(
            schemaVersion: hermesUsageLedgerPreviousSchemaVersion,
            identifierKey: SnapshotCipher.generateKey(),
            accurateSince: nil,
            lastSuccessfulObservationAt: nil,
            baselines: [:],
            unattributed: [:],
            events: [])
        try DurableFileIO.writePrivate(JSONEncoder().encode(legacy), to: ledgerURL)
        let ledger = HermesUsageLedger(
            fileURL: ledgerURL,
            automaticallyMigrateLegacy: true,
            privateFileWriter: { data, url in
                try DurableFileIO.writePrivate(data, to: url)
            },
            legacyMigrationHandler: { fileURL, mode in
                XCTAssertEqual(
                    try HermesUsageLedgerMigrator.migrate(fileURL: fileURL, mode: mode),
                    .migrated)
                return .notRequired
            })

        let status = try await ledger.status()

        XCTAssertNil(status.accurateSince)
        let migrated = try JSONDecoder().decode(
            HermesUsageLedgerPrivateDocument.self,
            from: Data(contentsOf: ledgerURL))
        XCTAssertEqual(migrated.schemaVersion, hermesUsageLedgerSchemaVersion)
    }

    func test_migrationIgnoresOverlappingTemporaryFilename() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("toki-hermes-migration-name-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try DurableFileIO.preparePrivateDirectory(directory)
        let ledgerURL = directory.appendingPathComponent("hermes-usage-ledger.json")
        let overlappingURL = directory.appendingPathComponent(".hermes-usage-ledger.json.tmp")
        let legacy = HermesUsageLedgerDocument(
            schemaVersion: hermesUsageLedgerPreviousSchemaVersion,
            identifierKey: SnapshotCipher.generateKey(),
            accurateSince: nil,
            lastSuccessfulObservationAt: nil,
            baselines: [:],
            unattributed: [:],
            events: [])
        try DurableFileIO.writePrivate(JSONEncoder().encode(legacy), to: ledgerURL)
        try DurableFileIO.writePrivate(Data("not-a-ledger".utf8), to: overlappingURL)

        XCTAssertEqual(
            try HermesUsageLedgerMigrator.migrate(fileURL: ledgerURL, mode: .apply),
            .migrated)
        XCTAssertTrue(FileManager.default.fileExists(atPath: overlappingURL.path))
    }

    func test_currentLedgerMapsUnreadableIdentifierKeyToInvalidLedger() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("toki-hermes-key-error-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try DurableFileIO.preparePrivateDirectory(directory)
        let ledgerURL = directory.appendingPathComponent("hermes-usage-ledger.json")
        let legacy = HermesUsageLedgerDocument(
            schemaVersion: hermesUsageLedgerPreviousSchemaVersion,
            identifierKey: SnapshotCipher.generateKey(),
            accurateSince: nil,
            lastSuccessfulObservationAt: nil,
            baselines: [:],
            unattributed: [:],
            events: [])
        try DurableFileIO.writePrivate(JSONEncoder().encode(legacy), to: ledgerURL)
        XCTAssertEqual(
            try HermesUsageLedgerMigrator.migrate(fileURL: ledgerURL, mode: .apply),
            .migrated)
        let keyURL = hermesUsageLedgerIdentifierKeyURL(for: ledgerURL)
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: keyURL.path)

        do {
            _ = try await HermesUsageLedger(fileURL: ledgerURL).status()
            XCTFail("An unreadable identifier key must fail as an invalid Hermes ledger")
        } catch HermesUsageLedgerError.invalidLedger {
            // Expected public error mapping.
        } catch {
            XCTFail("Unexpected error: \(type(of: error))")
        }
    }

    func test_applyRemovesLegacyArtifactsWhenPrimaryLedgerIsMissing() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("toki-hermes-orphan-artifacts-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try DurableFileIO.preparePrivateDirectory(directory)
        let ledgerURL = directory.appendingPathComponent("hermes-usage-ledger.json")
        let backupURL = ledgerURL.appendingPathExtension("v2.backup")
        let temporaryURL = directory.appendingPathComponent(
            ".\(ledgerURL.lastPathComponent).\(UUID().uuidString).tmp")
        let legacy = HermesUsageLedgerDocument(
            schemaVersion: hermesUsageLedgerPreviousSchemaVersion,
            identifierKey: SnapshotCipher.generateKey(),
            accurateSince: nil,
            lastSuccessfulObservationAt: nil,
            baselines: [:],
            unattributed: [:],
            events: [])
        let legacyData = try JSONEncoder().encode(legacy)
        try DurableFileIO.writePrivate(legacyData, to: backupURL)
        try DurableFileIO.writePrivate(legacyData, to: temporaryURL)

        XCTAssertEqual(
            try HermesUsageLedgerMigrator.migrate(fileURL: ledgerURL, mode: .apply),
            .noLedger)
        XCTAssertFalse(FileManager.default.fileExists(atPath: backupURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: temporaryURL.path))
    }

    func test_agentMigrationDryRunDoesNotCreateDirectoriesOrLockFile() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("toki-hermes-dry-run-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = AgentPaths(
            environment: [
                "XDG_CONFIG_HOME": root.appendingPathComponent("config").path,
                "XDG_STATE_HOME": root.appendingPathComponent("state").path,
                "XDG_DATA_HOME": root.appendingPathComponent("data").path,
            ],
            home: root)

        XCTAssertEqual(try TokiAgentCommand.migrateHermesLedger(arguments: [], paths: paths), .noLedger)
        XCTAssertFalse(FileManager.default.fileExists(atPath: paths.configurationDirectory.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: paths.stateDirectory.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: paths.dataDirectory.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: paths.lockURL.path))
    }
}
