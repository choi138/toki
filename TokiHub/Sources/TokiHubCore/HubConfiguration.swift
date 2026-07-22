import Foundation
import TokiSyncProtocol

struct HubConfiguration {
    let ownerToken: String
    let storageDirectory: URL
    let bindTarget: HubBindTarget

    init(environment: [String: String] = ProcessInfo.processInfo.environment) throws {
        guard let ownerToken = environment["TOKI_HUB_OWNER_TOKEN"],
              TokiSyncValidation.isSafeCredential(ownerToken) else {
            throw HubConfigurationError.missingOwnerToken
        }
        self.ownerToken = ownerToken

        if let path = environment["TOKI_HUB_STORAGE_PATH"], !path.isEmpty {
            storageDirectory = try Self.absoluteDirectory(path)
        } else if let stateHome = environment["XDG_STATE_HOME"], !stateHome.isEmpty {
            storageDirectory = try Self.absoluteDirectory(stateHome).appendingPathComponent("toki-hub")
        } else {
            storageDirectory = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".local/state/toki-hub")
        }

        if let socketPath = environment["TOKI_HUB_SOCKET_PATH"]?.nilIfBlank {
            guard environment["TOKI_HUB_HOST"]?.nilIfBlank == nil,
                  environment["PORT"]?.nilIfBlank == nil else {
                throw HubConfigurationError.incompatibleBindSettings
            }
            let socketURL = try Self.absoluteSocketPath(socketPath)
            bindTarget = .unixSocket(socketURL)
            return
        }

        let configuredHostname = environment["TOKI_HUB_HOST"]?.nilIfBlank ?? "127.0.0.1"
        let allowedHostCharacters = CharacterSet(
            charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789.-:")
        guard !configuredHostname.isEmpty,
              configuredHostname.count <= 253,
              configuredHostname.unicodeScalars.allSatisfy(allowedHostCharacters.contains) else {
            throw HubConfigurationError.invalidHost
        }
        let configuredPort: Int
        if let portValue = environment["PORT"] {
            guard let parsedPort = Int(portValue) else {
                throw HubConfigurationError.invalidPort
            }
            configuredPort = parsedPort
        } else {
            configuredPort = 8080
        }
        guard (1...65535).contains(configuredPort) else {
            throw HubConfigurationError.invalidPort
        }
        bindTarget = .tcp(hostname: configuredHostname, port: configuredPort)
    }

    private static func absoluteDirectory(_ path: String) throws -> URL {
        guard NSString(string: path).isAbsolutePath else {
            throw HubConfigurationError.invalidStoragePath
        }
        let url = URL(fileURLWithPath: path).standardizedFileURL
        guard url.path != "/", !url.lastPathComponent.isEmpty else {
            throw HubConfigurationError.invalidStoragePath
        }
        return url
    }

    private static func absoluteSocketPath(_ path: String) throws -> URL {
        guard NSString(string: path).isAbsolutePath,
              path.utf8.count <= 100 else {
            throw HubConfigurationError.invalidSocketPath
        }
        let url = URL(fileURLWithPath: path).standardizedFileURL
        guard url.path != "/", !url.lastPathComponent.isEmpty else {
            throw HubConfigurationError.invalidSocketPath
        }
        return url
    }
}

enum HubBindTarget: Equatable {
    case tcp(hostname: String, port: Int)
    case unixSocket(URL)
}

enum HubConfigurationError: LocalizedError {
    case missingOwnerToken
    case invalidStoragePath
    case invalidHost
    case invalidPort
    case invalidSocketPath
    case incompatibleBindSettings

    var errorDescription: String? {
        switch self {
        case .missingOwnerToken:
            "TOKI_HUB_OWNER_TOKEN must contain 32 to 512 printable ASCII bytes without spaces."
        case .invalidStoragePath:
            "TOKI_HUB_STORAGE_PATH and XDG_STATE_HOME must be absolute paths."
        case .invalidHost:
            "TOKI_HUB_HOST is invalid."
        case .invalidPort:
            "PORT must be between 1 and 65535."
        case .invalidSocketPath:
            "TOKI_HUB_SOCKET_PATH must be an absolute Unix-socket path no longer than 100 bytes."
        case .incompatibleBindSettings:
            "TOKI_HUB_SOCKET_PATH cannot be combined with TOKI_HUB_HOST or PORT."
        }
    }
}

private extension String {
    var nilIfBlank: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
