import Foundation
import TokiSyncProtocol
import TokiUsageCore

public struct GJCReader: TokenReader {
    public static let sourceName = "GJC"

    public let name = Self.sourceName
    private let sessionRoots: [URL]
    private let legacySessionsURL: URL?
    private let sharedOMPSessionRoots: [URL]
    private let sharedPiSessionRoots: [URL]
    private let usageFileCache: PiCompatibleUsageFileCache

    public init(sessionsURLOverride: URL? = nil) {
        let sessionsURL = sessionsURLOverride ?? homeDir().appendingPathComponent(".gjc/agent/sessions")
        sessionRoots = [sessionsURL]
        legacySessionsURL = sessionsURL
        sharedOMPSessionRoots = []
        sharedPiSessionRoots = []
        usageFileCache = .shared
    }

    public init(
        sessionRootsOverride: [URL], legacySessionsURL: URL? = nil,
        sharedOMPSessionRoots: [URL] = [], sharedPiSessionRoots: [URL] = []) {
        sessionRoots = sessionRootsOverride
        self.legacySessionsURL = legacySessionsURL
        self.sharedOMPSessionRoots = sharedOMPSessionRoots
        self.sharedPiSessionRoots = sharedPiSessionRoots
        usageFileCache = .shared
    }

    init(
        sessionsURLOverride: URL,
        usageFileCache: PiCompatibleUsageFileCache) {
        sessionRoots = [sessionsURLOverride]
        legacySessionsURL = sessionsURLOverride
        sharedOMPSessionRoots = []
        sharedPiSessionRoots = []
        self.usageFileCache = usageFileCache
    }

    public func readUsage(from startDate: Date, to endDate: Date) async throws -> RawTokenUsage {
        let limits = PiCompatibleReadLimits.default
        let groups = try discoveredFiles(limits: limits)
        usageFileCache.retainFiles(groups.flatMap(\.files), source: .gjc)
        var result = RawTokenUsage()
        var activityEvents: [ActivityTimeEvent<String>] = []
        var recordCount = 0
        var eventCount = 0
        for (root, files) in groups {
            var recordsByKey: [PiCompatibleDeduplicationKey: PiCompatibleUsageRecord] = [:]
            for file in files {
                try Task.checkCancellation()
                let (records, observedCount) = try selectedRecords(for: file, limits: limits)
                try recordUsageEvents(
                    observedCount, total: &recordCount, maximum: limits.maximumUnreconciledEventCount)
                for record in records {
                    recordsByKey[record.deduplicationKey] = recordsByKey[record.deduplicationKey]
                        .map { $0.merged(with: record) } ?? record
                }
            }
            Self.enrichResponseProviders(in: &recordsByKey)
            let records = mergeAliasedRecords(recordsByKey.values)
            try recordUsageEvents(records.count, total: &eventCount, maximum: limits.maximumEventCount)
            let isLegacyRoot = legacySessionsURL?.resolvingSymlinksInPath().standardizedFileURL.path == root.path
            let namespace = isLegacyRoot ? "" : "gjc:\(SnapshotCipher.digest(Data(root.path.utf8))):"
            for record in records.sorted(by: {
                if $0.timestamp != $1.timestamp { return $0.timestamp < $1.timestamp }
                return $0.deduplicationKey.isOrdered(before: $1.deduplicationKey)
            })
                where record.timestamp >= startDate && record.timestamp < endDate {
                try Task.checkCancellation()
                let session = record.attribution.sessionID ?? record.model
                let scopedSession = namespace + session
                let attribution = UsageAttribution(
                    projectPath: record.attribution.projectPath,
                    projectName: record.attribution.projectName,
                    sessionID: scopedSession,
                    sessionLabel: record.attribution.sessionLabel,
                    quality: record.attribution.quality)
                Self.accumulate(record, attribution: attribution, into: &result)
                activityEvents.append(ActivityTimeEvent(
                    streamID: scopedSession,
                    timestamp: record.timestamp,
                    key: UsageModelGrouping.groupingKey(for: record.model),
                    agentKind: record.agentKind))
            }
        }
        try Task.checkCancellation()
        result.mergeActivityEvents(activityEvents, source: name, clippingEndDate: endDate)
        return result
    }

    private func discoveredFiles(limits: PiCompatibleReadLimits) throws -> [(root: URL, files: [URL])] {
        try Task.checkCancellation()
        var visitedEntryCount = 0
        var fileCount = 0
        return try selectedSessionRoots().map { root in
            let files = try findUsageFiles(
                in: root,
                withExtension: "jsonl",
                maximumFileCount: limits.maximumFileCount + 1,
                maximumEntryCount: limits.maximumEntryCount,
                visitedEntryCount: &visitedEntryCount)
            fileCount += files.count
            guard fileCount <= limits.maximumFileCount else {
                throw PiCompatibleReaderError.tooManyFiles(fileCount)
            }
            return (root, files.sorted { $0.path < $1.path })
        }
    }

