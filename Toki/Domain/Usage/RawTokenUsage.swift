import Foundation

enum SupplementalUnit: String {
    case tokens
    case count
    case cents
}

enum UsageQuality: String {
    case exact
    case contextOnly
    case derived
}

struct SupplementalUsage {
    let id: String
    let label: String
    let value: Int
    let unit: SupplementalUnit
    let source: String
    let model: String?
    let includedInTotals: Bool
    let quality: UsageQuality
}

struct PerModelUsage {
    var totalTokens = 0
    var cost: Double = 0
    var activeSeconds: TimeInterval = 0
    var sources: Set<String> = []
}

struct TokenUsageEvent: Equatable, Codable {
    let timestamp: Date
    let source: String
    let model: String?
    let inputTokens: Int
    let outputTokens: Int
    let cacheReadTokens: Int
    let cacheWriteTokens: Int
    let reasoningTokens: Int
    let cost: Double

    var totalTokens: Int {
        inputTokens + outputTokens + cacheReadTokens + cacheWriteTokens + reasoningTokens
    }
}

struct WorkTimeMetrics: Equatable {
    var agentSeconds: TimeInterval
    var mainAgentSeconds: TimeInterval
    var subagentSeconds: TimeInterval
    var wallClockSeconds: TimeInterval
    var activeStreamCount: Int
    var maxConcurrentStreams: Int

    init(
        agentSeconds: TimeInterval = 0,
        wallClockSeconds: TimeInterval = 0,
        activeStreamCount: Int = 0,
        maxConcurrentStreams: Int = 0,
        mainAgentSeconds: TimeInterval? = nil,
        subagentSeconds: TimeInterval = 0) {
        self.agentSeconds = agentSeconds
        self.wallClockSeconds = wallClockSeconds
        self.activeStreamCount = activeStreamCount
        self.maxConcurrentStreams = maxConcurrentStreams
        self.subagentSeconds = max(0, subagentSeconds)
        self.mainAgentSeconds = max(0, mainAgentSeconds ?? (agentSeconds - self.subagentSeconds))
    }

    static let zero = WorkTimeMetrics()

    static func fallback(activeSeconds: TimeInterval) -> WorkTimeMetrics {
        let streamCount = activeSeconds > 0 ? 1 : 0
        return WorkTimeMetrics(
            agentSeconds: activeSeconds,
            wallClockSeconds: activeSeconds,
            activeStreamCount: streamCount,
            maxConcurrentStreams: streamCount,
            mainAgentSeconds: activeSeconds)
    }

    /// Merges metrics when their time windows cannot be aligned. This sums
    /// duration and stream counts, but keeps peak concurrency to observed peaks.
    /// If the inputs really overlap, wallClockSeconds is overestimated and
    /// parallelMultiplier moves closer to 1.
    func mergedConservatively(with other: WorkTimeMetrics) -> WorkTimeMetrics {
        if !hasActivity { return other }
        if !other.hasActivity { return self }
        return WorkTimeMetrics(
            agentSeconds: agentSeconds + other.agentSeconds,
            wallClockSeconds: wallClockSeconds + other.wallClockSeconds,
            activeStreamCount: activeStreamCount + other.activeStreamCount,
            maxConcurrentStreams: max(maxConcurrentStreams, other.maxConcurrentStreams),
            mainAgentSeconds: mainAgentSeconds + other.mainAgentSeconds,
            subagentSeconds: subagentSeconds + other.subagentSeconds)
    }

    var parallelMultiplier: Double {
        guard wallClockSeconds > 0 else { return 0 }
        return agentSeconds / wallClockSeconds
    }

    var hasActivity: Bool {
        agentSeconds > 0
            || mainAgentSeconds > 0
            || subagentSeconds > 0
            || wallClockSeconds > 0
            || activeStreamCount > 0
            || maxConcurrentStreams > 0
    }
}

struct RawTokenUsage {
    var inputTokens = 0
    var outputTokens = 0
    var cacheReadTokens = 0
    var cacheWriteTokens = 0
    var reasoningTokens = 0
    var cost: Double = 0
    var activeSeconds: TimeInterval = 0
    var workTime = WorkTimeMetrics.zero
    var perModel: [String: PerModelUsage] = [:]
    var activityEvents: [ActivityTimeEvent<String>] = []
    var tokenEvents: [TokenUsageEvent] = []
    var fallbackActiveSeconds: TimeInterval = 0
    var fallbackActiveSecondsByModel: [String: TimeInterval] = [:]
    var fallbackWorkTime = WorkTimeMetrics.zero
    var supplemental: [SupplementalUsage] = []

