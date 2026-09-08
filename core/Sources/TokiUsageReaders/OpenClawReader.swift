import Foundation
import TokiSyncProtocol
import TokiUsageCore

/// Reads OpenClaw agent SQLite stores and retained JSONL transcripts.
public struct OpenClawReader: TokenReader {
    public static let sourceName = "OpenClaw"

    public let name = Self.sourceName
    public let agentsRoots: [URL]
    private let limits: OpenClawReadLimits
    private let beforeTranscriptRead: ((URL) throws -> Void)?

    /// An override selects only that agents directory, preserving the legacy API.
    public init(agentsURLOverride: URL? = nil) {
        self.init(agentsRoots: agentsURLOverride.map { [$0] } ?? Self.defaultAgentsRoots())
    }

    /// Explicit roots are agents directories, not state directories or HOME.
    public init(agentsRoots: [URL]) {
        self.init(agentsRoots: agentsRoots, limits: OpenClawReadLimits())
    }

    init(agentsRoots: [URL], limits: OpenClawReadLimits) {
        self.init(agentsRoots: agentsRoots, limits: limits, beforeTranscriptRead: nil)
    }

    init(
        agentsRoots: [URL],
        limits: OpenClawReadLimits,
        beforeTranscriptRead: ((URL) throws -> Void)?) {
        self.agentsRoots = agentsRoots
        self.limits = limits
        self.beforeTranscriptRead = beforeTranscriptRead
    }

    public static func defaultAgentsRoots(home: URL = homeDir()) -> [URL] {
        [".openclaw", ".clawdbot", ".moltbot", ".moldbot"].map {
            home.appendingPathComponent("\($0)/agents")
        }
    }

    public func readUsage(from startDate: Date, to endDate: Date) async throws -> RawTokenUsage {
        try Task.checkCancellation()
        guard startDate < endDate else { return RawTokenUsage() }
        let budget = OpenClawReadBudget(limits: limits)
        let sources = try OpenClawSourceDiscovery.sources(in: agentsRoots, budget: budget)
        var accumulator = OpenClawUsageAccumulator(start: startDate, end: endDate)
        // A database is authoritative when a retained transcript contains the same event.
        for (sourceIndex, source) in sources.enumerated() {
            try Task.checkCancellation()
            switch source.kind {
            case .database:
                try OpenClawSQLiteReader.read(source: source, budget: budget) {
                    accumulator.append($0, agent: source.agentID)
                }
            case .transcript:
                var parser = OpenClawMessageParser(sessionID: source.sessionID, acceptsSessionHeader: true)
                try OpenClawTranscriptIO.forEachLine(
                    at: source.url,
                    budget: budget,
                    beforeRead: { try beforeTranscriptRead?(source.url) }) { data, readModifiedAt in
                        if let event = parser.parse(data, fallbackDate: readModifiedAt) {
                            accumulator.append(event, agent: source.agentID, transcriptSource: sourceIndex)
                        }
                    }
                try parser.validate()
            }
        }
        try Task.checkCancellation()
        return accumulator.finish()
    }

    /// Kept for the existing macOS reader tests; timestamp-less legacy rows remain excluded.
    static func usage(
        fromJSONLLines lines: [String],
        streamID: String,
        from startDate: Date,
        to endDate: Date) -> RawTokenUsage {
        var parser = OpenClawMessageParser(sessionID: usageSessionID(fromPath: streamID))
        var accumulator = OpenClawUsageAccumulator(start: startDate, end: endDate)
        for line in lines {
            if let event = parser.parse(Data(line.utf8)) {
                accumulator.append(event, agent: SnapshotCipher.digest(streamID))
            }
        }
        return accumulator.finish()
    }
}

private struct OpenClawUsageAccumulator {
    private struct SourceOccurrence: Hashable {
        let source: Int
        let event: OpenClawFallbackEventKey
    }

    let start: Date
    let end: Date
    private var seen: Set<OpenClawEventIdentity> = []
    private var seenFallbacks: Set<OpenClawFallbackEventIdentity> = []
    private var sourceOccurrences: [SourceOccurrence: Int] = [:]
    private var result = RawTokenUsage()
    private var activity: [ActivityTimeEvent<String>] = []

    init(start: Date, end: Date) {
        self.start = start
        self.end = end
    }

    mutating func append(_ event: OpenClawUsageEvent, agent: String, transcriptSource: Int? = nil) {
        if let identity = event.identity(agent: agent) {
            guard seen.insert(identity).inserted else { return }
        } else if let transcriptSource {
            let eventKey = event.fallbackIdentityKey(agent: agent)
            let sourceOccurrence = SourceOccurrence(source: transcriptSource, event: eventKey)
            let occurrence = sourceOccurrences[sourceOccurrence, default: 0]
            sourceOccurrences[sourceOccurrence] = occurrence + 1
            let identity = OpenClawFallbackEventIdentity(event: eventKey, occurrence: occurrence)
            guard seenFallbacks.insert(identity).inserted else { return }
        }
        guard event.date >= start, event.date < end else { return }
        let tokens = event.tokens
        guard let total = result.accumulateTokenCounts(
            input: tokens.input, output: tokens.output, cacheRead: tokens.cacheRead,
            cacheWrite: tokens.cacheWrite, reasoning: tokens.reasoning) else { return }
        let price = event.model.flatMap { modelPrice(for: $0, at: event.date) }
        let estimatedCost = price?.cost(
            input: tokens.input, output: tokens.output + tokens.reasoning,
            cacheRead: tokens.cacheRead, cacheWrite: tokens.cacheWrite)
        let cost = event.reportedCost ?? estimatedCost ?? 0
        guard total > 0 || cost > 0 else { return }
        let sessionID = "openclaw:" + SnapshotCipher.digest(agent + "\u{0}" + event.sessionID)
        result.cost += cost
        result.accumulatePerModelUsage(
            model: event.model, source: OpenClawReader.sourceName, totalTokens: total, cost: cost)
        result.recordTokenEvent(
            timestamp: event.date, source: OpenClawReader.sourceName, model: event.model, provider: event.provider,
            inputTokens: tokens.input, outputTokens: tokens.output, cacheReadTokens: tokens.cacheRead,
            cacheWriteTokens: tokens.cacheWrite, reasoningTokens: tokens.reasoning, cost: cost,
            costIsKnown: event.reportedCost != nil || price != nil,
            attribution: UsageAttribution(sessionID: sessionID))
        activity.append(ActivityTimeEvent(
            streamID: sessionID, timestamp: event.date, key: UsageModelGrouping.groupingKey(for: event.model)))
    }

    mutating func finish() -> RawTokenUsage {
        result.tokenEvents.sort { $0.timestamp < $1.timestamp }
        result.mergeActivityEvents(activity, source: OpenClawReader.sourceName, clippingEndDate: end)
        return result
    }
}
