import Foundation

public struct CreateRemoteDeviceRequest: Codable, Equatable, Sendable {
    public let name: String
    public let syncIntervalSeconds: Int

    public init(
        name: String,
        syncIntervalSeconds: Int = TokiSyncLimits.defaultSyncIntervalSeconds) {
        self.name = name
        self.syncIntervalSeconds = syncIntervalSeconds
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        name = try container.decode(String.self, forKey: .name)
        syncIntervalSeconds = try container.decodeIfPresent(Int.self, forKey: .syncIntervalSeconds)
            ?? TokiSyncLimits.defaultSyncIntervalSeconds
    }
}

public struct CreateRemoteDeviceResponse: Codable, Equatable, Sendable {
    public let deviceID: String
    public let deviceName: String
    public let uploadToken: String

    public init(deviceID: String, deviceName: String, uploadToken: String) {
        self.deviceID = deviceID
        self.deviceName = deviceName
        self.uploadToken = uploadToken
    }
}

public struct RemoteDeviceSummary: Codable, Equatable, Sendable {
    public let id: String
    public let name: String
    public let createdAt: Date
    public let lastSeenAt: Date?
    public let latestSequence: UInt64?
    public let syncIntervalSeconds: Int

    public init(
        id: String,
        name: String,
        createdAt: Date,
        lastSeenAt: Date?,
        latestSequence: UInt64?,
        syncIntervalSeconds: Int = TokiSyncLimits.defaultSyncIntervalSeconds) {
        self.id = id
        self.name = name
        self.createdAt = createdAt
        self.lastSeenAt = lastSeenAt
        self.latestSequence = latestSequence
        self.syncIntervalSeconds = syncIntervalSeconds
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        lastSeenAt = try container.decodeIfPresent(Date.self, forKey: .lastSeenAt)
        latestSequence = try container.decodeIfPresent(UInt64.self, forKey: .latestSequence)
        syncIntervalSeconds = try container.decodeIfPresent(Int.self, forKey: .syncIntervalSeconds)
            ?? TokiSyncLimits.defaultSyncIntervalSeconds
    }
}

public struct RemoteDeviceListResponse: Codable, Equatable, Sendable {
    public let devices: [RemoteDeviceSummary]

    public init(devices: [RemoteDeviceSummary]) {
        self.devices = devices
    }
}

public struct RemoteSnapshotListResponse: Codable, Equatable, Sendable {
    public let snapshots: [EncryptedUsageEnvelope]

    public init(snapshots: [EncryptedUsageEnvelope]) {
        self.snapshots = snapshots
    }
}

public struct RemoteSnapshotResponse: Codable, Equatable, Sendable {
    public let snapshot: EncryptedUsageEnvelope

    public init(snapshot: EncryptedUsageEnvelope) {
        self.snapshot = snapshot
    }
}

public struct RemoteSnapshotManifestResponse: Codable, Equatable, Sendable {
    public let devices: [RemoteDeviceSummary]

    public init(devices: [RemoteDeviceSummary]) {
        self.devices = devices
    }
}

public struct AgentHeartbeatRequest: Codable, Equatable, Sendable {
    public let latestSequence: UInt64

    public init(latestSequence: UInt64) {
        self.latestSequence = latestSequence
    }
}

public struct HubHealthResponse: Codable, Equatable, Sendable {
    public let status: String
    public let protocolVersion: Int

    public init(status: String = "ok", protocolVersion: Int = TokiSyncProtocolVersion.current) {
        self.status = status
        self.protocolVersion = protocolVersion
    }
}

public enum TokiSyncCoding {
    public static func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return encoder
    }

    public static func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        return decoder
    }

    public static func encodeBundle(_ value: some Encodable) throws -> String {
        let encoded = try makeEncoder().encode(value).base64EncodedString()
        guard encoded.utf8.count <= TokiSyncLimits.maximumPairingBundleBytes else {
            throw TokiSyncCodingError.bundleTooLarge
        }
        return encoded
    }

    public static func decodeBundle<T: Decodable>(_ type: T.Type, from value: String) throws -> T {
        let trimmedValue = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmedValue.utf8.count <= TokiSyncLimits.maximumPairingBundleBytes else {
            throw TokiSyncCodingError.bundleTooLarge
        }
        guard let data = Data(base64Encoded: trimmedValue) else {
            throw TokiSyncCodingError.invalidBundle
        }
        return try makeDecoder().decode(type, from: data)
    }
}

public enum TokiSyncCodingError: LocalizedError {
    case invalidBundle
    case bundleTooLarge

    public var errorDescription: String? {
        switch self {
        case .invalidBundle:
            "The pairing bundle is not valid base64-encoded Toki data."
        case .bundleTooLarge:
            "The pairing bundle exceeds the 64 KiB safety limit."
        }
    }
}
