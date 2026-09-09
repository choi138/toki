import Foundation
import TokiSyncProtocol
import TokiUsageCore

/// Reads Grok CLI per-session usage records.
public struct GrokReader: TokenReader {
    public static let sourceName = "Grok CLI"

    public let name = Self.sourceName
    public let sessionRoots: [URL]
    private let limits: PiCompatibleReadLimits

    public init(sessionRootsOverride: [URL]) {
        self.init(sessionRoots: sessionRootsOverride, limits: .default)
    }

    public init(
        homeDirectory: URL = homeDir(),
        environment: [String: String] = ProcessInfo.processInfo.environment) {
        self.init(
            sessionRoots: Self.defaultSessionRoots(home: homeDirectory, environment: environment),
            limits: .default)
    }

    init(sessionRoots: [URL], limits: PiCompatibleReadLimits) {
        self.sessionRoots = sessionRoots
        self.limits = limits
    }

    public static func defaultSessionRoots(
        home: URL = homeDir(),
        environment: [String: String] = ProcessInfo.processInfo.environment) -> [URL] {
        [LocalUsageReaderPaths(homeDirectory: home, environment: environment).grokSessions]
    }

    package func selectedSourceLocations() throws -> [LocalUsageSourceLocation] {
        let roots = sessionRoots.map {
            LocalUsageSourceLocation.directoryPresence($0).canonicalSelectedLocation
        }
        let sessions = try GrokSessionDiscovery.sessions(in: sessionRoots, limits: limits)
        return roots + sessions.flatMap { session in
            [session.usageURL, session.summaryURL].map {
                LocalUsageSourceLocation.file($0, includesSQLiteSidecars: false).canonicalSelectedLocation
            }
        }
    }

    public func readUsage(from startDate: Date, to endDate: Date) async throws -> RawTokenUsage {
        try Task.checkCancellation()
        guard startDate < endDate else { return RawTokenUsage() }
        let sessions = try GrokSessionDiscovery.sessions(in: sessionRoots, limits: limits)
        let decoder = JSONDecoder()
        var result = RawTokenUsage()
        var activityEvents: [ActivityTimeEvent<String>] = []
        var examinedEventCount = 0

        for session in sessions {
            try Task.checkCancellation()
            let data = try boundedUsageFileData(at: session.usageURL, maximumBytes: limits.maximumFileBytes)
            guard let document = try? decoder.decode(GrokUsageDocument.self, from: data) else { continue }
            let fallbackDate = (try? session.usageURL.resourceValues(
                forKeys: [.contentModificationDateKey]))?.contentModificationDate
            let records = grokUsageRecords(document, fallbackDate: fallbackDate)
            try recordUsageEvents(records.count, total: &examinedEventCount, maximum: limits.maximumEventCount)
            guard !records.isEmpty else { continue }
            let summary = grokSessionSummary(
                at: session.summaryURL, maximumBytes: limits.maximumFileBytes, decoder: decoder)
            let streamID = "grokcli:" + SnapshotCipher.digest(document.sessionId ?? session.sessionID)
            let attribution = UsageAttribution(
                projectPath: summary?.info?.cwd ?? session.projectPath,
                sessionID: streamID,
                sessionLabel: summary?.generatedTitle,
                quality: .exact)

            for record in records where record.date >= startDate && record.date < endDate {
                try Task.checkCancellation()
                guard let totalTokens = result.accumulateTokenCounts(
                    input: record.tokens.input,
                    output: record.tokens.output,
                    cacheRead: record.tokens.cacheRead,
                    cacheWrite: record.tokens.cacheWrite,
                    reasoning: record.tokens.reasoning) else { continue }
                guard totalTokens > 0 || record.cost > 0 else { continue }
                result.cost += record.cost
                result.accumulatePerModelUsage(
                    model: record.model,
                    source: Self.sourceName,
                    totalTokens: totalTokens,
                    cost: record.cost)
                result.recordTokenEvent(
                    timestamp: record.date,
                    source: Self.sourceName,
                    model: record.model,
                    provider: inferredUsageProvider(from: record.model),
                    inputTokens: record.tokens.input,
                    outputTokens: record.tokens.output,
                    cacheReadTokens: record.tokens.cacheRead,
                    cacheWriteTokens: record.tokens.cacheWrite,
                    reasoningTokens: record.tokens.reasoning,
                    cost: record.cost,
                    costIsKnown: record.costIsKnown,
                    attribution: attribution)
                if totalTokens > 0 {
                    activityEvents.append(ActivityTimeEvent(
                        streamID: streamID,
                        timestamp: record.date,
                        key: UsageModelGrouping.groupingKey(for: record.model)))
                }
            }
        }

        try Task.checkCancellation()
        result.tokenEvents.sort { $0.timestamp < $1.timestamp }
        result.mergeActivityEvents(activityEvents, source: Self.sourceName, clippingEndDate: endDate)
        return result
    }
}

