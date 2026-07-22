import Foundation
import TokiSyncProtocol
import TokiUsageCore
import TokiUsageReaders

protocol AgentSnapshotBuilding {
    func build(configuration: AgentConfiguration, now: Date) async throws -> RemoteUsageSnapshot
    func contentDigest(_ snapshot: RemoteUsageSnapshot) throws -> String
    func resetCaches() async throws
    func sourceSignature(configuration: AgentConfiguration, now: Date) async throws -> String?
}

extension AgentSnapshotBuilding {
    func resetCaches() async throws {}

    func sourceSignature(configuration _: AgentConfiguration, now _: Date) async throws -> String? {
        nil
    }
}

struct AgentSnapshotBuilder: AgentSnapshotBuilding {
    private let homeDirectory: URL
    private let environment: [String: String]
    private let rolloutUsageCache: CodexRolloutUsageCache
    private let claudeUsageCache: ClaudeUsageCache
    private let readerDescriptors: [LocalUsageReaderDescriptor]
    private let retentionTimeZone: TimeZone

    init(
        home: URL = homeDir(),
        environment: [String: String] = ProcessInfo.processInfo.environment,
        rolloutUsageCache: CodexRolloutUsageCache? = nil,
        claudeUsageCache: ClaudeUsageCache? = nil,
        readerDescriptors: [LocalUsageReaderDescriptor]? = nil,
        retentionTimeZone: TimeZone = TimeZone(secondsFromGMT: 0) ?? .current) {
        let paths = LocalUsageReaderPaths(homeDirectory: home, environment: environment)
        let resolvedRolloutUsageCache = rolloutUsageCache
            ?? CodexRolloutUsageCache(
                cacheURL: paths.agentCacheDirectory.appendingPathComponent("codex-rollout-cache.json"))
        let resolvedClaudeUsageCache = claudeUsageCache
            ?? ClaudeUsageCache(cacheURL: claudeUsageCacheURL(paths: paths, scope: .agent))
        let agentLedgerURL = hermesUsageLedgerURL(paths: paths, scope: .agent)
        let resolvedHermesUsageLedger = HermesUsageLedger(fileURL: agentLedgerURL)

        homeDirectory = home
        self.environment = environment
        self.rolloutUsageCache = resolvedRolloutUsageCache
        self.claudeUsageCache = resolvedClaudeUsageCache
        self.retentionTimeZone = retentionTimeZone
        if let readerDescriptors {
            self.readerDescriptors = readerDescriptors
        } else {
            self.readerDescriptors = LocalUsageReaderRegistry.agentDescriptors(
                home: home,
                environment: environment,
                codexRolloutUsageCache: resolvedRolloutUsageCache,
                claudeUsageCache: resolvedClaudeUsageCache,
                hermesUsageLedger: resolvedHermesUsageLedger)
                .map { descriptor in
                    guard descriptor.name == HermesReader.sourceName else { return descriptor }
                    return LocalUsageReaderDescriptor(
                        reader: descriptor.reader,
                        sourceLocations: descriptor.sourceLocations + [
                            .file(agentLedgerURL, includesSQLiteSidecars: false),
                        ],
                        sourceSignatureStrategy: descriptor.sourceSignatureStrategy)
                }
        }
    }

