import Foundation
import TokiUsageCore

public enum LocalUsageCacheScope {
    case application
    case agent
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
        let resolvedCodexRolloutUsageCache = codexRolloutUsageCache
            ?? CodexRolloutUsageCache(cacheURL: codexRolloutUsageCacheURL(paths: paths, scope: cacheScope))
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
        let gjcReader = GJCReader(
            sessionRootsOverride: paths.gjcSessionRoots,
            legacySessionsURL: paths.homeDirectory.appendingPathComponent(".gjc/agent/sessions"),
            sharedOMPSessionRoots: paths.ompSessionRoots,
            sharedPiSessionRoots: [paths.piSessions])
        let descriptors = primaryDescriptors(
            paths: paths, codexCache: resolvedCodexRolloutUsageCache,
            claudeCache: resolvedClaudeUsageCache, hermesLedger: resolvedHermesUsageLedger,
            cacheScope: cacheScope) + [
            LocalUsageReaderDescriptor(
                reader: GeminiReader(chatsBaseURLOverride: paths.geminiChats),
                sourceLocations: [.directory(paths.geminiChats, extensions: ["json", "jsonl"])],
                sourceSignatureStrategy: .boundedAllFiles(
                    maximumFileCount: PiCompatibleReadLimits.default.maximumFileCount,
                    maximumEntryCount: PiCompatibleReadLimits.default.maximumEntryCount)),
            LocalUsageReaderDescriptor(
                reader: gjcReader,
                sourceLocations: paths.gjcSessionRoots.map { .directory($0, extensions: ["jsonl"]) },
                sourceSignatureStrategy: .boundedAllFiles(
                    maximumFileCount: PiCompatibleReadLimits.default.maximumFileCount,
                    maximumEntryCount: PiCompatibleReadLimits.default.maximumEntryCount),
                collectorRevision: 1,
                sourceLocationsResolver: {
                    let identity = gjcReader.sharedSelectionIdentity()
                    return gjcReader.selectedSessionRoots().map {
                        .directory($0, extensions: ["jsonl"], selectionIdentity: identity)
                    }
                }),
            LocalUsageReaderDescriptor(
                reader: FactoryDroidReader(sessionsURLOverride: paths.factoryDroidSessions),
                sourceLocations: [.directory(paths.factoryDroidSessions, extensions: ["json", "jsonl"])],
                sourceSignatureStrategy: .allFiles),
            LocalUsageReaderDescriptor(
                reader: AmpReader(threadsURLOverride: paths.ampThreads),
                sourceLocations: [.directory(paths.ampThreads, extensions: ["json"])],
                sourceSignatureStrategy: .allFiles),
            LocalUsageReaderDescriptor(
                reader: SenpiReader(sessionRootsOverride: paths.senpiSessionDirectories),
                sourceLocations: paths.senpiSessionDirectories.map {
                    .directory($0, extensions: ["jsonl"])
                },
                sourceSignatureStrategy: .allFiles),
        ] + piFamilyDescriptors(paths: paths) + additionalDescriptors(
            paths: paths,
            environment: environment,
            copilotSourceLocations: copilotSourceLocations)
        return descriptors.map { descriptor in
            // Changing this local revision invalidates the agent's persisted source signature
            // once after upgrade. It never changes the remote snapshot schema or Hermes history.
            guard ["Claude Code", "Codex", "Gemini CLI", "Kimchi"].contains(descriptor.name) else {
                return descriptor
            }
            return LocalUsageReaderDescriptor(
                reader: descriptor.reader, sourceLocations: descriptor.sourceLocations,
                sourceSignatureStrategy: descriptor.sourceSignatureStrategy,
                collectorRevision: 1,
                sourceLocationsResolver: {
                    try descriptor.resolvedSourceLocations().map(\.canonicalSelectedLocation)
                })
        }
    }
}