    package func selectedSessionRoots() -> [URL] {
        let roots = Set(sessionRoots.map {
            URL(fileURLWithPath: $0.resolvingSymlinksInPath().standardizedFileURL.path, isDirectory: true)
        })
        .sorted { $0.path < $1.path }
        return roots.filter { root in
            !roots.contains { $0 != root && root.pathComponents.starts(with: $0.pathComponents) }
        }
    }

    private func selectedRecords(
        for file: URL, limits: PiCompatibleReadLimits) throws -> ([PiCompatibleUsageRecord], Int) {
        guard let owner = sharedSource(for: file) else {
            let records = try usageFileCache.records(for: file, source: .gjc, agentKind: .main, limits: limits)
            return (records, records.count)
        }
        // Shared roots can also contain headerless, model-less and task GJC records.
        // Let the actual owning parser select common lines, preserving GJC-only lines.
        var gjc = PiCompatibleSessionParser(streamID: file.path, source: .gjc, agentKind: .main)
        var shared = PiCompatibleSessionParser(streamID: file.path, source: owner, agentKind: .main)
        var records: [PiCompatibleUsageRecord] = []
        var observedCount = 0
        try forEachBoundedJSONLLine(at: file, limits: limits) { line, index in
            let common = shared.record(fromJSONLLine: line, lineIndex: index)
            guard let record = gjc.record(fromJSONLLine: line, lineIndex: index) else { return }
            try recordUsageEvents(1, total: &observedCount, maximum: limits.maximumEventCount)
            if common == nil { records.append(record) }
        }
        return (records, observedCount)
    }

    private func sharedSource(for file: URL) -> PiCompatibleSource? {
        let components = file.resolvingSymlinksInPath().standardizedFileURL.pathComponents
        func contains(_ roots: [URL]) -> Bool {
            roots.contains { components.starts(with: $0.resolvingSymlinksInPath().standardizedFileURL.pathComponents) }
        }
        let pi = contains(sharedPiSessionRoots)
        let omp = contains(sharedOMPSessionRoots)
        if pi, omp { return .piAndOhMyPi }
        if pi { return .pi }
        return omp ? .ohMyPi : nil
    }

    private static func accumulate(
        _ record: PiCompatibleUsageRecord, attribution: UsageAttribution, into result: inout RawTokenUsage) {
        let model = record.model == UsageModelGrouping.mixedOrUnattributedKey ? nil : record.model
        result.inputTokens += record.inputTokens
        result.outputTokens += record.outputTokens
        result.cacheReadTokens += record.cacheReadTokens
        result.cacheWriteTokens += record.cacheWriteTokens
        result.reasoningTokens += record.reasoningTokens
        result.cost += record.cost
        result.accumulatePerModelUsage(
            model: model, source: sourceName, totalTokens: record.totalTokens, cost: record.cost)
        result.recordTokenEvent(
            timestamp: record.timestamp,
            source: sourceName,
            model: model,
            provider: record.provider,
            inputTokens: record.inputTokens,
            outputTokens: record.outputTokens,
            cacheReadTokens: record.cacheReadTokens,
            cacheWriteTokens: record.cacheWriteTokens,
            reasoningTokens: record.reasoningTokens,
            cost: record.cost,
            costIsKnown: record.costIsKnown,
            attribution: attribution)
    }

    /// Match the existing Pi-compatible response enrichment within each independent root.
    private static func enrichResponseProviders(
        in records: inout [PiCompatibleDeduplicationKey: PiCompatibleUsageRecord]) {
        var providers: [PiCompatibleResponseScope: Set<String>] = [:]
        for key in records.keys {
            if case let .sessionResponse(session, provider?, response) = key {
                providers[PiCompatibleResponseScope(sessionID: session, responseID: response), default: []]
                    .insert(provider)
            }
        }
        for key in Array(records.keys) {
            guard case let .sessionResponse(session, nil, response) = key,
                  let record = records[key],
                  let candidates = providers[PiCompatibleResponseScope(sessionID: session, responseID: response)],
                  candidates.count == 1, let provider = candidates.first else { continue }
            let enriched = PiCompatibleDeduplicationKey.sessionResponse(
                sessionID: session, provider: provider, responseID: response)
            records[enriched] = records[enriched].map { $0.merged(with: record) } ?? record
            records.removeValue(forKey: key)
        }
    }

    static func usage(
        fromJSONLLines lines: [String],
        streamID: String,
        from startDate: Date,
        to endDate: Date) -> RawTokenUsage {
        PiCompatibleReader.usage(
            fromJSONLLines: lines,
            streamID: streamID,
            source: .gjc,
            from: startDate,
            to: endDate)
    }
}

package extension GJCReader {
    func sharedSelectionIdentity() -> String {
        func identity(_ roots: [URL]) -> String {
            roots.map { $0.resolvingSymlinksInPath().standardizedFileURL.path }.sorted()
                .map { "\($0.utf8.count):\($0)" }.joined()
        }
        return "pi:\(identity(sharedPiSessionRoots)):omp:\(identity(sharedOMPSessionRoots))"
    }
}
