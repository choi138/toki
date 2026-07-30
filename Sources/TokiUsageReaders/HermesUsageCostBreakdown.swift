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
    guard let deltas = hermesModelCounterDeltas(
        current: current,
        previous: previous,
        maximumDelta: maximumDelta) else {
        return nil
    }

    var cost = 0.0
    for (model, delta) in deltas {
        let modelCost = hermesModelPricedCost(
            counters: delta,
            model: model,
            timestamp: timestamp)
        guard modelCost.isFinite, (cost + modelCost).isFinite else { return nil }
        cost += modelCost
    }
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
            guard let model = observation.model else { return nil }
            let switchedToReportedCost = reportedCost > 0
                && previousReportedCost == 0
                && previous.model == model
                && previous.modelPricingCounters?.count == 1
                && previous.modelPricingCounters?[model] != nil
                && observation.modelPricingCounters?.isEmpty == true
            guard (reportedCost == 0 && observation.costIsDerivedFromModelPricing)
                || switchedToReportedCost else {
                return nil
            }
            return hermesModelPricedCost(
                counters: delta,
                model: model,
                timestamp: timestamp)
        }

        guard let reportedCost = observation.reportedCost,
              previous.reportedCost == nil else {
            return nil
        }
        if reportedCost > 0 {
            guard observation.cost >= previous.cost else { return nil }
            return observation.cost - previous.cost
        }
        guard observation.costIsDerivedFromModelPricing else { return nil }
        if let detailedCost = hermesModelPricedDeltaCost(
            current: observation.modelPricingCounters,
            previous: previous.modelPricingCounters,
            maximumDelta: delta,
            timestamp: timestamp) {
            return detailedCost
        }
        guard let model = observation.model else { return nil }
        return hermesModelPricedCost(
            counters: delta,
            model: model,
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