    func build(configuration: AgentConfiguration, now: Date = Date()) async throws -> RemoteUsageSnapshot {
        let window = try retentionWindow(configuration: configuration, now: now)
        let coveredFrom = window.start
        let coveredTo = window.end
        let readerUsages = try await readUsages(from: coveredFrom, to: coveredTo)
        let identifierHasher = try SnapshotCipher.makeOpaqueIdentifierHasher(
            key: configuration.encryptionKey)

        let tokenEvents = readerUsages
            .flatMap(\.usage.tokenEvents)
            .filter { event in
                event.timestamp >= coveredFrom
                    && event.timestamp < coveredTo
            }
            .compactMap(remoteTokenEvent)
            .sorted(by: tokenEventSort)

        let activityEvents = readerUsages
            .flatMap { readerUsage in
                readerUsage.usage.activityEvents
                    .filter { $0.timestamp >= coveredFrom && $0.timestamp < coveredTo }
                    .map { event in
                        RemoteActivityEvent(
                            timestamp: event.timestamp,
                            source: readerUsage.name,
                            model: remoteModel(event.key),
                            streamID: identifierHasher.identifier(
                                for: "\(readerUsage.name)\u{0}\(event.streamID)"),
                            agentKind: event.agentKind == .subagent ? .subagent : .main)
                    }
            }
            .sorted(by: activityEventSort)

        return RemoteUsageSnapshot(
            device: RemoteDeviceDescriptor(
                id: configuration.deviceID,
                name: configuration.deviceName,
                platform: platformName),
            generatedAt: now,
            coveredFrom: coveredFrom,
            coveredTo: coveredTo,
            tokenEvents: tokenEvents,
            activityEvents: activityEvents)
    }

    func contentDigest(_ snapshot: RemoteUsageSnapshot) throws -> String {
        let content = AgentSnapshotContent(
            device: snapshot.device,
            coveredFrom: snapshot.coveredFrom,
            coveredTo: snapshot.coveredTo,
            tokenEvents: snapshot.tokenEvents,
            activityEvents: snapshot.activityEvents)
        return try SnapshotCipher.digest(TokiSyncCoding.makeEncoder().encode(content))
    }

    func resetCaches() async throws {
        do {
            try await rolloutUsageCache.reset()
            try await claudeUsageCache.reset()
        } catch {
            throw AgentSnapshotBuilderError.cacheResetFailed
        }
    }

    func sourceSignature(configuration: AgentConfiguration, now: Date) async throws -> String? {
        let window = try retentionWindow(configuration: configuration, now: now)
        let sources = try readerDescriptors.map { descriptor in
            let records: [String] = switch descriptor.sourceSignatureStrategy {
            case .standard:
                try standardSourceRecords(
                    locations: descriptor.sourceLocations,
                    modifiedOnOrAfter: window.start)
            case .codexRollouts:
                try codexSourceRecords(window: window)
            }
            return AgentSourceSignature.Source(
                reader: descriptor.name,
                records: records.sorted())
        }
        .sorted { $0.reader < $1.reader }

        let document = AgentSourceSignature(
            coveredFrom: window.start,
            coveredTo: window.end,
            sources: sources)
        return try SnapshotCipher.digest(TokiSyncCoding.makeEncoder().encode(document))
    }
}

private extension AgentSnapshotBuilder {
    private func readUsages(from startDate: Date, to endDate: Date) async throws -> [AgentReaderUsage] {
        try await withThrowingTaskGroup(of: AgentReaderUsage.self) { group in
            for (index, descriptor) in readerDescriptors.enumerated() {
                group.addTask {
                    do {
                        let usage = try await descriptor.reader.readUsage(from: startDate, to: endDate)
                        return AgentReaderUsage(index: index, name: descriptor.name, usage: usage)
                    } catch is CancellationError {
                        throw CancellationError()
                    } catch {
                        throw AgentSnapshotBuilderError.readerFailed(descriptor.name)
                    }
                }
            }

            var results: [AgentReaderUsage] = []
            for try await result in group {
                results.append(result)
            }
            return results.sorted { $0.index < $1.index }
        }
    }

    private func retentionWindow(configuration: AgentConfiguration, now: Date) throws -> DateInterval {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = retentionTimeZone
        let today = calendar.startOfDay(for: now)
        guard let coveredTo = calendar.date(byAdding: .day, value: 1, to: today),
              let coveredFrom = calendar.date(
                  byAdding: .day,
                  value: 1 - configuration.retentionDays,
                  to: today) else {
            throw AgentSnapshotBuilderError.invalidDateRange
        }
        return DateInterval(start: coveredFrom, end: coveredTo)
    }

