import Foundation

#if canImport(CryptoKit)
    import CryptoKit
#elseif canImport(Crypto)
    @preconcurrency import Crypto
#else
    #error("TokiSyncProtocol requires CryptoKit or swift-crypto")
#endif

public enum SnapshotCipherError: LocalizedError {
    case invalidKey
    case invalidEnvelope
    case payloadTooLarge
    case unsupportedVersion(Int)
    case deviceMismatch
    case metadataMismatch

    public var errorDescription: String? {
        switch self {
        case .invalidKey:
            "The sync encryption key must contain exactly 32 bytes."
        case .invalidEnvelope:
            "The encrypted usage envelope is malformed or failed authentication."
        case .payloadTooLarge:
            "The encrypted snapshot exceeds the 8 MiB limit. Reduce retention or source volume."
        case let .unsupportedVersion(version):
            "Sync protocol version \(version) is not supported."
        case .deviceMismatch:
            "The encrypted snapshot does not belong to the envelope device."
        case .metadataMismatch:
            "The encrypted snapshot metadata does not match its envelope."
        }
    }
}

public enum SnapshotCipher {
    private static let derivationSalt = Data("toki-sync-key-derivation-v1".utf8)
    private static let encryptionKeyPurpose = Data("snapshot-encryption".utf8)
    private static let identifierKeyPurpose = Data("stream-identifier".utf8)

    public static func generateKey() -> String {
        let key = SymmetricKey(size: .bits256)
        return key.withUnsafeBytes { Data($0).base64EncodedString() }
    }

    public static func seal(
        _ snapshot: RemoteUsageSnapshot,
        sequence: UInt64,
        key encodedKey: String) throws -> EncryptedUsageEnvelope {
        guard sequence > 0 else {
            throw SnapshotCipherError.invalidEnvelope
        }
        try RemoteUsageSnapshotValidator.validate(snapshot)

        let key = try derivedKey(from: encodedKey, purpose: encryptionKeyPurpose)
        let generatedAt = try millisecondDate(snapshot.generatedAt)
        let envelopeMetadata = EncryptedUsageEnvelope(
            deviceID: snapshot.device.id,
            sequence: sequence,
            generatedAt: generatedAt,
            payload: "")
        let plaintext = try TokiSyncCoding.makeEncoder().encode(snapshot)
        let sealedBox = try AES.GCM.seal(
            plaintext,
            using: key,
            authenticating: associatedData(for: envelopeMetadata))
        guard let combined = sealedBox.combined else {
            throw SnapshotCipherError.invalidEnvelope
        }

        let envelope = EncryptedUsageEnvelope(
            deviceID: snapshot.device.id,
            sequence: sequence,
            generatedAt: generatedAt,
            payload: combined.base64EncodedString())
        try validateEnvelopeSize(envelope)
        return envelope
    }

    public static func open(
        _ envelope: EncryptedUsageEnvelope,
        key encodedKey: String) throws -> RemoteUsageSnapshot {
        guard envelope.schemaVersion == TokiSyncProtocolVersion.current else {
            throw SnapshotCipherError.unsupportedVersion(envelope.schemaVersion)
        }
        guard envelope.sequence > 0,
              TokiSyncValidation.isSafeDeviceID(envelope.deviceID),
              envelope.payload.utf8.count <= TokiSyncLimits.maximumEnvelopeBytes else {
            throw SnapshotCipherError.invalidEnvelope
        }
        guard let combined = Data(base64Encoded: envelope.payload) else {
            throw SnapshotCipherError.invalidEnvelope
        }

        do {
            let key = try derivedKey(from: encodedKey, purpose: encryptionKeyPurpose)
            let sealedBox = try AES.GCM.SealedBox(combined: combined)
            let plaintext = try AES.GCM.open(
                sealedBox,
                using: key,
                authenticating: associatedData(for: envelope))
            let snapshot = try TokiSyncCoding.makeDecoder().decode(RemoteUsageSnapshot.self, from: plaintext)
            guard snapshot.schemaVersion == TokiSyncProtocolVersion.current else {
                throw SnapshotCipherError.unsupportedVersion(snapshot.schemaVersion)
            }
            guard snapshot.device.id == envelope.deviceID else {
                throw SnapshotCipherError.deviceMismatch
            }
            guard abs(snapshot.generatedAt.timeIntervalSince(envelope.generatedAt)) < 0.001 else {
                throw SnapshotCipherError.metadataMismatch
            }
            try RemoteUsageSnapshotValidator.validate(snapshot)
            return snapshot
        } catch let error as SnapshotCipherError {
            throw error
        } catch {
            throw SnapshotCipherError.invalidEnvelope
        }
    }

