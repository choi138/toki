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

struct WorkTimeMetrics {
    var agentSeconds: TimeInterval = 0
    var wallClockSeconds: TimeInterval = 0
    var activeStreamCount = 0
    var maxConcurrentStreams = 0

    static let zero = WorkTimeMetrics()

    var parallelMultiplier: Double {
        guard wallClockSeconds > 0 else { return 0 }
        return agentSeconds / wallClockSeconds
    }

    var hasActivity: Bool {
        agentSeconds > 0
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
    var fallbackActiveSeconds: TimeInterval = 0
    var fallbackActiveSecondsByModel: [String: TimeInterval] = [:]
    var supplemental: [SupplementalUsage] = []

    var totalTokens: Int {
        inputTokens + outputTokens + cacheReadTokens + cacheWriteTokens + reasoningTokens
    }

    var resolvedWorkTime: WorkTimeMetrics {
        if workTime.hasActivity { return workTime }
        return WorkTimeMetrics(
            agentSeconds: activeSeconds,
            wallClockSeconds: activeSeconds,
            activeStreamCount: activeSeconds > 0 ? 1 : 0,
            maxConcurrentStreams: activeSeconds > 0 ? 1 : 0)
    }
}

func += (lhs: inout RawTokenUsage, rhs: RawTokenUsage) {
    lhs.inputTokens += rhs.inputTokens
    lhs.outputTokens += rhs.outputTokens
    lhs.cacheReadTokens += rhs.cacheReadTokens
    lhs.cacheWriteTokens += rhs.cacheWriteTokens
    lhs.reasoningTokens += rhs.reasoningTokens
    lhs.cost += rhs.cost
    lhs.activeSeconds += rhs.activeSeconds
    lhs.activityEvents.append(contentsOf: rhs.activityEvents)
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
}
