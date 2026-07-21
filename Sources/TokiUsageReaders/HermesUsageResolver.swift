import Foundation
import TokiUsageCore

public struct HermesUsageCoverageStatus: Equatable, Sendable {
    public let unmeteredMainAPICallCount: Int

    public init(unmeteredMainAPICallCount: Int) {
        self.unmeteredMainAPICallCount = unmeteredMainAPICallCount
    }
}

struct HermesSessionModelUsage {
    let model: String?
    let counters: HermesTokenCounters
    let cost: Double
}

enum HermesUsageResolver {
    static func resolve(
        session: HermesSessionObservation,
        modelUsage: [HermesSessionModelUsage]) throws -> HermesSessionObservation {
        var modelCounters = HermesTokenCounters.zero
        var modelCost = 0.0
        var models: Set<String> = []

        for usage in modelUsage {
            guard usage.counters.isValid(),
                  modelCounters.canAdd(usage.counters, maximum: hermesLedgerMaximumCumulativeTokens),
                  usage.cost.isFinite,
                  usage.cost >= 0,
                  (modelCost + usage.cost).isFinite else {
                throw HermesUsageLedgerError.invalidObservation
            }
            modelCounters = modelCounters.adding(usage.counters)
            modelCost += usage.cost
            if usage.counters.totalTokens > 0, let model = usage.model {
                models.insert(model)
            }
        }

        if session.counters.totalTokens > 0, let model = session.model {
            models.insert(model)
        }
        let resolvedModel = models.count == 1 ? models.first : (models.isEmpty ? session.model : nil)

        return HermesSessionObservation(
            sessionID: session.sessionID,
            startedAt: session.startedAt,
            earliestActivityAt: session.earliestActivityAt,
            latestActivityAt: session.latestActivityAt,
            model: resolvedModel,
            counters: session.counters.maximum(modelCounters),
            cost: max(session.cost, modelCost),
            projectName: session.projectName,
            attributionQuality: session.attributionQuality)
    }
}

func hermesUsageCost(
    model: String?,
    counters: HermesTokenCounters,
    estimatedCost: Double,
    actualCost: Double) -> Double {
    if actualCost > 0 { return actualCost }
    if estimatedCost > 0 { return estimatedCost }

    guard let model, let price = modelPrice(for: model) else { return 0 }
    return price.cost(
        input: counters.inputTokens,
        output: counters.outputTokens + counters.reasoningTokens,
        cacheRead: counters.cacheReadTokens,
        cacheWrite: counters.cacheWriteTokens)
}