    public static func opaqueIdentifier(for value: String, key encodedKey: String) throws -> String {
        try makeOpaqueIdentifierHasher(key: encodedKey).identifier(for: value)
    }

    public static func makeOpaqueIdentifierHasher(key encodedKey: String) throws -> SnapshotOpaqueIdentifierHasher {
        try SnapshotOpaqueIdentifierHasher(
            key: derivedKey(from: encodedKey, purpose: identifierKeyPurpose))
    }

    public static func randomToken() -> String {
        let key = SymmetricKey(size: .bits256)
        let data = key.withUnsafeBytes { Data($0) }
        return data.base64URLEncodedString()
    }

    public static func digest(_ value: String) -> String {
        digest(Data(value.utf8))
    }

    public static func digest(_ value: Data) -> String {
        Data(SHA256.hash(data: value)).map { String(format: "%02x", $0) }.joined()
    }

    public static func isSHA256Digest(_ value: String) -> Bool {
        guard value.count == 64 else { return false }
        let hexadecimal = CharacterSet(charactersIn: "0123456789abcdef")
        return value.unicodeScalars.allSatisfy(hexadecimal.contains)
    }

    public static func constantTimeEqual(_ lhs: String, _ rhs: String) -> Bool {
        let left = Array(lhs.utf8)
        let right = Array(rhs.utf8)
        guard left.count == right.count else { return false }

        var difference: UInt8 = 0
        for index in left.indices {
            difference |= left[index] ^ right[index]
        }
        return difference == 0
    }

    static func validateEnvelopeSize(_ envelope: EncryptedUsageEnvelope) throws {
        guard envelope.payload.utf8.count <= TokiSyncLimits.maximumEnvelopeBytes else {
            throw SnapshotCipherError.payloadTooLarge
        }
        let encodedEnvelope = try TokiSyncCoding.makeEncoder().encode(envelope)
        guard encodedEnvelope.count <= TokiSyncLimits.maximumEnvelopeBytes else {
            throw SnapshotCipherError.payloadTooLarge
        }
    }

    private static func symmetricKey(from encodedKey: String) throws -> SymmetricKey {
        guard let data = Data(base64Encoded: encodedKey), data.count == 32 else {
            throw SnapshotCipherError.invalidKey
        }
        return SymmetricKey(data: data)
    }

    private static func derivedKey(from encodedKey: String, purpose: Data) throws -> SymmetricKey {
        try HKDF<SHA256>.deriveKey(
            inputKeyMaterial: symmetricKey(from: encodedKey),
            salt: derivationSalt,
            info: purpose,
            outputByteCount: 32)
    }

    private static func associatedData(for envelope: EncryptedUsageEnvelope) throws -> Data {
        let generatedAtMilliseconds = try millisecondsSince1970(envelope.generatedAt)
        return Data(
            "\(envelope.schemaVersion)\n\(envelope.deviceID)\n\(envelope.sequence)\n\(generatedAtMilliseconds)".utf8)
    }

    private static func millisecondDate(_ date: Date) throws -> Date {
        let milliseconds = try millisecondsSince1970(date)
        return Date(timeIntervalSince1970: Double(milliseconds) / 1000)
    }

    private static func millisecondsSince1970(_ date: Date) throws -> Int64 {
        let milliseconds = date.timeIntervalSince1970 * 1000
        guard milliseconds.isFinite,
              milliseconds >= Double(Int64.min),
              milliseconds < Double(Int64.max) else {
            throw SnapshotCipherError.invalidEnvelope
        }
        return Int64(milliseconds.rounded(.down))
    }
}

public struct SnapshotOpaqueIdentifierHasher: Sendable {
    fileprivate let key: SymmetricKey

    public func identifier(for value: String) -> String {
        var message = Data("toki-stream-id-v1\0".utf8)
        message.append(Data(value.utf8))
        let authenticationCode = HMAC<SHA256>.authenticationCode(for: message, using: key)
        return Data(authenticationCode.prefix(16)).map { String(format: "%02x", $0) }.joined()
    }
}

private extension Data {
    func base64URLEncodedString() -> String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