// MARK: - Discovery

struct GrokSessionSource: Equatable {
    let usageURL: URL
    let summaryURL: URL
    let sessionID: String
    let projectPath: String?
}

enum GrokSessionDiscovery {
    /// Grok writes `sessions/<percent-encoded cwd>/<session id>/usage.json`. The depth is fixed
    /// so a session's `subagents/<id>/` children are never mistaken for sessions of their own;
    /// each subagent already owns a top-level session directory with its own usage record.
    static func sessions(
        in roots: [URL],
        limits: PiCompatibleReadLimits) throws -> [GrokSessionSource] {
        var visitedEntryCount = 0
        var canonicalPaths = Set<String>()
        var sessions: [GrokSessionSource] = []
        for root in roots {
            try Task.checkCancellation()
            for projectDirectory in try childDirectories(of: root, visitedEntryCount: &visitedEntryCount) {
                for sessionDirectory in try childDirectories(
                    of: projectDirectory, visitedEntryCount: &visitedEntryCount) {
                    let usageURL = sessionDirectory.appendingPathComponent("usage.json")
                    guard isRegularFile(usageURL) else { continue }
                    let canonicalPath = usageURL.resolvingSymlinksInPath().standardizedFileURL.path
                    guard canonicalPaths.insert(canonicalPath).inserted else { continue }
                    guard sessions.count < limits.maximumFileCount else {
                        throw PiCompatibleReaderError.tooManyFiles(sessions.count + 1)
                    }
                    sessions.append(GrokSessionSource(
                        usageURL: usageURL,
                        summaryURL: sessionDirectory.appendingPathComponent("summary.json"),
                        sessionID: sessionDirectory.lastPathComponent,
                        projectPath: decodedProjectPath(projectDirectory.lastPathComponent)))
                }
            }
        }
        return sessions.sorted { $0.usageURL.path < $1.usageURL.path }
    }

    private static func childDirectories(
        of directory: URL,
        visitedEntryCount: inout Int) throws -> [URL] {
        let keys: [URLResourceKey] = [.isDirectoryKey, .isSymbolicLinkKey, .isHiddenKey]
        let entries: [URL]
        do {
            entries = try FileManager.default.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: keys,
                options: [.skipsHiddenFiles])
        } catch {
            let cocoaError = error as NSError
            guard cocoaError.domain == NSCocoaErrorDomain,
                  cocoaError.code == CocoaError.fileReadNoSuchFile.rawValue
                  || cocoaError.code == CocoaError.fileNoSuchFile.rawValue else {
                throw UsageFileDiscoveryError.cannotEnumerateRoot
            }
            return []
        }
        var directories: [URL] = []
        for entry in entries {
            let (nextEntryCount, overflow) = visitedEntryCount.addingReportingOverflow(1)
            guard !overflow, nextEntryCount <= PiCompatibleReadLimits.default.maximumEntryCount else {
                throw PiCompatibleReaderError.tooManyEntries(overflow ? Int.max : nextEntryCount)
            }
            visitedEntryCount = nextEntryCount
            guard let values = try? entry.resourceValues(forKeys: Set(keys)) else {
                throw UsageFileDiscoveryError.cannotReadEntryMetadata
            }
            guard values.isSymbolicLink != true,
                  values.isDirectory == true,
                  !entry.lastPathComponent.hasPrefix(".") else { continue }
            directories.append(entry)
        }
        return directories.sorted { $0.path < $1.path }
    }

    private static func isRegularFile(_ url: URL) -> Bool {
        guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey]) else {
            return false
        }
        return values.isRegularFile == true && values.isSymbolicLink != true
    }

    private static func decodedProjectPath(_ component: String) -> String? {
        guard let decoded = component.removingPercentEncoding, decoded.hasPrefix("/") else { return nil }
        return decoded
    }
}

// MARK: - Records

private struct GrokTokenCounts: Equatable {
    let input: Int
    let output: Int
    let cacheRead: Int
    let cacheWrite: Int
    let reasoning: Int

    /// Grok reports `cachedReadTokens` inside `inputTokens` and `reasoningTokens` inside
    /// `outputTokens`, while `RawTokenUsage` sums the five buckets as disjoint categories.
    /// Clamping keeps the split non-negative if a future format stops nesting them.
    init(counts: GrokUsageCounts) {
        let rawInput = max(0, counts.inputTokens ?? 0)
        let rawOutput = max(0, counts.outputTokens ?? 0)
        cacheRead = min(max(0, counts.cachedReadTokens ?? 0), rawInput)
        reasoning = min(max(0, counts.reasoningTokens ?? 0), rawOutput)
        input = rawInput - cacheRead
        output = rawOutput - reasoning
        cacheWrite = max(0, counts.cacheCreationTokens ?? 0)
    }
}