private extension LocalUsageReaderRegistry {
    private static func primaryDescriptors(
        paths: LocalUsageReaderPaths, codexCache: CodexRolloutUsageCache,
        claudeCache: ClaudeUsageCache, hermesLedger: HermesUsageLedger,
        cacheScope: LocalUsageCacheScope) -> [LocalUsageReaderDescriptor] {
        [
            LocalUsageReaderDescriptor(
                reader: ClaudeCodeReader(
                    projectsURLOverride: paths.claudeProjects,
                    usageCache: claudeCache,
                    transcriptsURLOverride: paths.claudeTranscripts,
                    attributionHomeDirectory: paths.homeDirectory),
                sourceLocations: [
                    .directory(paths.claudeProjects, extensions: ["jsonl"]),
                    .directory(paths.claudeTranscripts, extensions: ["jsonl"]),
                ],
                sourceSignatureStrategy: .boundedAllFiles(
                    maximumFileCount: PiCompatibleReadLimits.default.maximumFileCount,
                    maximumEntryCount: PiCompatibleReadLimits.default.maximumEntryCount)),
            LocalUsageReaderDescriptor(
                reader: CodexReader(
                    dbPath: paths.codexDatabase.path,
                    rolloutUsageCache: codexCache),
                sourceLocations: [
                    .file(paths.codexDatabase, includesSQLiteSidecars: true),
                    .directory(paths.codexSessions, extensions: ["jsonl"]),
                    .directory(paths.codexArchivedSessions, extensions: ["jsonl"]),
                ],
                sourceSignatureStrategy: .codexRollouts),
            hermesReaderDescriptor(paths: paths, usageLedger: hermesLedger, cacheScope: cacheScope),
            LocalUsageReaderDescriptor(
                reader: CursorReader(dbPathOverride: paths.cursorDatabase.path),
                sourceLocations: [.file(paths.cursorDatabase, includesSQLiteSidecars: true)]),
        ]
    }
}

extension LocalUsageReaderRegistry {
    private static func additionalDescriptors(
        paths: LocalUsageReaderPaths,
        environment: [String: String],
        copilotSourceLocations: [LocalUsageSourceLocation]) -> [LocalUsageReaderDescriptor] {
        let openCode = OpenCodeReader(homeDirectory: paths.homeDirectory, environment: environment)
        let openClaw = OpenClawReader(agentsRoots: OpenClawReader.defaultAgentsRoots(home: paths.homeDirectory))
        let grok = GrokReader(sessionRootsOverride: [paths.grokSessions])
        return [
            LocalUsageReaderDescriptor(
                reader: openCode,
                sourceLocations: [.directoryPresence(paths.openCodeDatabase.deletingLastPathComponent())],
                sourceSignatureStrategy: .allFiles,
                collectorRevision: 1,
                sourceLocationsResolver: openCode.selectedSourceLocations),
            LocalUsageReaderDescriptor(
                reader: openClaw,
                sourceLocations: openClaw.agentsRoots.map { .directoryPresence($0) },
                sourceSignatureStrategy: .allFiles,
                collectorRevision: 1,
                sourceLocationsResolver: openClaw.selectedSourceLocations),
            LocalUsageReaderDescriptor(
                reader: CopilotCLIReader(
                    otelDirectoryURLOverride: paths.copilotOTELDirectory,
                    exporterFileURLOverride: paths.copilotOTELExporterFile),
                sourceLocations: copilotSourceLocations,
                sourceSignatureStrategy: .allFiles),
            LocalUsageReaderDescriptor(
                reader: KimiCLIReader(sessionRoots: paths.kimiCLISessions),
                sourceLocations: paths.kimiCLISessions.map { .directory($0, extensions: ["jsonl"]) },
                sourceSignatureStrategy: .allFiles),
            LocalUsageReaderDescriptor(
                reader: KimiCodeReader(sessionRoots: paths.kimiCodeSessions),
                sourceLocations: paths.kimiCodeSessions.map { .directory($0, extensions: ["jsonl"]) },
                sourceSignatureStrategy: .allFiles),
            LocalUsageReaderDescriptor(
                reader: QwenCLIReader(projectRoots: paths.qwenProjects),
                sourceLocations: paths.qwenProjects.map { .directory($0, extensions: ["jsonl"]) },
                sourceSignatureStrategy: .allFiles),
            LocalUsageReaderDescriptor(
                reader: grok,
                sourceLocations: grok.sessionRoots.map { .directoryPresence($0) },
                sourceSignatureStrategy: .allFiles,
                collectorRevision: 1,
                sourceLocationsResolver: grok.selectedSourceLocations),
        ]
    }

