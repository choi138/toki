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

private struct HermesResolvedSessionCost {
    let value: Double
    let isDerivedFromModelPricing: Bool
    let reportedValue: Double
    let modelPricingCounters: [String: HermesTokenCounters]
}

enum HermesUsageResolver {
    static func resolve(
        session: HermesSessionObservation,
        modelUsage: [HermesSessionModelUsage]) throws -> HermesSessionObservation {
        var modelCounters = HermesTokenCounters.zero
        var modelCost = 0.0
        var modelReportedCost = 0.0
        var modelCostIsDerivedFromModelPricing = true
        var modelPricingCounters: [String: HermesTokenCounters] = [:]
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
            if !usage.costIsDerivedFromModelPricing {
                modelReportedCost += usage.cost
            }
            if usage.counters.totalTokens > 0, let model = usage.model {
                if usage.costIsDerivedFromModelPricing {
                    let existingCounters = modelPricingCounters[model] ?? .zero
                    guard existingCounters.canAdd(
                        usage.counters,
                        maximum: hermesLedgerMaximumCumulativeTokens) else {
                        throw HermesUsageLedgerError.invalidObservation
                    }
                    modelPricingCounters[model] = existingCounters.adding(usage.counters)
                }
                models.insert(model)
            }
        }

        if session.counters.totalTokens > 0, let model = session.model {
            models.insert(model)
        }
        let resolvedModel = models.count == 1 ? models.first : (models.isEmpty ? session.model : nil)
        let resolvedCost = resolveCost(
            session: session,
            hasModelUsage: !modelUsage.isEmpty,
            modelCost: modelCost,
            modelReportedCost: modelReportedCost,
            modelCostIsDerivedFromModelPricing: modelCostIsDerivedFromModelPricing,
            modelPricingCounters: modelPricingCounters)

        return HermesSessionObservation(
            sessionID: session.sessionID,
            startedAt: session.startedAt,
            earliestActivityAt: session.earliestActivityAt,
            latestActivityAt: session.latestActivityAt,
            model: resolvedModel,
            counters: session.counters.maximum(modelCounters),
            cost: resolvedCost.value,
            costIsDerivedFromModelPricing: resolvedCost.isDerivedFromModelPricing,
            reportedCost: resolvedCost.reportedValue,
            modelPricingCounters: resolvedCost.modelPricingCounters,
            projectName: session.projectName,
            attributionQuality: session.attributionQuality)
    }

    private static func resolveCost(
        session: HermesSessionObservation,
        hasModelUsage: Bool,
        modelCost: Double,
        modelReportedCost: Double,
        modelCostIsDerivedFromModelPricing: Bool,
        modelPricingCounters: [String: HermesTokenCounters]) -> HermesResolvedSessionCost {
        let sessionPricingCounters = session.costIsDerivedFromModelPricing
            ? pricingCounters(model: session.model, counters: session.counters)
            : [:]
        let sessionReportedCost = session.costIsDerivedFromModelPricing ? 0 : session.cost
        if !hasModelUsage || session.cost > modelCost {
            return HermesResolvedSessionCost(
                value: session.cost,
                isDerivedFromModelPricing: session.costIsDerivedFromModelPricing,
                reportedValue: sessionReportedCost,
                modelPricingCounters: sessionPricingCounters)
        }
        if modelCost > session.cost {
            return HermesResolvedSessionCost(
                value: modelCost,
                isDerivedFromModelPricing: modelCostIsDerivedFromModelPricing,
                reportedValue: modelReportedCost,
                modelPricingCounters: modelPricingCounters)
        }

        if !session.costIsDerivedFromModelPricing {
            return HermesResolvedSessionCost(
                value: session.cost,
                isDerivedFromModelPricing: false,
                reportedValue: sessionReportedCost,
                modelPricingCounters: sessionPricingCounters)
        }
        return HermesResolvedSessionCost(
            value: modelCost,
            isDerivedFromModelPricing: modelCostIsDerivedFromModelPricing,
            reportedValue: modelReportedCost,
            modelPricingCounters: modelPricingCounters)
    }

    private static func pricingCounters(
        model: String?,
        counters: HermesTokenCounters) -> [String: HermesTokenCounters] {
        guard let model, counters.totalTokens > 0 else { return [:] }
        return [model: counters]
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
