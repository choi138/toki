import Foundation
import TokiSyncProtocol
import XCTest
@testable import TokiAgentCore
@testable import TokiUsageReaders

final class AgentHermesLedgerSyncTests: XCTestCase {
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