    private func standardSourceRecords(
        locations: [LocalUsageSourceLocation],
        modifiedOnOrAfter minimumDate: Date) throws -> [String] {
        var records: [String] = []
        for location in locations {
            switch location {
            case let .file(url, includesSQLiteSidecars):
                try records.append(fileSignatureRecord(url))
                if includesSQLiteSidecars {
                    try records.append(fileSignatureRecord(URL(fileURLWithPath: url.path + "-wal")))
                    try records.append(fileSignatureRecord(URL(fileURLWithPath: url.path + "-shm")))
                }
            case let .directory(url, extensions):
                try records.append(directoryPresenceRecord(url))
                try records.append(contentsOf: retainedFiles(
                    in: url,
                    extensions: extensions,
                    modifiedOnOrAfter: minimumDate)
                    .map(fileSignatureRecord))
            }
        }
        return records
    }

    private func codexSourceRecords(window: DateInterval) throws -> [String] {
        let paths = LocalUsageReaderPaths(homeDirectory: homeDirectory, environment: environment)
        let databaseURL = paths.codexDatabase
        var sourceURLs: Set<URL> = [
            databaseURL,
            URL(fileURLWithPath: databaseURL.path + "-wal"),
            URL(fileURLWithPath: databaseURL.path + "-shm"),
        ]

        let reader = CodexReader(
            dbPath: databaseURL.path,
            rolloutUsageCache: rolloutUsageCache)
        sourceURLs.formUnion(reader.databaseRolloutPaths(from: window.start, to: window.end).map {
            URL(fileURLWithPath: $0).standardizedFileURL
        })
        for directory in retainedSessionDirectories(window: window) {
            sourceURLs.insert(directory)
            try sourceURLs.formUnion(jsonlFiles(in: directory))
        }
        try sourceURLs.formUnion(jsonlFiles(
            in: paths.codexArchivedSessions,
            modifiedOnOrAfter: window.start))

        return try sourceURLs.map(fileSignatureRecord)
    }

    private func retainedSessionDirectories(window: DateInterval) -> [URL] {
        let calendar = Calendar.autoupdatingCurrent
        let startDay = calendar.startOfDay(for: window.start)
        let endDay = calendar.startOfDay(for: window.end)
        let retainedDayCount = calendar.dateComponents([.day], from: startDay, to: endDay).day ?? 0
        return (Array(-3..<0) + Array(0...max(0, retainedDayCount))).compactMap { offset in
            guard let day = calendar.date(byAdding: .day, value: offset, to: startDay) else { return nil }
            let components = calendar.dateComponents([.year, .month, .day], from: day)
            return homeDirectory
                .appendingPathComponent(".codex/sessions")
                .appendingPathComponent(String(format: "%04d", components.year ?? 0))
                .appendingPathComponent(String(format: "%02d", components.month ?? 0))
                .appendingPathComponent(String(format: "%02d", components.day ?? 0))
        }
    }

    private func retainedFiles(
        in directory: URL,
        extensions: Set<String>,
        modifiedOnOrAfter minimumDate: Date) throws -> Set<URL> {
        guard FileManager.default.fileExists(atPath: directory.path) else { return [] }

        var inspectionFailed = false
        guard let enumerator = FileManager.default.enumerator(
            at: directory,
            includingPropertiesForKeys: [
                .contentModificationDateKey,
                .isDirectoryKey,
                .isRegularFileKey,
                .isSymbolicLinkKey,
            ],
            options: [.skipsHiddenFiles],
            errorHandler: { _, _ in
                inspectionFailed = true
                return false
            }) else {
            throw AgentSnapshotBuilderError.sourceInspectionFailed
        }

        var files: Set<URL> = []
        for case let fileURL as URL in enumerator {
            let values: URLResourceValues
            do {
                values = try fileURL.resourceValues(forKeys: [
                    .contentModificationDateKey,
                    .isDirectoryKey,
                    .isRegularFileKey,
                    .isSymbolicLinkKey,
                ])
            } catch {
                throw AgentSnapshotBuilderError.sourceInspectionFailed
            }
            if values.isSymbolicLink == true {
                if values.isDirectory == true {
                    enumerator.skipDescendants()
                }
                continue
            }
            guard values.isRegularFile == true,
                  extensions.contains(fileURL.pathExtension),
                  values.contentModificationDate.map({ $0 >= minimumDate }) == true else {
                continue
            }
            files.insert(fileURL.standardizedFileURL)
        }
        guard !inspectionFailed else {
            throw AgentSnapshotBuilderError.sourceInspectionFailed
        }
        return files
    }

