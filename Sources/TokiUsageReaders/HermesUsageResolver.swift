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
    let costIsDerivedFromModelPricing: Bool
}

struct HermesResolvedUsageCost {
    let value: Double
    let isDerivedFromModelPricing: Bool
}

enum HermesUsageResolver {
    static func resolve(
        session: HermesSessionObservation,
        modelUsage: [HermesSessionModelUsage]) throws -> HermesSessionObservation {
        var modelCounters = HermesTokenCounters.zero
        var modelCost = 0.0
        var modelCostIsDerivedFromModelPricing = true
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
            modelCostIsDerivedFromModelPricing =
                modelCostIsDerivedFromModelPricing && usage.costIsDerivedFromModelPricing
            if usage.counters.totalTokens > 0, let model = usage.model {
                models.insert(model)
            }
        }

        if session.counters.totalTokens > 0, let model = session.model {
            models.insert(model)
        }
        let resolvedModel = models.count == 1 ? models.first : (models.isEmpty ? session.model : nil)
        let resolvedCost: Double
        let costIsDerivedFromModelPricing: Bool
        if modelUsage.isEmpty || session.cost > modelCost {
            resolvedCost = session.cost
            costIsDerivedFromModelPricing = session.costIsDerivedFromModelPricing
        } else if modelCost > session.cost {
            resolvedCost = modelCost
            costIsDerivedFromModelPricing = modelCostIsDerivedFromModelPricing
        } else {
            resolvedCost = session.cost
            costIsDerivedFromModelPricing =
                session.costIsDerivedFromModelPricing && modelCostIsDerivedFromModelPricing
        }

        return HermesSessionObservation(
            sessionID: session.sessionID,
            startedAt: session.startedAt,
            earliestActivityAt: session.earliestActivityAt,
            latestActivityAt: session.latestActivityAt,
            model: resolvedModel,
            counters: session.counters.maximum(modelCounters),
            cost: resolvedCost,
            costIsDerivedFromModelPricing: costIsDerivedFromModelPricing,
            projectName: session.projectName,
            attributionQuality: session.attributionQuality)
    }
}

func hermesUsageCost(
    model: String?,
    counters: HermesTokenCounters,
    estimatedCost: Double,
    actualCost: Double,
    timestamp: Date?) -> HermesResolvedUsageCost {
    if actualCost > 0 {
        return HermesResolvedUsageCost(
            value: actualCost,
            isDerivedFromModelPricing: false)
    }
    if estimatedCost > 0 {
        return HermesResolvedUsageCost(
            value: estimatedCost,
            isDerivedFromModelPricing: false)
    }

    let value = model
        .flatMap { modelPrice(for: $0, at: timestamp ?? Date()) }?
        .cost(
            input: counters.inputTokens,
            output: counters.outputTokens + counters.reasoningTokens,
            cacheRead: counters.cacheReadTokens,
            cacheWrite: counters.cacheWriteTokens) ?? 0
    return HermesResolvedUsageCost(
        value: value,
        isDerivedFromModelPricing: true)
}
