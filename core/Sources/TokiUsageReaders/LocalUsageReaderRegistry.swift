import Foundation
import TokiUsageCore

package enum LocalUsageSourceLocation: Equatable {
    case file(URL, includesSQLiteSidecars: Bool)
    case directory(URL, extensions: Set<String>)

    package var url: URL {
        switch self {
        case let .file(url, _), let .directory(url, _):
            url
        }
    }
}

package enum LocalUsageSourceSignatureStrategy {
    case standard
    case codexRollouts
}

package struct LocalUsageReaderDescriptor {
    package let reader: any TokenReader
    package let sourceLocations: [LocalUsageSourceLocation]
    package let sourceSignatureStrategy: LocalUsageSourceSignatureStrategy

    package init(
        reader: any TokenReader,
        sourceLocations: [LocalUsageSourceLocation],
        sourceSignatureStrategy: LocalUsageSourceSignatureStrategy = .standard) {
        self.reader = reader
        self.sourceLocations = sourceLocations
        self.sourceSignatureStrategy = sourceSignatureStrategy
    }

    package var name: String {
        reader.name
    }
}

public enum LocalUsageCacheScope {
    case application
    case agent
}

public struct LocalUsageReaderPaths: Equatable {
    public let homeDirectory: URL
    public let xdgConfigDirectory: URL
    public let xdgDataDirectory: URL
    public let xdgStateDirectory: URL
    private let kimiCLIHomeOverride: URL?
    private let kimiCodeHomeOverride: URL?
    private let qwenHomeOverride: URL?
    private let qwenRuntimeOverride: URL?

    public init(
        homeDirectory: URL = homeDir(),
        environment: [String: String] = ProcessInfo.processInfo.environment) {
        self.homeDirectory = homeDirectory
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
    }

    public var claudeProjects: URL {
        homeDirectory.appendingPathComponent(".claude/projects")
    }

    public var codexDatabase: URL {
        homeDirectory.appendingPathComponent(".codex/state_5.sqlite")
    }

    public var codexSessions: URL {
        homeDirectory.appendingPathComponent(".codex/sessions")
    }

    public var codexArchivedSessions: URL {
        homeDirectory.appendingPathComponent(".codex/archived_sessions")
    }

    public var hermesDatabase: URL {
        homeDirectory.appendingPathComponent(".hermes/state.db")
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
        homeDirectory.appendingPathComponent(".gemini/tmp")
    }

    public var gjcSessions: URL {
        homeDirectory.appendingPathComponent(".gjc/agent/sessions")
    }

    public var openCodeDatabase: URL {
        xdgDataDirectory.appendingPathComponent("opencode/opencode.db")
    }

    public var openClawAgents: URL {
        homeDirectory.appendingPathComponent(".openclaw/agents")
    }

    public var kimiCLISessions: [URL] {
        kimiCLIHomes.map { $0.appendingPathComponent("sessions") }
    }

