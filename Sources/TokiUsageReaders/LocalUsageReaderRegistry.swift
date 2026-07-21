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

    private static func absoluteEnvironmentDirectory(
        key: String,
        environment: [String: String]) -> URL? {
        guard let value = environment[key],
              NSString(string: value).isAbsolutePath else {
            return nil
        }
        return URL(fileURLWithPath: value)
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
                .shared
            case .agent:
                CodexRolloutUsageCache(cacheURL: codexRolloutUsageCacheURL(paths: paths, scope: .agent))
            }
        }
        let resolvedClaudeUsageCache = claudeUsageCache
            ?? ClaudeUsageCache(cacheURL: claudeUsageCacheURL(paths: paths, scope: cacheScope))
        let resolvedHermesUsageLedger = hermesUsageLedger
            ?? HermesUsageLedger(fileURL: hermesUsageLedgerURL(paths: paths, scope: cacheScope))
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
