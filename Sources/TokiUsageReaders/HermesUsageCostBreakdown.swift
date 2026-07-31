import Foundation
import TokiUsageCore

func hermesReportedCostBreakdownIsValid(
    _ reportedCost: Double?,
    modelReportedCosts: [String: Double]? = nil,
    modelPricingCounters: [String: HermesTokenCounters]?,
    totalCost: Double) -> Bool {
    guard let reportedCost else { return modelReportedCosts == nil }
    return reportedCost.isFinite
        && reportedCost >= 0
        && reportedCost <= totalCost
        && modelPricingCounters != nil
        && hermesModelReportedCostsAreValid(
            modelReportedCosts,
            totalReportedCost: reportedCost)
}

func hermesModelReportedCostDeltas(
    current: [String: Double]?,
    previous: [String: Double]?) -> [String: Double]? {
    guard let current, let previous else { return nil }

    var deltas: [String: Double] = [:]
    for model in Set(current.keys).union(previous.keys) {
        let currentCost = current[model] ?? 0
        let previousCost = previous[model] ?? 0
        guard currentCost.isFinite,
              previousCost.isFinite,
              currentCost >= previousCost else {
            return nil
        }
        let delta = currentCost - previousCost
        if delta > 0 {
            deltas[model] = delta
        }
    }
    return deltas
}

private func hermesModelReportedCostsAreValid(
    _ modelReportedCosts: [String: Double]?,
    totalReportedCost: Double) -> Bool {
    guard let modelReportedCosts else { return true }

    var combinedCost = 0.0
    for (model, cost) in modelReportedCosts {
        guard !model.isEmpty,
              model.utf8.count <= 512,
              cost.isFinite,
              cost >= 0,
              (combinedCost + cost).isFinite else {
            return false
        }
        combinedCost += cost
    }
    let tolerance = 0.000_000_001 * max(1, totalReportedCost)
    return abs(combinedCost - totalReportedCost) <= tolerance
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
    pricingTimestamp: Date) -> Double? {
    if observation.reportedCost != nil || previous.reportedCost != nil {
        if let reportedCost = observation.reportedCost,
           let previousReportedCost = previous.reportedCost {
            let reportedCostDelta = max(0, reportedCost - previousReportedCost)
            if let pricedCost = hermesModelPricedDeltaCost(
                current: observation.modelPricingCounters,
                previous: previous.modelPricingCounters,
                maximumDelta: delta,
                timestamp: pricingTimestamp) {
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
                timestamp: pricingTimestamp)
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
            timestamp: pricingTimestamp) {
            return detailedCost
        }
        guard let model = observation.model else { return nil }
        return hermesModelPricedCost(
            counters: delta,
            model: model,
            timestamp: pricingTimestamp)
    }

    if observation.costIsDerivedFromModelPricing {
        if let detailedCost = hermesModelPricedDeltaCost(
            current: observation.modelPricingCounters,
            previous: previous.modelPricingCounters,
            maximumDelta: delta,
            timestamp: pricingTimestamp) {
            return detailedCost
        }
        return hermesModelPricedCost(
            counters: delta,
            model: observation.model,
            timestamp: pricingTimestamp)
    }
    if observation.cost >= previous.cost {
        return observation.cost - previous.cost
    }
    return hermesModelPricedCost(
        counters: delta,
        model: observation.model,
        timestamp: pricingTimestamp)
}
