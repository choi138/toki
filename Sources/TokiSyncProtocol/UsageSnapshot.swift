@preconcurrency import Foundation

public enum TokiSyncProtocolVersion {
    public static let current = 1
}

public struct RemoteDeviceDescriptor: Codable, Equatable, Sendable {
    public let id: String
    public let name: String
    public let platform: String

    public init(id: String, name: String, platform: String) {
        self.id = id
        self.name = name
        self.platform = platform
    }
}

public enum RemoteAgentKind: String, Codable, Equatable, Sendable {
    case main
    case subagent
}

public struct RemoteTokenEvent: Codable, Equatable, Sendable {
    public let timestamp: Date
    public let source: String
    public let model: String?
    public let inputTokens: Int
    public let outputTokens: Int
    public let cacheReadTokens: Int
    public let cacheWriteTokens: Int
    public let reasoningTokens: Int

    public init(
        timestamp: Date,
        source: String,
        model: String?,
        inputTokens: Int,
        outputTokens: Int,
        cacheReadTokens: Int,
        cacheWriteTokens: Int,
        reasoningTokens: Int) {
        self.timestamp = timestamp
        self.source = source
        self.model = model
        self.inputTokens = max(0, inputTokens)
        self.outputTokens = max(0, outputTokens)
        self.cacheReadTokens = max(0, cacheReadTokens)
        self.cacheWriteTokens = max(0, cacheWriteTokens)
        self.reasoningTokens = max(0, reasoningTokens)
    }

    public var totalTokens: Int {
        [inputTokens, outputTokens, cacheReadTokens, cacheWriteTokens, reasoningTokens]
            .reduce(0, saturatingTokenSum)
    }
}

private func saturatingTokenSum(_ total: Int, _ value: Int) -> Int {
    let (sum, overflow) = total.addingReportingOverflow(value)
    guard overflow else { return sum }
    return value >= 0 ? Int.max : Int.min
}

public struct RemoteActivityEvent: Codable, Equatable, Sendable {
    public let timestamp: Date
    public let source: String
    public let model: String?
    public let streamID: String
    public let agentKind: RemoteAgentKind

    public init(
        timestamp: Date,
        source: String,
        model: String?,
        streamID: String,
        agentKind: RemoteAgentKind) {
        self.timestamp = timestamp
        self.source = source
        self.model = model
        self.streamID = streamID
        self.agentKind = agentKind
    }
}

/// A replaceable, bounded snapshot. It deliberately excludes prompts, responses,
/// local paths, session labels, database rows, and security-audit findings.
public struct RemoteUsageSnapshot: Codable, Equatable, Sendable {
    public let schemaVersion: Int
    public let device: RemoteDeviceDescriptor
    public let generatedAt: Date
    public let coveredFrom: Date
    public let coveredTo: Date
    public let tokenEvents: [RemoteTokenEvent]
    public let activityEvents: [RemoteActivityEvent]

    public init(
        schemaVersion: Int = TokiSyncProtocolVersion.current,
        device: RemoteDeviceDescriptor,
        generatedAt: Date,
        coveredFrom: Date,
        coveredTo: Date,
        tokenEvents: [RemoteTokenEvent],
        activityEvents: [RemoteActivityEvent]) {
        self.schemaVersion = schemaVersion
        self.device = device
        self.generatedAt = generatedAt
        self.coveredFrom = coveredFrom
        self.coveredTo = coveredTo
        self.tokenEvents = tokenEvents
        self.activityEvents = activityEvents
    }
}

/// The Hub stores this value without having the key required to inspect `payload`.
public struct EncryptedUsageEnvelope: Codable, Equatable, Sendable {
    public let schemaVersion: Int
    public let deviceID: String
    public let sequence: UInt64
    public let generatedAt: Date
    public let payload: String

    public init(
        schemaVersion: Int = TokiSyncProtocolVersion.current,
        deviceID: String,
        sequence: UInt64,
        generatedAt: Date,
        payload: String) {
        self.schemaVersion = schemaVersion
        self.deviceID = deviceID
        self.sequence = sequence
        self.generatedAt = generatedAt
        self.payload = payload
    }
}

public struct AgentPairingBundle: Codable, Equatable, Sendable {
    public let schemaVersion: Int
    public let hubURL: URL
    public let deviceID: String
    public let deviceName: String
    public let uploadToken: String
    public let encryptionKey: String
    public let retentionDays: Int
    public let syncIntervalSeconds: Int

    public init(
        schemaVersion: Int = TokiSyncProtocolVersion.current,
        hubURL: URL,
        deviceID: String,
        deviceName: String,
        uploadToken: String,
        encryptionKey: String,
        retentionDays: Int = TokiSyncLimits.defaultRetentionDays,
        syncIntervalSeconds: Int = TokiSyncLimits.defaultSyncIntervalSeconds) {
        self.schemaVersion = schemaVersion
        self.hubURL = hubURL
        self.deviceID = deviceID
        self.deviceName = deviceName
        self.uploadToken = uploadToken
        self.encryptionKey = encryptionKey
        self.retentionDays = retentionDays
        self.syncIntervalSeconds = syncIntervalSeconds
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try container.decode(Int.self, forKey: .schemaVersion)
        hubURL = try container.decode(URL.self, forKey: .hubURL)
        deviceID = try container.decode(String.self, forKey: .deviceID)
        deviceName = try container.decode(String.self, forKey: .deviceName)
        uploadToken = try container.decode(String.self, forKey: .uploadToken)
        encryptionKey = try container.decode(String.self, forKey: .encryptionKey)
        retentionDays = try container.decodeIfPresent(Int.self, forKey: .retentionDays)
            ?? TokiSyncLimits.defaultRetentionDays
        syncIntervalSeconds = try container.decodeIfPresent(Int.self, forKey: .syncIntervalSeconds)
            ?? TokiSyncLimits.defaultSyncIntervalSeconds
    }
}