private struct GrokUsageRecord {
    let date: Date
    let model: String?
    let tokens: GrokTokenCounts
    let cost: Double
    let costIsKnown: Bool
}

/// One tick is a billionth of a US dollar.
private let grokCostTicksPerUSD = 1_000_000_000.0

private func grokUsageRecords(
    _ document: GrokUsageDocument,
    fallbackDate: Date?) -> [GrokUsageRecord] {
    let documentDate = document.updatedAt.flatMap(DateParser.parse) ?? fallbackDate
    guard let turns = document.turns, !turns.isEmpty else {
        guard let session = document.session, let date = documentDate else { return [] }
        return grokRecords(from: session, date: date)
    }
    return turns.flatMap { turn -> [GrokUsageRecord] in
        guard let date = turn.endedAt.flatMap(DateParser.parse) ?? documentDate else { return [] }
        return grokRecords(from: turn, date: date)
    }
}

private func grokRecords(from counts: GrokUsageCounts, date: Date) -> [GrokUsageRecord] {
    guard let modelUsage = counts.modelUsage, !modelUsage.isEmpty else {
        return [grokRecord(from: counts, model: counts.primaryModelId, date: date)]
    }
    return modelUsage.keys.sorted().map {
        grokRecord(from: modelUsage[$0] ?? counts, model: $0, date: date)
    }
}

private func grokRecord(from counts: GrokUsageCounts, model: String?, date: Date) -> GrokUsageRecord {
    let ticks = counts.costUsdTicks.flatMap { $0 >= 0 ? $0 : nil }
    return GrokUsageRecord(
        date: date,
        model: normalizedModelID(model),
        tokens: GrokTokenCounts(counts: counts),
        cost: ticks.map { Double($0) / grokCostTicksPerUSD } ?? 0,
        costIsKnown: ticks != nil)
}

private func grokSessionSummary(
    at url: URL,
    maximumBytes: Int,
    decoder: JSONDecoder) -> GrokSessionSummary? {
    guard let data = try? boundedUsageFileData(at: url, maximumBytes: maximumBytes) else { return nil }
    return try? decoder.decode(GrokSessionSummary.self, from: data)
}

// MARK: - Decoding

private struct GrokUsageDocument: Decodable {
    let sessionId: String?
    let updatedAt: String?
    let session: GrokUsageCounts?
    let turns: [GrokUsageCounts]?

    enum CodingKeys: String, CodingKey {
        case sessionId, updatedAt, session, turns
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        sessionId = try? container.decodeIfPresent(String.self, forKey: .sessionId)
        updatedAt = try? container.decodeIfPresent(String.self, forKey: .updatedAt)
        session = try? container.decodeIfPresent(GrokUsageCounts.self, forKey: .session)
        turns = (try? container.decodeIfPresent(LossyArray<GrokUsageCounts>.self, forKey: .turns))?.elements
    }
}

/// Grok repeats the same token/cost field names at the session, turn, and per-model levels.
private struct GrokUsageCounts: Decodable {
    let endedAt: String?
    let inputTokens: Int?
    let outputTokens: Int?
    let cachedReadTokens: Int?
    let cacheCreationTokens: Int?
    let reasoningTokens: Int?
    let costUsdTicks: Int64?
    let primaryModelId: String?
    let modelUsage: [String: GrokUsageCounts]?

    enum CodingKeys: String, CodingKey {
        case endedAt, inputTokens, outputTokens, cachedReadTokens, cacheCreationTokens
        case reasoningTokens, costUsdTicks, primaryModelId, modelUsage
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        endedAt = try? container.decodeIfPresent(String.self, forKey: .endedAt)
        inputTokens = try? container.decodeIfPresent(Int.self, forKey: .inputTokens)
        outputTokens = try? container.decodeIfPresent(Int.self, forKey: .outputTokens)
        cachedReadTokens = try? container.decodeIfPresent(Int.self, forKey: .cachedReadTokens)
        cacheCreationTokens = try? container.decodeIfPresent(Int.self, forKey: .cacheCreationTokens)
        reasoningTokens = try? container.decodeIfPresent(Int.self, forKey: .reasoningTokens)
        costUsdTicks = try? container.decodeIfPresent(Int64.self, forKey: .costUsdTicks)
        primaryModelId = try? container.decodeIfPresent(String.self, forKey: .primaryModelId)
        modelUsage = try? container.decodeIfPresent([String: GrokUsageCounts].self, forKey: .modelUsage)
    }
}

private struct GrokSessionSummary: Decodable {
    struct Info: Decodable {
        let cwd: String?
    }

    let info: Info?
    let generatedTitle: String?

    enum CodingKeys: String, CodingKey {
        case info
        case generatedTitle = "generated_title"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        info = try? container.decodeIfPresent(Info.self, forKey: .info)
        generatedTitle = try? container.decodeIfPresent(String.self, forKey: .generatedTitle)
    }
}
