import Foundation
import TokiUsageCore

public struct LocalUsageReaderPaths: Equatable {
    public let homeDirectory: URL
    public let hermesHome: URL
    public let hermesDiscoversProfiles: Bool
    public let xdgConfigDirectory: URL
    public let xdgDataDirectory: URL
    public let xdgStateDirectory: URL
    public let senpiSessions: [URL]
    public let senpiSessionDirectories: [URL]
    public let piSessions: URL
    public let ompSessions: URL
    public let ompSessionRoots: [URL]
    public let kimchiSessions: URL
    public let gjcSessionRoots: [URL]
    public let copilotOTELExporterFile: URL?
    private let claudeHome: URL
    private let codexHome: URL
    private let geminiHome: URL
    private let kimiCLIHomeOverride: URL?
    private let kimiCodeHomeOverride: URL?
    private let qwenHomeOverride: URL?
    private let qwenRuntimeOverride: URL?
    private let grokHome: URL

    public init(
        homeDirectory: URL = homeDir(),
        environment: [String: String] = ProcessInfo.processInfo.environment) {
        self.homeDirectory = homeDirectory
        let explicitHermesHome = Self.absoluteEnvironmentDirectory(
            key: "HERMES_HOME",
            environment: environment)
        hermesHome = explicitHermesHome
            ?? homeDirectory.appendingPathComponent(".hermes")
        hermesDiscoversProfiles = explicitHermesHome == nil
        claudeHome = Self.absoluteEnvironmentDirectory(key: "CLAUDE_CONFIG_DIR", environment: environment)
            ?? homeDirectory.appendingPathComponent(".claude")
        codexHome = Self.absoluteEnvironmentDirectory(key: "CODEX_HOME", environment: environment)
            ?? homeDirectory.appendingPathComponent(".codex")
        geminiHome = Self.absoluteEnvironmentDirectory(key: "GEMINI_CLI_HOME", environment: environment)
            ?? homeDirectory.appendingPathComponent(".gemini")
        xdgConfigDirectory = Self.absoluteEnvironmentDirectory(
            key: "XDG_CONFIG_HOME",
            environment: environment)
            ?? homeDirectory.appendingPathComponent(".config")
        xdgDataDirectory = Self.absoluteEnvironmentDirectory(
            key: "XDG_DATA_HOME",
            environment: environment)
            ?? homeDirectory.appendingPathComponent(".local/share")
        xdgStateDirectory = Self.absoluteEnvironmentDirectory(
            key: "XDG_STATE_HOME",
            environment: environment)
            ?? homeDirectory.appendingPathComponent(".local/state")
        let senpiSessionOverride = Self.absoluteEnvironmentDirectory(
            key: "SENPI_CODING_AGENT_SESSION_DIR",
            environment: environment)
        senpiSessions = senpiSessionOverride.map { [$0] } ?? [
            homeDirectory.appendingPathComponent(".omo/agent/sessions"),
            homeDirectory.appendingPathComponent(".senpi/agent/sessions"),
        ]
        senpiSessionDirectories = Self.senpiDirectories(
            home: homeDirectory, environment: environment, sessionOverride: senpiSessionOverride)
        piSessions = Self.absoluteEnvironmentDirectory(
            key: "PI_CODING_AGENT_SESSION_DIR",
            environment: environment)
            ?? Self.absoluteEnvironmentDirectory(
                key: "PI_CODING_AGENT_DIR",
                environment: environment)
            .map { $0.appendingPathComponent("sessions") }
            ?? homeDirectory.appendingPathComponent(".pi/agent/sessions")
        ompSessionRoots = Self.ompSessionDirectories(
            homeDirectory: homeDirectory,
            xdgDataDirectory: xdgDataDirectory,
            environment: environment)
        ompSessions = ompSessionRoots[0]
        kimchiSessions = Self.absoluteEnvironmentDirectory(key: "KIMCHI_CODING_AGENT_DIR", environment: environment)
            .map { $0.appendingPathComponent("sessions") }
            ?? xdgConfigDirectory.appendingPathComponent("kimchi/harness/sessions")
        gjcSessionRoots = Self.gjcDirectories(home: homeDirectory, environment: environment)
        copilotOTELExporterFile = Self.absoluteEnvironmentDirectory(
            key: "COPILOT_OTEL_FILE_EXPORTER_PATH",
            environment: environment)
            .flatMap { $0.pathExtension.lowercased() == "jsonl" ? $0 : nil }
        kimiCLIHomeOverride = Self.absoluteEnvironmentDirectory(
            key: "KIMI_SHARE_DIR",
            environment: environment)
        kimiCodeHomeOverride = Self.absoluteEnvironmentDirectory(
            key: "KIMI_CODE_HOME",
            environment: environment)
        qwenHomeOverride = Self.absoluteEnvironmentDirectory(
            key: "QWEN_HOME",
            environment: environment)
        qwenRuntimeOverride = Self.absoluteEnvironmentDirectory(
            key: "QWEN_RUNTIME_DIR",
            environment: environment)
        grokHome = Self.absoluteEnvironmentDirectory(key: "GROK_HOME", environment: environment)
            ?? homeDirectory.appendingPathComponent(".grok")
    }

