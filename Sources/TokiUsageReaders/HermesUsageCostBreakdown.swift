import Foundation
import TokiUsageCore

func hermesReportedCostBreakdownIsValid(
    _ reportedCost: Double?,
    modelPricingCounters: [String: HermesTokenCounters]?,
    totalCost: Double) -> Bool {
    guard let reportedCost else { return true }
    return reportedCost.isFinite
        && reportedCost >= 0
        && reportedCost <= totalCost
        && modelPricingCounters != nil
}

func hermesModelPricedCost(
    counters: HermesTokenCounters,
    model: String?,
    timestamp: Date) -> Double {
    guard let model,
          let price = modelPrice(for: model, at: timestamp) else { return 0 }
    return price.cost(
        input: counters.inputTokens,
        output: counters.outputTokens + counters.reasoningTokens,
        cacheRead: counters.cacheReadTokens,
        cacheWrite: counters.cacheWriteTokens)
}

func hermesModelPricedDeltaCost(
    current: [String: HermesTokenCounters]?,
    previous: [String: HermesTokenCounters]?,
    maximumDelta: HermesTokenCounters,
    timestamp: Date) -> Double? {
    guard let current, let previous else { return nil }

    var combinedDelta = HermesTokenCounters.zero
    var cost = 0.0
    for model in Set(current.keys).union(previous.keys) {
        let currentCounters = current[model] ?? .zero
        let previousCounters = previous[model] ?? .zero
        guard !currentCounters.hasDecrease(comparedTo: previousCounters) else { return nil }
        let delta = currentCounters.subtracting(previousCounters)
        guard combinedDelta.canAdd(
            delta,
            maximum: hermesLedgerMaximumCumulativeTokens) else {
            return nil
        }
        combinedDelta = combinedDelta.adding(delta)
        let modelCost = hermesModelPricedCost(
            counters: delta,
            model: model,
            timestamp: timestamp)
        guard modelCost.isFinite, (cost + modelCost).isFinite else { return nil }
        cost += modelCost
    }
    guard !maximumDelta.hasDecrease(comparedTo: combinedDelta) else { return nil }
    return cost
}

func hermesIncrementalCost(
    observation: HermesSessionObservation,
    previous: HermesUsageLedgerBaseline,
    delta: HermesTokenCounters,
    timestamp: Date) -> Double? {
    if observation.reportedCost != nil || previous.reportedCost != nil {
        if let reportedCost = observation.reportedCost,
           let previousReportedCost = previous.reportedCost {
            let reportedCostDelta = max(0, reportedCost - previousReportedCost)
            if let pricedCost = hermesModelPricedDeltaCost(
                current: observation.modelPricingCounters,
                previous: previous.modelPricingCounters,
                maximumDelta: delta,
                timestamp: timestamp) {
                let cost = reportedCostDelta + pricedCost
                return cost.isFinite ? cost : nil
            }
            guard reportedCost == 0,
                  previousReportedCost == 0,
                  observation.costIsDerivedFromModelPricing,
                  observation.model != nil else {
                return nil
            }
            return hermesModelPricedCost(
                counters: delta,
                model: observation.model,
                timestamp: timestamp)
        }

        guard let reportedCost = observation.reportedCost,
              reportedCost == 0,
              previous.reportedCost == nil,
              previous.modelPricingCounters != nil,
              observation.costIsDerivedFromModelPricing else {
            return nil
        }
        return hermesModelPricedDeltaCost(
            current: observation.modelPricingCounters,
            previous: previous.modelPricingCounters,
            maximumDelta: delta,
            timestamp: timestamp)
    }

    if observation.costIsDerivedFromModelPricing {
        if let detailedCost = hermesModelPricedDeltaCost(
            current: observation.modelPricingCounters,
            previous: previous.modelPricingCounters,
            maximumDelta: delta,
            timestamp: timestamp) {
            return detailedCost
        }
        return hermesModelPricedCost(
            counters: delta,
            model: observation.model,
            timestamp: timestamp)
    }
    if observation.cost >= previous.cost {
        return observation.cost - previous.cost
    }
    return hermesModelPricedCost(
        counters: delta,
        model: observation.model,
        timestamp: timestamp)
}
