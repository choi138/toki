import Foundation
import TokiDurableStorage
import TokiSyncProtocol

struct AgentConfiguration: Codable, Equatable {
    let schemaVersion: Int
    let hubURL: URL
    let deviceID: String
    let deviceName: String
    let uploadToken: String
    let encryptionKey: String
    let retentionDays: Int
    let syncIntervalSeconds: Int

    init(bundle: AgentPairingBundle) throws {
        schemaVersion = bundle.schemaVersion
        hubURL = bundle.hubURL
        deviceID = bundle.deviceID
        deviceName = bundle.deviceName
        uploadToken = bundle.uploadToken
        encryptionKey = bundle.encryptionKey
        retentionDays = bundle.retentionDays
        syncIntervalSeconds = bundle.syncIntervalSeconds
        try validate()
    }

    init(from decoder: Decoder) throws {
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

    func validate() throws {
        guard schemaVersion == TokiSyncProtocolVersion.current else {
            throw AgentConfigurationError.unsupportedVersion(schemaVersion)
        }
        guard TokiSyncValidation.isAllowedHubURL(hubURL) else {
            throw AgentConfigurationError.insecureHubURL
        }
        guard TokiSyncValidation.isSafeDeviceID(deviceID) else {
            throw AgentConfigurationError.invalidDeviceID
        }
        guard TokiSyncValidation.normalizedDeviceName(deviceName) == deviceName else {
            throw AgentConfigurationError.invalidDeviceName
        }
        guard TokiSyncValidation.isSafeCredential(uploadToken) else {
            throw AgentConfigurationError.invalidUploadToken
        }
        guard (TokiSyncLimits.minimumRetentionDays...TokiSyncLimits.maximumRetentionDays).contains(retentionDays) else {
            throw AgentConfigurationError.invalidRetentionDays
        }
        guard (TokiSyncLimits.minimumSyncIntervalSeconds...TokiSyncLimits.maximumSyncIntervalSeconds)
            .contains(syncIntervalSeconds) else {
            throw AgentConfigurationError.invalidSyncInterval
        }
        _ = try SnapshotCipher.opaqueIdentifier(for: "configuration-check", key: encryptionKey)
    }
}

struct AgentConfigurationStore {
    let paths: AgentPaths

    func load() throws -> AgentConfiguration {
        guard paths.pathExistsIncludingSymbolicLink(paths.configurationURL) else {
            throw AgentConfigurationError.notPaired
        }
        let values = try paths.configurationURL.resourceValues(
            forKeys: [.fileSizeKey, .isRegularFileKey, .isSymbolicLinkKey])
        guard values.isRegularFile == true,
              values.isSymbolicLink != true,
              let fileSize = values.fileSize,
              fileSize <= TokiSyncLimits.maximumConfigurationFileBytes else {
            throw AgentConfigurationError.invalidConfigurationFile
        }
        let data = try Data(contentsOf: paths.configurationURL)
        guard data.count <= TokiSyncLimits.maximumConfigurationFileBytes else {
            throw AgentConfigurationError.configurationTooLarge
        }
        let configuration = try TokiSyncCoding.makeDecoder().decode(AgentConfiguration.self, from: data)
        try configuration.validate()
        return configuration
    }

    func save(_ configuration: AgentConfiguration) throws {
        try configuration.validate()
        try paths.prepare()
        let data = try TokiSyncCoding.makeEncoder().encode(configuration)
        try paths.writePrivate(data, to: paths.configurationURL)
    }

    func clear() throws {
        try DurableFileIO.removeIfPresent(paths.configurationURL)
    }
}

enum AgentConfigurationError: LocalizedError {
    case notPaired
    case unsupportedVersion(Int)
    case insecureHubURL
    case invalidDeviceID
    case invalidDeviceName
    case invalidUploadToken
    case invalidRetentionDays
    case invalidSyncInterval
    case configurationTooLarge
    case invalidConfigurationFile

    var errorDescription: String? {
        switch self {
        case .notPaired:
            "This agent is not paired. Pipe an Agent pairing bundle into `toki-agent pair`."
        case let .unsupportedVersion(version):
            "Pairing bundle protocol version \(version) is not supported."
        case .insecureHubURL:
            "The Hub URL must be a valid HTTPS origin no longer than 2048 bytes. " +
                "Plain HTTP is allowed only for localhost."
        case .invalidDeviceID:
            "The pairing bundle contains an invalid device identifier."
        case .invalidDeviceName:
            "The device name must contain 1 to 80 characters."
        case .invalidUploadToken:
            "The upload credential must contain 32 to 512 printable ASCII bytes without spaces."
        case .invalidRetentionDays:
            "Retention must be between 1 and 366 days."
        case .invalidSyncInterval:
            "The sync interval must be between 60 seconds and 24 hours."
        case .configurationTooLarge:
            "The Agent configuration exceeds the 64 KiB safety limit."
        case .invalidConfigurationFile:
            "The Agent configuration is not a valid private regular file."
        }
    }
}