    var totalTokens: Int {
        inputTokens + outputTokens + cacheReadTokens + cacheWriteTokens + reasoningTokens
    }

    var resolvedWorkTime: WorkTimeMetrics {
        if workTime.hasActivity { return workTime }
        return .fallback(activeSeconds: activeSeconds)
    }

    var resolvedFallbackWorkTime: WorkTimeMetrics {
        if fallbackWorkTime.hasActivity { return fallbackWorkTime }
        if fallbackActiveSeconds > 0 { return .fallback(activeSeconds: fallbackActiveSeconds) }
        if activityEvents.isEmpty { return resolvedWorkTime }
        return .zero
    }

    var hasReportableData: Bool {
        totalTokens > 0
            || cost > 0
            || activeSeconds > 0
            || workTime.hasActivity
            || fallbackWorkTime.hasActivity
            || fallbackActiveSeconds > 0
            || !perModel.isEmpty
            || !tokenEvents.isEmpty
            || !supplemental.isEmpty
    }

    mutating func recordTokenEvent(
        timestamp: Date,
        source: String,
        model: String?,
        inputTokens: Int,
        outputTokens: Int,
        cacheReadTokens: Int = 0,
        cacheWriteTokens: Int = 0,
        reasoningTokens: Int = 0,
        cost: Double = 0) {
        let event = TokenUsageEvent(
            timestamp: timestamp,
            source: source,
            model: model,
            inputTokens: inputTokens,
            outputTokens: outputTokens,
            cacheReadTokens: cacheReadTokens,
            cacheWriteTokens: cacheWriteTokens,
            reasoningTokens: reasoningTokens,
            cost: cost)
        guard event.totalTokens > 0 else { return }
        tokenEvents.append(event)
    }
}

func += (lhs: inout RawTokenUsage, rhs: RawTokenUsage) {
    let lhsWorkTime = lhs.resolvedWorkTime
    let rhsWorkTime = rhs.resolvedWorkTime
    let lhsFallbackWorkTime = lhs.resolvedFallbackWorkTime
    let rhsFallbackWorkTime = rhs.resolvedFallbackWorkTime

    lhs.inputTokens += rhs.inputTokens
    lhs.outputTokens += rhs.outputTokens
    lhs.cacheReadTokens += rhs.cacheReadTokens
    lhs.cacheWriteTokens += rhs.cacheWriteTokens
    lhs.reasoningTokens += rhs.reasoningTokens
    lhs.cost += rhs.cost
    lhs.activeSeconds += rhs.activeSeconds
    lhs.activityEvents.append(contentsOf: rhs.activityEvents)
    lhs.tokenEvents.append(contentsOf: rhs.tokenEvents)
    lhs.fallbackActiveSeconds += rhs.fallbackActiveSeconds

    if rhs.activityEvents.isEmpty, rhs.activeSeconds > 0 {
        lhs.fallbackActiveSeconds += rhs.activeSeconds
    }

    for (id, usage) in rhs.perModel {
        lhs.perModel[id, default: PerModelUsage()].totalTokens += usage.totalTokens
        lhs.perModel[id, default: PerModelUsage()].cost += usage.cost
        lhs.perModel[id, default: PerModelUsage()].activeSeconds += usage.activeSeconds
        lhs.perModel[id, default: PerModelUsage()].sources.formUnion(usage.sources)
    }

    for (id, seconds) in rhs.fallbackActiveSecondsByModel {
        lhs.fallbackActiveSecondsByModel[id, default: 0] += seconds
    }

    lhs.supplemental.append(contentsOf: rhs.supplemental)

    if rhs.activityEvents.isEmpty {
        for (id, usage) in rhs.perModel where usage.activeSeconds > 0 {
            lhs.fallbackActiveSecondsByModel[id, default: 0] += usage.activeSeconds
        }
    }

    lhs.fallbackWorkTime = lhsFallbackWorkTime.mergedConservatively(with: rhsFallbackWorkTime)
    lhs.workTime = lhsWorkTime.mergedConservatively(with: rhsWorkTime)
}
