import Foundation
import TokiSyncProtocol

protocol LocalAgentIdentityProviding {
    func deviceID(matching hubURL: URL) -> String?
}

struct NoLocalAgentIdentityProvider: LocalAgentIdentityProviding {
    func deviceID(matching _: URL) -> String? {
        nil
    }
}

struct LocalAgentIdentityProvider: LocalAgentIdentityProviding {
    private let configurationURL: URL

    init(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser) {
        let configurationRoot: URL = if let configuredRoot = environment["XDG_CONFIG_HOME"],
                                        !configuredRoot.isEmpty,
                                        NSString(string: configuredRoot).isAbsolutePath {
            URL(fileURLWithPath: configuredRoot)
        } else {
            homeDirectory.appendingPathComponent(".config")
        }
        configurationURL = configurationRoot
            .appendingPathComponent("toki-agent")
            .appendingPathComponent("config.json")
    }

    init(configurationURL: URL) {
        self.configurationURL = configurationURL
    }

    func deviceID(matching hubURL: URL) -> String? {
        do {
            let values = try configurationURL.resourceValues(
                forKeys: [.fileSizeKey, .isRegularFileKey, .isSymbolicLinkKey])
            guard values.isRegularFile == true,
                  values.isSymbolicLink != true,
                  let fileSize = values.fileSize,
                  fileSize > 0,
                  fileSize <= TokiSyncLimits.maximumConfigurationFileBytes else {
                return nil
            }
            let data = try Data(contentsOf: configurationURL)
            guard !data.isEmpty,
                  data.count <= TokiSyncLimits.maximumConfigurationFileBytes else {
                return nil
            }
            let identity = try TokiSyncCoding.makeDecoder().decode(StoredLocalAgentIdentity.self, from: data)
            guard identity.schemaVersion == TokiSyncProtocolVersion.current,
                  TokiSyncValidation.isAllowedHubURL(identity.hubURL),
                  TokiSyncValidation.isSafeDeviceID(identity.deviceID),
                  RemoteHubConfiguration.canonicalHubOrigin(for: identity.hubURL)
                  == RemoteHubConfiguration.canonicalHubOrigin(for: hubURL) else {
                return nil
            }
            return identity.deviceID
        } catch {
            return nil
        }
    }
}

private struct StoredLocalAgentIdentity: Decodable {
    let schemaVersion: Int
    let hubURL: URL
    let deviceID: String
}