    public var claudeProjects: URL {
        claudeHome.appendingPathComponent("projects")
    }

    public var claudeTranscripts: URL {
        claudeHome.appendingPathComponent("transcripts")
    }

    public var codexDatabase: URL {
        codexHome.appendingPathComponent("state_5.sqlite")
    }

    public var codexSessions: URL {
        codexHome.appendingPathComponent("sessions")
    }

    public var codexArchivedSessions: URL {
        codexHome.appendingPathComponent("archived_sessions")
    }

    public var hermesDatabase: URL {
        hermesHome.appendingPathComponent("state.db")
    }

    public var hermesDefaultDatabase: URL {
        homeDirectory.appendingPathComponent(".hermes/state.db")
    }

    public var hermesProfiles: URL {
        hermesHome.appendingPathComponent("profiles", isDirectory: true)
    }

    public var cursorDatabase: URL {
        #if os(Linux)
            xdgConfigDirectory.appendingPathComponent("Cursor/User/globalStorage/state.vscdb")
        #else
            homeDirectory.appendingPathComponent(
                "Library/Application Support/Cursor/User/globalStorage/state.vscdb")
        #endif
    }

    public var geminiChats: URL {
        geminiHome.appendingPathComponent("tmp")
    }

    public var gjcSessions: URL {
        gjcSessionRoots[0]
    }

    public var factoryDroidSessions: URL {
        homeDirectory.appendingPathComponent(".factory/sessions")
    }

    public var ampThreads: URL {
        xdgDataDirectory.appendingPathComponent("amp/threads")
    }

    public var openCodeDatabase: URL {
        xdgDataDirectory.appendingPathComponent("opencode/opencode.db")
    }

    public var openClawAgents: URL {
        homeDirectory.appendingPathComponent(".openclaw/agents")
    }

    public var copilotOTELDirectory: URL {
        homeDirectory.appendingPathComponent(".copilot/otel")
    }

    public var kimiCLISessions: [URL] {
        kimiCLIHomes.map { $0.appendingPathComponent("sessions") }
    }

    public var kimiCodeSessions: [URL] {
        Self.uniqueDirectories(
            [homeDirectory.appendingPathComponent(".kimi-code")]
                + [kimiCodeHomeOverride].compactMap { $0 })
            .map { $0.appendingPathComponent("sessions") }
    }

    public var qwenProjects: [URL] {
        Self.uniqueDirectories(
            [homeDirectory.appendingPathComponent(".qwen")]
                + [qwenHomeOverride, qwenRuntimeOverride].compactMap { $0 })
            .map { $0.appendingPathComponent("projects") }
    }

    public var grokSessions: URL {
        grokHome.appendingPathComponent("sessions")
    }

    public var agentCacheDirectory: URL {
        xdgStateDirectory.appendingPathComponent("toki-agent")
    }

    public var applicationCacheDirectory: URL {
        #if os(macOS)
            homeDirectory
                .appendingPathComponent("Library")
                .appendingPathComponent("Application Support")
                .appendingPathComponent("Toki")
        #else
            xdgStateDirectory.appendingPathComponent("toki")
        #endif
    }

    public func cacheDirectory(for scope: LocalUsageCacheScope) -> URL {
        switch scope {
        case .application:
            applicationCacheDirectory
        case .agent:
            agentCacheDirectory
        }
    }
}

private extension LocalUsageReaderPaths {
    static func senpiDirectories(home: URL, environment: [String: String], sessionOverride: URL?) -> [URL] {
        var directories = [
            home.appendingPathComponent(".omo/agent/sessions"),
            home.appendingPathComponent(".senpi/agent/sessions"),
            home.appendingPathComponent(".omo/senpi-task/children"),
            home.appendingPathComponent(".omo/senpi-task/sessions"),
        ]
        if let agent = absoluteEnvironmentDirectory(key: "SENPI_CODING_AGENT_DIR", environment: environment) {
            directories.append(agent.appendingPathComponent("sessions"))
        }
        if let sessionOverride { directories.append(sessionOverride) }
        if let project = absoluteEnvironmentDirectory(key: "PWD", environment: environment) {
            directories.append(project.appendingPathComponent(".omo/senpi-task/children"))
            directories.append(project.appendingPathComponent(".omo/senpi-task/sessions"))
        }
        return uniqueDirectories(directories)
    }

