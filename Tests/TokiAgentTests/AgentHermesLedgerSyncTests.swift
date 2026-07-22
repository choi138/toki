import Foundation
import TokiDurableStorage
import TokiSyncProtocol
import XCTest
@testable import TokiAgentCore
@testable import TokiUsageReaders

final class AgentHermesLedgerSyncTests: XCTestCase {
    func test_pendingUploadFailureStillMigratesLegacyHermesLedger() async throws {
        let fixture = try AgentSyncFixture()
        defer { fixture.remove() }
        let now = Date(timeIntervalSince1970: 1_780_000_000)
        let environment = [
            "XDG_CONFIG_HOME": fixture.root.appendingPathComponent("config").path,
            "XDG_STATE_HOME": fixture.root.appendingPathComponent("state").path,
            "XDG_DATA_HOME": fixture.root.appendingPathComponent("data").path,
        ]
        try AgentConfigurationStore(paths: fixture.paths).save(fixture.configuration)
        let pendingBuilder = AgentSnapshotBuilder(home: fixture.root, readerDescriptors: [])
        let pendingSnapshot = try await pendingBuilder.build(configuration: fixture.configuration, now: now)
        _ = try AgentSpool(paths: fixture.paths).enqueue(SnapshotCipher.seal(
            pendingSnapshot,
            sequence: 1,
            key: fixture.configuration.encryptionKey))
        let identifierKey = SnapshotCipher.generateKey()
        let ledgerURL = hermesUsageLedgerURL(
            paths: LocalUsageReaderPaths(homeDirectory: fixture.root, environment: environment),
            scope: .agent)
        let legacy = HermesUsageLedgerDocument(
            schemaVersion: hermesUsageLedgerPreviousSchemaVersion,
            identifierKey: identifierKey,
            accurateSince: now,
            lastSuccessfulObservationAt: now,
            baselines: [:],
            unattributed: [:],
            events: [])
        try DurableFileIO.writePrivate(JSONEncoder().encode(legacy), to: ledgerURL)
        let service = AgentSyncService(
            paths: fixture.paths,
            hubClient: FailFirstUploadAgentHubClient(),
            snapshotBuilder: AgentSnapshotBuilder(home: fixture.root, environment: environment))

        do {
            try await service.syncOnce(now: now)
            XCTFail("Expected the pending upload to fail")
        } catch AgentSyncTestError.uploadFailed {}

        let migrated = try JSONDecoder().decode(
            HermesUsageLedgerPrivateDocument.self,
            from: Data(contentsOf: ledgerURL))
        XCTAssertEqual(migrated.schemaVersion, hermesUsageLedgerSchemaVersion)
        XCTAssertEqual(
            try Data(contentsOf: hermesUsageLedgerIdentifierKeyURL(for: ledgerURL)),
            Data(identifierKey.utf8))
    }

    func test_uploadFailurePreservesHermesLedgerIncrementAcrossServiceRestart() async throws {
        let fixture = try AgentSyncFixture()
        defer { fixture.remove() }
        try AgentConfigurationStore(paths: fixture.paths).save(fixture.configuration)
        let now = Date(timeIntervalSince1970: 1_780_000_000)
        let startedAt = now.addingTimeInterval(-3600)
        let ledgerURL = fixture.paths.stateDirectory.appendingPathComponent("hermes-usage-ledger.json")
        let firstLedger = HermesUsageLedger(fileURL: ledgerURL)
        try await firstLedger.refresh(
            observations: [],
            observedAt: now.addingTimeInterval(-7200))
        try await firstLedger.refresh(
            observations: [hermesSyncObservation(
                startedAt: startedAt,
                latestActivityAt: now.addingTimeInterval(-120),
                inputTokens: 100)],
            observedAt: now.addingTimeInterval(-60))
        let hubClient = FailFirstUploadAgentHubClient()
        let firstBuilder = hermesLedgerSnapshotBuilder(
            fixture: fixture,
            ledger: firstLedger,
            ledgerURL: ledgerURL,
            now: now)
        let firstService = AgentSyncService(
            paths: fixture.paths,
            hubClient: hubClient,
            snapshotBuilder: firstBuilder)

        do {
            try await firstService.syncOnce(now: now)
            XCTFail("Expected the first upload to fail")
        } catch AgentSyncTestError.uploadFailed {}
        XCTAssertEqual(try AgentSpool(paths: fixture.paths).pendingEnvelopes().count, 1)

        try await firstLedger.refresh(
            observations: [hermesSyncObservation(
                startedAt: startedAt,
                latestActivityAt: now.addingTimeInterval(30),
                inputTokens: 150)],
            observedAt: now.addingTimeInterval(60))
        let restartedLedger = HermesUsageLedger(fileURL: ledgerURL)
        let restartedBuilder = hermesLedgerSnapshotBuilder(
            fixture: fixture,
            ledger: restartedLedger,
            ledgerURL: ledgerURL,
            now: now.addingTimeInterval(60))
        let restartedService = AgentSyncService(
            paths: fixture.paths,
            hubClient: hubClient,
            snapshotBuilder: restartedBuilder)

        try await restartedService.syncOnce(now: now.addingTimeInterval(60))
        try await restartedService.syncOnce(now: now.addingTimeInterval(60))

        XCTAssertEqual(hubClient.uploadAttempts, [1, 1, 2])
        XCTAssertEqual(hubClient.successfulUploads, [1, 2])
        XCTAssertEqual(hubClient.heartbeatSequences, [2])
        let snapshots = try hubClient.successfulEnvelopes.map {
            try SnapshotCipher.open($0, key: fixture.configuration.encryptionKey)
        }
        XCTAssertEqual(snapshots.map(remoteSnapshotTotalTokens), [100, 150])
        XCTAssertTrue(try AgentSpool(paths: fixture.paths).pendingEnvelopes().isEmpty)
    }
}
