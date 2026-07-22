import Foundation
import XCTest
@testable import TokiSyncProtocol

final class SnapshotCipherTests: XCTestCase {
    func test_sealAndOpenRoundTrip() throws {
        let key = SnapshotCipher.generateKey()
        let snapshot = makeSnapshot()

        let envelope = try SnapshotCipher.seal(snapshot, sequence: 42, key: key)
        let decoded = try SnapshotCipher.open(envelope, key: key)

        XCTAssertEqual(decoded, snapshot)
        XCTAssertEqual(envelope.deviceID, snapshot.device.id)
        XCTAssertEqual(envelope.sequence, 42)
        XCTAssertLessThanOrEqual(
            try TokiSyncCoding.makeEncoder().encode(envelope).count,
            TokiSyncLimits.maximumEnvelopeBytes)
    }

    func test_tamperedMetadataFailsAuthentication() throws {
        let key = SnapshotCipher.generateKey()
        let envelope = try SnapshotCipher.seal(makeSnapshot(), sequence: 3, key: key)
        let tampered = EncryptedUsageEnvelope(
            deviceID: envelope.deviceID,
            sequence: 4,
            generatedAt: envelope.generatedAt,
            payload: envelope.payload)

        XCTAssertThrowsError(try SnapshotCipher.open(tampered, key: key))
    }

    func test_outOfRangeEnvelopeTimestampFailsWithoutIntegerConversionTrap() {
        let envelope = EncryptedUsageEnvelope(
            deviceID: "device-1",
            sequence: 1,
            generatedAt: Date(timeIntervalSince1970: Double.greatestFiniteMagnitude),
            payload: Data(repeating: 0, count: 32).base64EncodedString())

        XCTAssertThrowsError(try SnapshotCipher.open(envelope, key: SnapshotCipher.generateKey()))
    }

    func test_envelopeSizeValidationIncludesEncodedMetadata() {
        let envelope = EncryptedUsageEnvelope(
            deviceID: "device-1",
            sequence: 1,
            generatedAt: Date(timeIntervalSince1970: 1_750_000_000),
            payload: String(repeating: "A", count: TokiSyncLimits.maximumEnvelopeBytes))

        XCTAssertThrowsError(try SnapshotCipher.validateEnvelopeSize(envelope)) { error in
            guard let cipherError = error as? SnapshotCipherError,
                  case .payloadTooLarge = cipherError else {
                return XCTFail("Expected payloadTooLarge, got \(error)")
            }
        }
    }

    func test_pairingBundleRoundTrip() throws {
        let bundle = try AgentPairingBundle(
            hubURL: XCTUnwrap(URL(string: "https://hub.example.test")),
            deviceID: "device-1",
            deviceName: "ubuntu",
            uploadToken: "upload-token",
            encryptionKey: SnapshotCipher.generateKey())

        let encoded = try TokiSyncCoding.encodeBundle(bundle)
        let decoded = try TokiSyncCoding.decodeBundle(AgentPairingBundle.self, from: encoded)

        XCTAssertEqual(decoded, bundle)
    }

    func test_opaqueIdentifierHasherIsStableAndKeyScoped() throws {
        let firstKey = SnapshotCipher.generateKey()
        let secondKey = SnapshotCipher.generateKey()
        let hasher = try SnapshotCipher.makeOpaqueIdentifierHasher(key: firstKey)

        let identifier = hasher.identifier(for: "/private/session/path")

        XCTAssertEqual(identifier.count, 32)
        XCTAssertEqual(identifier, hasher.identifier(for: "/private/session/path"))
        XCTAssertEqual(
            identifier,
            try SnapshotCipher.opaqueIdentifier(for: "/private/session/path", key: firstKey))
        XCTAssertNotEqual(identifier, hasher.identifier(for: "/private/other/path"))
        XCTAssertNotEqual(
            identifier,
            try SnapshotCipher.opaqueIdentifier(for: "/private/session/path", key: secondKey))
        XCTAssertFalse(identifier.contains("session"))
    }

    private func makeSnapshot() -> RemoteUsageSnapshot {
        let generatedAt = Date(timeIntervalSince1970: 1_750_000_000)
        return RemoteUsageSnapshot(
            device: RemoteDeviceDescriptor(id: "device-1", name: "ubuntu", platform: "linux"),
            generatedAt: generatedAt,
            coveredFrom: generatedAt.addingTimeInterval(-3600),
            coveredTo: generatedAt.addingTimeInterval(1),
            tokenEvents: [
                RemoteTokenEvent(
                    timestamp: generatedAt.addingTimeInterval(-60),
                    source: "Codex",
                    model: "gpt-test",
                    inputTokens: 10,
                    outputTokens: 3,
                    cacheReadTokens: 2,
                    cacheWriteTokens: 0,
                    reasoningTokens: 1),
            ],
            activityEvents: [
                RemoteActivityEvent(
                    timestamp: generatedAt.addingTimeInterval(-60),
                    source: "Codex",
                    model: "gpt-test",
                    streamID: "opaque-stream",
                    agentKind: .main),
            ])
    }
}
