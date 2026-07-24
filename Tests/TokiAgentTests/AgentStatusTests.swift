import Foundation
import TokiSyncProtocol
import XCTest
@testable import TokiAgentCore
@testable import TokiUsageReaders

final class AgentStatusTests: XCTestCase {
    func test_statusLinesShowVerificationStateWithoutSensitiveIdentifiers() throws {
        let configuration = try AgentConfiguration(bundle: AgentPairingBundle(
            hubURL: XCTUnwrap(URL(string: "https://private-hub.example.test")),
            deviceID: "private-device-uuid",
            deviceName: "ubuntu-worker",
            uploadToken: SnapshotCipher.randomToken(),
            encryptionKey: SnapshotCipher.generateKey()))
        let digest = SnapshotCipher.digest("snapshot")
        let signature = SnapshotCipher.digest("source")
        let pendingState = AgentRuntimeState(
            latestSequence: 7,
            lastError: "private log content",
            lastUploadedContentDigest: digest)
        let stableState = AgentRuntimeState(
            latestSequence: 7,
            lastUploadedContentDigest: digest,
            lastSourceSignature: signature)

        let pendingOutput = TokiAgentCommand.statusLines(
            configuration: configuration,
            state: pendingState,
            pendingCount: 1).joined(separator: "\n")
        let stableOutput = TokiAgentCommand.statusLines(
            configuration: configuration,
            state: stableState,
            pendingCount: 0,
            hermesStatus: HermesUsageLedgerStatus(
                accurateSince: Date(timeIntervalSince1970: 1_784_200_000),
                unattributedSessionCount: 2,
                unattributedTokens: 1234),
            hermesCoverage: HermesUsageCoverageStatus(
                unmeteredMainAPICallCount: 3)).joined(separator: "\n")

        XCTAssertTrue(pendingOutput.contains("Latest sequence: 7"))
        XCTAssertTrue(pendingOutput.contains("Snapshot verification: pending"))
        XCTAssertTrue(pendingOutput.contains("Last error: present"))
        XCTAssertTrue(stableOutput.contains("Snapshot verification: stable"))
        XCTAssertTrue(stableOutput.contains("Hermes accurate since:"))
        XCTAssertTrue(stableOutput.contains("Hermes unattributed: 2 sessions, 1234 tokens"))
        XCTAssertTrue(stableOutput.contains("Hermes unmetered main calls: 3"))
        var sensitiveValues = [
            configuration.deviceID,
            configuration.hubURL.absoluteString,
            configuration.uploadToken,
            configuration.encryptionKey,
        ]
        sensitiveValues.append(contentsOf: [configuration.hubURL.host, pendingState.lastError].compactMap { $0 })
        for sensitiveValue in sensitiveValues {
            XCTAssertFalse(pendingOutput.contains(sensitiveValue))
            XCTAssertFalse(stableOutput.contains(sensitiveValue))
        }
    }
}