    private static func piFamilyDescriptors(
        paths: LocalUsageReaderPaths) -> [LocalUsageReaderDescriptor] {
        let sharedOMPRoots = paths.ompSessionRoots.filter {
            directoriesShareStorage(paths.piSessions, $0)
        }
        let independentOMPRoots = paths.ompSessionRoots.filter { root in
            !sharedOMPRoots.contains { directoriesShareStorage(root, $0) }
        }
        var descriptors: [LocalUsageReaderDescriptor] = []
        if !sharedOMPRoots.isEmpty {
            descriptors.append(LocalUsageReaderDescriptor(
                reader: SharedPiOMPReader(sessionsURL: paths.piSessions),
                sourceLocations: [.directory(paths.piSessions, extensions: ["jsonl"])],
                sourceSignatureStrategy: .boundedAllFiles(
                    maximumFileCount: PiCompatibleReadLimits.default.maximumFileCount,
                    maximumEntryCount: PiCompatibleReadLimits.default.maximumEntryCount)))
        } else {
            descriptors.append(LocalUsageReaderDescriptor(
                reader: PiReader(sessionsURLOverride: paths.piSessions),
                sourceLocations: [.directory(paths.piSessions, extensions: ["jsonl"])],
                sourceSignatureStrategy: .boundedAllFiles(
                    maximumFileCount: PiCompatibleReadLimits.default.maximumFileCount,
                    maximumEntryCount: PiCompatibleReadLimits.default.maximumEntryCount)))
        }
        if !independentOMPRoots.isEmpty {
            descriptors.append(LocalUsageReaderDescriptor(
                reader: OMPReader(sessionRootsOverride: independentOMPRoots),
                sourceLocations: independentOMPRoots.map { .directory($0, extensions: ["jsonl"]) },
                sourceSignatureStrategy: .boundedAllFiles(
                    maximumFileCount: PiCompatibleReadLimits.default.maximumFileCount,
                    maximumEntryCount: PiCompatibleReadLimits.default.maximumEntryCount)))
        }
        descriptors.append(LocalUsageReaderDescriptor(
            reader: KimchiReader(sessionsURLOverride: paths.kimchiSessions),
            sourceLocations: [.directory(paths.kimchiSessions, extensions: ["jsonl"])],
            sourceSignatureStrategy: .boundedAllFiles(
                maximumFileCount: PiCompatibleReadLimits.default.maximumFileCount,
                maximumEntryCount: PiCompatibleReadLimits.default.maximumEntryCount)))
        return descriptors
    }

    private static func directoriesShareStorage(_ lhs: URL, _ rhs: URL) -> Bool {
        let resolvedLHS = lhs.resolvingSymlinksInPath().standardizedFileURL
        let resolvedRHS = rhs.resolvingSymlinksInPath().standardizedFileURL
        if resolvedLHS.path == resolvedRHS.path {
            return true
        }
        guard let lhsIdentity = directoryIdentity(resolvedLHS),
              let rhsIdentity = directoryIdentity(resolvedRHS) else {
            return false
        }
        return lhsIdentity == rhsIdentity
    }

    private static func directoryIdentity(_ url: URL) -> LocalUsageDirectoryIdentity? {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory),
              isDirectory.boolValue,
              let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              let systemNumber = (attributes[.systemNumber] as? NSNumber)?.uint64Value,
              let fileNumber = (attributes[.systemFileNumber] as? NSNumber)?.uint64Value else {
            return nil
        }
        return LocalUsageDirectoryIdentity(systemNumber: systemNumber, fileNumber: fileNumber)
    }
}

extension LocalUsageReaderRegistry {
    public static func readers(
        home: URL = homeDir(),
        environment: [String: String] = ProcessInfo.processInfo.environment,
        codexRolloutUsageCache: CodexRolloutUsageCache? = nil) -> [any TokenReader] {
        descriptors(
            home: home,
            environment: environment,
            codexRolloutUsageCache: codexRolloutUsageCache).map(\.reader)
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

private struct LocalUsageDirectoryIdentity: Equatable {
    let systemNumber: UInt64
    let fileNumber: UInt64
}
