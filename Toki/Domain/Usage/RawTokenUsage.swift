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

struct RawTokenUsage {
    var inputTokens = 0
    var outputTokens = 0
    var cacheReadTokens = 0
    var cacheWriteTokens = 0
    var reasoningTokens = 0
    var cost: Double = 0
    var activeSeconds: TimeInterval = 0
    var perModel: [String: PerModelUsage] = [:]
    var activityEvents: [ActivityTimeEvent<String>] = []
    var fallbackActiveSeconds: TimeInterval = 0
    var fallbackActiveSecondsByModel: [String: TimeInterval] = [:]
    var supplemental: [SupplementalUsage] = []

    var totalTokens: Int {
        inputTokens + outputTokens + cacheReadTokens + cacheWriteTokens + reasoningTokens
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