    public var kimiCLIConfigFiles: [URL] {
        kimiCLIHomes.flatMap { home in
            [
                home.appendingPathComponent("config.toml"),
                home.appendingPathComponent("config.json"),
            ]
        }
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

    private var kimiCLIHomes: [URL] {
        Self.uniqueDirectories(
            [homeDirectory.appendingPathComponent(".kimi")]
                + [kimiCLIHomeOverride].compactMap { $0 })
    }

    private static func absoluteEnvironmentDirectory(
        key: String,
        environment: [String: String]) -> URL? {
        guard let value = environment[key],
              NSString(string: value).isAbsolutePath else {
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
}

public enum LocalUsageReaderRegistry {
    static func descriptors(
        home: URL = homeDir(),
        environment: [String: String] = ProcessInfo.processInfo.environment,
        cacheScope: LocalUsageCacheScope = .application,
        codexRolloutUsageCache: CodexRolloutUsageCache? = nil,
        claudeUsageCache: ClaudeUsageCache? = nil,
        hermesUsageLedger: HermesUsageLedger? = nil) -> [LocalUsageReaderDescriptor] {
        let paths = LocalUsageReaderPaths(homeDirectory: home, environment: environment)
        let resolvedCodexRolloutUsageCache: CodexRolloutUsageCache = if let codexRolloutUsageCache {
            codexRolloutUsageCache
        } else {
            switch cacheScope {
            case .application:
                CodexRolloutUsageCache(
                    cacheURL: codexRolloutUsageCacheURL(paths: paths, scope: .application))
            case .agent:
                CodexRolloutUsageCache(cacheURL: codexRolloutUsageCacheURL(paths: paths, scope: .agent))
            }
        }
        let resolvedClaudeUsageCache = claudeUsageCache
            ?? ClaudeUsageCache(cacheURL: claudeUsageCacheURL(paths: paths, scope: cacheScope))
        let automaticallyMigrateLegacyHermesLedger = switch cacheScope {
        case .application:
            true
        case .agent:
            false
        }
        let resolvedHermesUsageLedger = hermesUsageLedger
            ?? HermesUsageLedger(
                fileURL: hermesUsageLedgerURL(paths: paths, scope: cacheScope),
                automaticallyMigrateLegacy: automaticallyMigrateLegacyHermesLedger)
        return [
            LocalUsageReaderDescriptor(
                reader: ClaudeCodeReader(
                    projectsURLOverride: paths.claudeProjects,
                    usageCache: resolvedClaudeUsageCache),
                sourceLocations: [.directory(paths.claudeProjects, extensions: ["jsonl"])]),
            LocalUsageReaderDescriptor(
                reader: CodexReader(
                    dbPath: paths.codexDatabase.path,
                    rolloutUsageCache: resolvedCodexRolloutUsageCache),
                sourceLocations: [
                    .file(paths.codexDatabase, includesSQLiteSidecars: true),
                    .directory(paths.codexSessions, extensions: ["jsonl"]),
                    .directory(paths.codexArchivedSessions, extensions: ["jsonl"]),
                ],
                sourceSignatureStrategy: .codexRollouts),
            LocalUsageReaderDescriptor(
                reader: HermesReader(
                    dbPathOverride: paths.hermesDatabase.path,
                    usageLedger: resolvedHermesUsageLedger),
                sourceLocations: [.file(paths.hermesDatabase, includesSQLiteSidecars: true)]),
            LocalUsageReaderDescriptor(
                reader: CursorReader(dbPathOverride: paths.cursorDatabase.path),
                sourceLocations: [.file(paths.cursorDatabase, includesSQLiteSidecars: true)]),
            LocalUsageReaderDescriptor(
                reader: GeminiReader(chatsBaseURLOverride: paths.geminiChats),
                sourceLocations: [.directory(paths.geminiChats, extensions: ["json"])]),
            LocalUsageReaderDescriptor(
                reader: GJCReader(sessionsURLOverride: paths.gjcSessions),
                sourceLocations: [.directory(paths.gjcSessions, extensions: ["jsonl"])]),
            LocalUsageReaderDescriptor(
                reader: OpenCodeReader(dbPathOverride: paths.openCodeDatabase.path),
                sourceLocations: [.file(paths.openCodeDatabase, includesSQLiteSidecars: true)]),
            LocalUsageReaderDescriptor(
                reader: OpenClawReader(agentsURLOverride: paths.openClawAgents),
                sourceLocations: [.directory(paths.openClawAgents, extensions: ["jsonl"])]),
            LocalUsageReaderDescriptor(
                reader: KimiCLIReader(sessionRoots: paths.kimiCLISessions),
                sourceLocations:
                paths.kimiCLIConfigFiles.map { .file($0, includesSQLiteSidecars: false) }
                    + paths.kimiCLISessions.map { .directory($0, extensions: ["jsonl"]) }),
            LocalUsageReaderDescriptor(
                reader: KimiCodeReader(sessionRoots: paths.kimiCodeSessions),
                sourceLocations: paths.kimiCodeSessions.map { .directory($0, extensions: ["jsonl"]) }),
            LocalUsageReaderDescriptor(
                reader: QwenCLIReader(projectRoots: paths.qwenProjects),
                sourceLocations: paths.qwenProjects.map { .directory($0, extensions: ["jsonl"]) }),
        ]
    }

    public static func readers(
        home: URL = homeDir(),
        environment: [String: String] = ProcessInfo.processInfo.environment) -> [any TokenReader] {
        descriptors(home: home, environment: environment).map(\.reader)
    }

    package static func agentDescriptors(
        home: URL = homeDir(),
        environment: [String: String] = ProcessInfo.processInfo.environment,
        codexRolloutUsageCache: CodexRolloutUsageCache? = nil,
        claudeUsageCache: ClaudeUsageCache? = nil,
        hermesUsageLedger: HermesUsageLedger? = nil) -> [LocalUsageReaderDescriptor] {
        descriptors(
            home: home,
            environment: environment,
            cacheScope: .agent,
            codexRolloutUsageCache: codexRolloutUsageCache,
            claudeUsageCache: claudeUsageCache,
            hermesUsageLedger: hermesUsageLedger)
    }
}
