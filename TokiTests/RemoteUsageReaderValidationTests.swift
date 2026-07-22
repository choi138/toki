import Foundation
import TokiSyncProtocol
import XCTest
@testable import Toki

extension RemoteUsageReaderTests {
    func test_snapshotProgressRejectsConflictingSnapshotsForSameDeviceSequence() throws {
        let fixture = try makeFixture()
        let conflicting = EncryptedUsageEnvelope(
            deviceID: fixture.envelope.deviceID,
            sequence: fixture.envelope.sequence,
            generatedAt: fixture.envelope.generatedAt,
            payload: Data(repeating: 1, count: 32).base64EncodedString())

        XCTAssertThrowsError(try RemoteSnapshotProgress.validated([fixture.envelope, conflicting])) { error in
            guard let readerError = error as? RemoteUsageReaderError,
                  case .conflictingSnapshots = readerError else {
                return XCTFail("Expected conflictingSnapshots, got \(error)")
            }
        }
    }

    func test_remoteReaderRejectsAuthenticatedSnapshotRollback() async throws {
        let fixture = try makeFixture()
        let snapshot = try SnapshotCipher.open(fixture.envelope, key: fixture.encryptionKey)
        let newerEnvelope = try SnapshotCipher.seal(snapshot, sequence: 2, key: fixture.encryptionKey)
        let anchorStore = InMemoryRemoteSnapshotAnchorStore(envelopes: [newerEnvelope])
        let reader = fixture.makeReader(
            client: fixture.makeClient(),
            anchorStore: anchorStore)

        do {
            _ = try await reader.readUsage(from: fixture.start, to: fixture.end)
            XCTFail("Expected an authenticated rollback to fail")
        } catch let error as RemoteUsageReaderError {
            guard case .staleSnapshot = error else {
                return XCTFail("Expected staleSnapshot, got \(error)")
            }
        }
    }

    func test_remoteReaderRejectsDifferentAuthenticatedEnvelopeAtAnchoredSequence() async throws {
        let fixture = try makeFixture()
        let snapshot = try SnapshotCipher.open(fixture.envelope, key: fixture.encryptionKey)
        let resealedEnvelope = try SnapshotCipher.seal(snapshot, sequence: 1, key: fixture.encryptionKey)
        XCTAssertNotEqual(resealedEnvelope.payload, fixture.envelope.payload)
        let anchorStore = InMemoryRemoteSnapshotAnchorStore(envelopes: [fixture.envelope])
        let client = fixture.makeClient(envelopes: [resealedEnvelope])
        let reader = fixture.makeReader(client: client, anchorStore: anchorStore)

        do {
            _ = try await reader.readUsage(from: fixture.start, to: fixture.end)
            XCTFail("Expected a sequence conflict to fail")
        } catch let error as RemoteUsageReaderError {
            guard case .conflictingSnapshots = error else {
                return XCTFail("Expected conflictingSnapshots, got \(error)")
            }
        }
    }
}
