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
    case allFiles
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
    public let senpiSessionDirectories: [URL]
    public let piSessions: URL
    public let ompSessions: URL
    public let kimchiSessions: URL
    public let copilotOTELExporterFile: URL?

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
        var senpiDirectories = [
            homeDirectory.appendingPathComponent(".omo/agent/sessions"),
            homeDirectory.appendingPathComponent(".senpi/agent/sessions"),
            homeDirectory.appendingPathComponent(".omo/senpi-task/children"),
            homeDirectory.appendingPathComponent(".omo/senpi-task/sessions"),
        ]
        if let agentDirectory = Self.absoluteEnvironmentDirectory(
            key: "SENPI_CODING_AGENT_DIR",
            environment: environment) {
            senpiDirectories.append(agentDirectory.appendingPathComponent("sessions"))
        }
        if let sessionDirectory = Self.absoluteEnvironmentDirectory(
            key: "SENPI_CODING_AGENT_SESSION_DIR",
            environment: environment) {
            senpiDirectories.append(sessionDirectory)
        }
        if let projectDirectory = Self.absoluteEnvironmentDirectory(
            key: "PWD",
            environment: environment) {
            senpiDirectories.append(projectDirectory.appendingPathComponent(".omo/senpi-task/children"))
            senpiDirectories.append(projectDirectory.appendingPathComponent(".omo/senpi-task/sessions"))
        }
        senpiSessionDirectories = Self.uniqueDirectories(senpiDirectories)
        piSessions = Self.absoluteEnvironmentDirectory(
            key: "PI_CODING_AGENT_SESSION_DIR",
            environment: environment)
            ?? Self.absoluteEnvironmentDirectory(
                key: "PI_CODING_AGENT_DIR",
                environment: environment)
            .map { $0.appendingPathComponent("sessions") }
            ?? homeDirectory.appendingPathComponent(".pi/agent/sessions")
        ompSessions = homeDirectory.appendingPathComponent(".omp/agent/sessions")
        kimchiSessions = xdgConfigDirectory.appendingPathComponent("kimchi/harness/sessions")
        copilotOTELExporterFile = Self.absoluteEnvironmentDirectory(
            key: "COPILOT_OTEL_FILE_EXPORTER_PATH",
            environment: environment)
            .flatMap { $0.pathExtension.lowercased() == "jsonl" ? $0 : nil }
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

    public var copilotOTELDirectory: URL {
        homeDirectory.appendingPathComponent(".copilot/otel")
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

    private static func uniqueDirectories(_ directories: [URL]) -> [URL] {
        var paths: Set<String> = []
        return directories.compactMap { directory in
            let standardized = directory.standardizedFileURL
            guard paths.insert(standardized.path).inserted else { return nil }
            return standardized
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
        let copilotSourceLocations: [LocalUsageSourceLocation] =
            [.directory(paths.copilotOTELDirectory, extensions: ["jsonl"])]
                + (paths.copilotOTELExporterFile.map {
                    [.file($0, includesSQLiteSidecars: false)]
                } ?? [])
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
                reader: SenpiReader(sessionRootsOverride: paths.senpiSessionDirectories),
                sourceLocations: paths.senpiSessionDirectories.map {
                    .directory($0, extensions: ["jsonl"])
                },
                sourceSignatureStrategy: .allFiles),
        ] + piFamilyDescriptors(paths: paths) + [
            LocalUsageReaderDescriptor(
                reader: OpenCodeReader(dbPathOverride: paths.openCodeDatabase.path),
                sourceLocations: [.file(paths.openCodeDatabase, includesSQLiteSidecars: true)]),
            LocalUsageReaderDescriptor(
                reader: OpenClawReader(agentsURLOverride: paths.openClawAgents),
                sourceLocations: [.directory(paths.openClawAgents, extensions: ["jsonl"])]),
            LocalUsageReaderDescriptor(
                reader: CopilotCLIReader(
                    otelDirectoryURLOverride: paths.copilotOTELDirectory,
                    exporterFileURLOverride: paths.copilotOTELExporterFile),
                sourceLocations: copilotSourceLocations,
                sourceSignatureStrategy: .allFiles),
        ]
    }

    private static func piFamilyDescriptors(
        paths: LocalUsageReaderPaths) -> [LocalUsageReaderDescriptor] {
        [
            LocalUsageReaderDescriptor(
                reader: PiReader(sessionsURLOverride: paths.piSessions),
                sourceLocations: [.directory(paths.piSessions, extensions: ["jsonl"])],
                sourceSignatureStrategy: .allFiles),
            LocalUsageReaderDescriptor(
                reader: OMPReader(sessionsURLOverride: paths.ompSessions),
                sourceLocations: [.directory(paths.ompSessions, extensions: ["jsonl"])],
                sourceSignatureStrategy: .allFiles),
            LocalUsageReaderDescriptor(
                reader: KimchiReader(sessionsURLOverride: paths.kimchiSessions),
                sourceLocations: [.directory(paths.kimchiSessions, extensions: ["jsonl"])],
                sourceSignatureStrategy: .allFiles),
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