    private func jsonlFiles(in directory: URL, modifiedOnOrAfter minimumDate: Date? = nil) throws -> Set<URL> {
        guard FileManager.default.fileExists(atPath: directory.path) else { return [] }
        let files: [URL]
        do {
            files = try FileManager.default.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: [
                    .contentModificationDateKey,
                    .isRegularFileKey,
                    .isSymbolicLinkKey,
                ],
                options: [.skipsHiddenFiles])
        } catch {
            throw AgentSnapshotBuilderError.sourceInspectionFailed
        }
        return try Set(files.compactMap { fileURL in
            guard fileURL.pathExtension == "jsonl" else { return nil }
            let values = try fileURL.resourceValues(forKeys: [
                .contentModificationDateKey,
                .isRegularFileKey,
                .isSymbolicLinkKey,
            ])
            let isRecentEnough = minimumDate.map { minimumDate in
                values.contentModificationDate.map { $0 >= minimumDate } == true
            } ?? true
            guard values.isRegularFile == true,
                  values.isSymbolicLink != true,
                  isRecentEnough else {
                return nil
            }
            return fileURL.standardizedFileURL
        })
    }

    private func directoryPresenceRecord(_ url: URL) throws -> String {
        let normalizedURL = url.standardizedFileURL
        let pathDigest = SnapshotCipher.digest(normalizedURL.path)
        guard FileManager.default.fileExists(atPath: normalizedURL.path) else {
            return "\(pathDigest):missing"
        }
        let values: URLResourceValues
        do {
            values = try normalizedURL.resourceValues(forKeys: [.isDirectoryKey])
        } catch {
            throw AgentSnapshotBuilderError.sourceInspectionFailed
        }
        guard values.isDirectory == true else {
            throw AgentSnapshotBuilderError.sourceInspectionFailed
        }
        return "\(pathDigest):directory"
    }

    private func fileSignatureRecord(_ url: URL) throws -> String {
        let normalizedURL = url.standardizedFileURL
        let pathDigest = SnapshotCipher.digest(normalizedURL.path)
        guard FileManager.default.fileExists(atPath: normalizedURL.path) else {
            return "\(pathDigest):missing"
        }
        let attributes: [FileAttributeKey: Any]
        do {
            attributes = try FileManager.default.attributesOfItem(atPath: normalizedURL.path)
        } catch {
            throw AgentSnapshotBuilderError.sourceInspectionFailed
        }
        let type = (attributes[.type] as? FileAttributeType)?.rawValue ?? "unknown"
        let size = (attributes[.size] as? NSNumber)?.uint64Value ?? 0
        let modified = (attributes[.modificationDate] as? Date)?.timeIntervalSince1970.bitPattern ?? 0
        let fileNumber = (attributes[.systemFileNumber] as? NSNumber)?.uint64Value ?? 0
        return "\(pathDigest):\(type):\(size):\(modified):\(fileNumber)"
    }

    private func tokenEventSort(_ lhs: RemoteTokenEvent, _ rhs: RemoteTokenEvent) -> Bool {
        if lhs.timestamp != rhs.timestamp { return lhs.timestamp < rhs.timestamp }
        if lhs.source != rhs.source { return lhs.source < rhs.source }
        if lhs.model != rhs.model { return (lhs.model ?? "") < (rhs.model ?? "") }
        if lhs.inputTokens != rhs.inputTokens { return lhs.inputTokens < rhs.inputTokens }
        if lhs.outputTokens != rhs.outputTokens { return lhs.outputTokens < rhs.outputTokens }
        if lhs.cacheReadTokens != rhs.cacheReadTokens { return lhs.cacheReadTokens < rhs.cacheReadTokens }
        if lhs.cacheWriteTokens != rhs.cacheWriteTokens { return lhs.cacheWriteTokens < rhs.cacheWriteTokens }
        return lhs.reasoningTokens < rhs.reasoningTokens
    }

    private func activityEventSort(_ lhs: RemoteActivityEvent, _ rhs: RemoteActivityEvent) -> Bool {
        if lhs.timestamp != rhs.timestamp { return lhs.timestamp < rhs.timestamp }
        if lhs.source != rhs.source { return lhs.source < rhs.source }
        if lhs.model != rhs.model { return (lhs.model ?? "") < (rhs.model ?? "") }
        if lhs.streamID != rhs.streamID { return lhs.streamID < rhs.streamID }
        return lhs.agentKind.rawValue < rhs.agentKind.rawValue
    }

    private func remoteModel(_ model: String?) -> String? {
        guard let model,
              TokiSyncValidation.isSafeDisplayText(
                  model,
                  maximumLength: RemoteUsageSnapshotValidator.maximumModelLength) else {
            return nil
        }
        return model
    }

    private func remoteTokenEvent(_ event: TokenUsageEvent) -> RemoteTokenEvent? {
        let counts = [
            event.inputTokens,
            event.outputTokens,
            event.cacheReadTokens,
            event.cacheWriteTokens,
            event.reasoningTokens,
        ]
        let validRange = 0...RemoteUsageSnapshotValidator.maximumTokenCountPerBucket
        guard counts.allSatisfy(validRange.contains),
              counts.contains(where: { $0 > 0 }) else {
            return nil
        }
        return RemoteTokenEvent(
            timestamp: event.timestamp,
            source: event.source,
            model: remoteModel(event.model),
            inputTokens: event.inputTokens,
            outputTokens: event.outputTokens,
            cacheReadTokens: event.cacheReadTokens,
            cacheWriteTokens: event.cacheWriteTokens,
            reasoningTokens: event.reasoningTokens)
    }

    private var platformName: String {
        #if os(Linux)
            "linux"
        #elseif os(macOS)
            "macos"
        #else
            "unknown"
        #endif
    }
}

private struct AgentReaderUsage {
    let index: Int
    let name: String
    let usage: RawTokenUsage
}

private struct AgentSnapshotContent: Encodable {
    let device: RemoteDeviceDescriptor
    let coveredFrom: Date
    let coveredTo: Date
    let tokenEvents: [RemoteTokenEvent]
    let activityEvents: [RemoteActivityEvent]
}

private struct AgentSourceSignature: Encodable {
    struct Source: Encodable {
        let reader: String
        let records: [String]
    }

    let coveredFrom: Date
    let coveredTo: Date
    let sources: [Source]
}

enum AgentSnapshotBuilderError: LocalizedError {
    case cacheResetFailed
    case invalidDateRange
    case readerFailed(String)
    case sourceInspectionFailed

    var errorDescription: String? {
        switch self {
        case .cacheResetFailed:
            "Could not safely reset the local usage parse caches."
        case .invalidDateRange:
            "Could not construct the configured retention window."
        case let .readerFailed(name):
            "The \(name) usage reader failed. The previous remote snapshot was preserved."
        case .sourceInspectionFailed:
            "Could not inspect local usage source metadata. Run `toki-agent doctor`."
        }
    }
}