    static func gjcDirectories(home: URL, environment: [String: String]) -> [URL] {
        var roots: [URL] = []
        if let agent = absoluteEnvironmentDirectory(key: "GJC_CODING_AGENT_DIR", environment: environment) {
            roots.append(agent.appendingPathComponent("sessions"))
        }
        for key in ["GJC_CONFIG_DIR", "PI_CONFIG_DIR"] {
            if let config = absoluteEnvironmentDirectory(key: key, environment: environment) {
                roots.append(config.appendingPathComponent("agent/sessions"))
            }
        }
        if let data = absoluteEnvironmentDirectory(key: "XDG_DATA_HOME", environment: environment) {
            roots.append(data.appendingPathComponent("gjc/sessions"))
        }
        roots.append(home.appendingPathComponent(".gjc/agent/sessions"))
        // Keep absent candidates so readers and signatures observe roots created after launch.
        return uniqueDirectories(roots)
    }

    private var kimiCLIHomes: [URL] {
        Self.uniqueDirectories(
            [homeDirectory.appendingPathComponent(".kimi")]
                + [kimiCLIHomeOverride].compactMap { $0 })
    }

    private static func absoluteEnvironmentDirectory(
        key: String,
        environment: [String: String]) -> URL? {
        guard let value = environment[key],
              !value.contains("\0"),
              value.hasPrefix("/") else {
            return nil
        }
        return URL(fileURLWithPath: value)
    }

    private static func uniqueDirectories(_ directories: [URL]) -> [URL] {
        var seen = Set<String>()
        return directories.compactMap { directory in
            let standardized = directory.standardizedFileURL
            return seen.insert(standardized.path).inserted ? standardized : nil
        }
    }

    private static func ompSessionDirectories(
        homeDirectory: URL,
        xdgDataDirectory: URL,
        environment: [String: String]) -> [URL] {
        let profileValue = environment.keys.contains("OMP_PROFILE")
            ? environment["OMP_PROFILE"]
            : environment["PI_PROFILE"]
        let profile = normalizedOMPProfile(profileValue)
        let explicitConfigDirectory = normalizedConfigDirectory(environment["PI_CONFIG_DIR"])
        let configRoot: URL = if let explicitConfigDirectory,
                                 NSString(string: explicitConfigDirectory).isAbsolutePath {
            URL(fileURLWithPath: explicitConfigDirectory)
        } else {
            homeDirectory.appendingPathComponent(explicitConfigDirectory ?? ".omp")
        }

        if let profile {
            let configuredSessions = configRoot
                .appendingPathComponent("profiles")
                .appendingPathComponent(profile)
                .appendingPathComponent("agent/sessions")
            if explicitConfigDirectory != nil {
                return [configuredSessions]
            }
            let xdgSessions = xdgDataDirectory
                .appendingPathComponent("omp/profiles")
                .appendingPathComponent(profile)
                .appendingPathComponent("sessions")
            return isExistingDirectory(xdgSessions)
                ? uniqueDirectories([xdgSessions, configuredSessions])
                : uniqueDirectories([configuredSessions, xdgSessions])
        }

        let configuredSessions = configRoot.appendingPathComponent("agent/sessions")
        if explicitConfigDirectory != nil {
            return [configuredSessions]
        }
        let xdgSessions = xdgDataDirectory.appendingPathComponent("omp/sessions")
        return isExistingDirectory(xdgSessions)
            ? uniqueDirectories([xdgSessions, configuredSessions])
            : uniqueDirectories([configuredSessions, xdgSessions])
    }

    private static func normalizedOMPProfile(_ value: String?) -> String? {
        guard let profile = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !profile.isEmpty,
              profile != "default",
              profile != ".",
              profile != "..",
              !profile.hasSuffix("."),
              profile.utf8.count <= 64,
              let first = profile.first,
              first.isLowercase || first.isNumber,
              profile.allSatisfy({ $0.isLowercase || $0.isNumber || "._-".contains($0) }) else {
            return nil
        }
        return profile
    }
}

private func isExistingDirectory(_ url: URL) -> Bool {
    var isDirectory: ObjCBool = false
    return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory)
        && isDirectory.boolValue
}

private func normalizedConfigDirectory(_ value: String?) -> String? {
    let configured = value?.trimmingCharacters(in: .whitespacesAndNewlines)
    return configured.flatMap { $0.isEmpty ? nil : $0 }
}
