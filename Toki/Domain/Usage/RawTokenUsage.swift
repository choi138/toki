import Foundation

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

    for (id, usage) in rhs.perModel {
        lhs.perModel[id, default: PerModelUsage()].totalTokens += usage.totalTokens
        lhs.perModel[id, default: PerModelUsage()].cost += usage.cost
        lhs.perModel[id, default: PerModelUsage()].activeSeconds += usage.activeSeconds
        lhs.perModel[id, default: PerModelUsage()].sources.formUnion(usage.sources)
    }
}
