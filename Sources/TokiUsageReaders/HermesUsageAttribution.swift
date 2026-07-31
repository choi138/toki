import Foundation

private struct HermesUsageEventPart {
    let model: String?
    let counters: HermesTokenCounters
}

private struct HermesUsageCostAllocationBasis {
    let assignedCosts: [Double]
    let remainderTokenCounts: [Int]
}

func hermesUsageEvents(
    identifier: String,
    timestamp: Date,
    observation: HermesSessionObservation,
    previousModelCounters: [String: HermesTokenCounters]?,
    previousReportedCost: Double?,
    previousModelReportedCosts: [String: Double]?,
    previousModelPricingCounters: [String: HermesTokenCounters]?,
    counters: HermesTokenCounters,
    cost: Double,
    pricingTimestamp: Date) -> [HermesUsageLedgerEvent] {
    let modelReportedCostDeltas = hermesModelReportedCostDeltas(
        current: observation.modelReportedCosts,
        previous: previousModelReportedCosts)
    let unattributedReportedCostDelta = hermesUnattributedReportedCostDelta(
        currentReportedCost: observation.reportedCost,
        previousReportedCost: previousReportedCost,
        modelReportedCostDeltas: modelReportedCostDeltas)
    let parts = hermesUsageEventParts(
        observation: observation,
        previousModelCounters: previousModelCounters,
        counters: counters,
        costOnlyModels: Set(modelReportedCostDeltas?.keys.map { $0 } ?? []),
        includeCostOnlyResidual: unattributedReportedCostDelta.map { $0 > 0 } ?? false,
        includeCostOnlyFallback: cost > 0)
    let modelPricingDeltas = hermesModelCounterDeltas(
        current: observation.modelPricingCounters,
        previous: previousModelPricingCounters,
        maximumDelta: counters)
    let costs = hermesAllocatedUsageCosts(
        totalCost: cost,
        parts: parts,
        modelPricingDeltas: modelPricingDeltas,
        modelReportedCostDeltas: modelReportedCostDeltas,
        unattributedReportedCostDelta: unattributedReportedCostDelta,
        pricingTimestamp: pricingTimestamp)
    return zip(parts, costs).compactMap { part, allocatedCost in
        guard part.counters.totalTokens > 0 || allocatedCost > 0 else {
            return nil
        }
        return HermesUsageLedgerEvent(
            sessionIdentifier: identifier,
            timestamp: timestamp,
            model: part.model,
            counters: part.counters,
            cost: allocatedCost,
            projectName: observation.projectName,
            attributionQuality: observation.attributionQuality)
    }
}

private func hermesUsageEventParts(
    observation: HermesSessionObservation,
    previousModelCounters: [String: HermesTokenCounters]?,
    counters: HermesTokenCounters,
    costOnlyModels: Set<String>,
    includeCostOnlyResidual: Bool,
    includeCostOnlyFallback: Bool) -> [HermesUsageEventPart] {
    guard let modelDeltas = hermesModelCounterDeltas(
        current: observation.modelCounters,
        previous: previousModelCounters,
        maximumDelta: counters) else {
        var parts: [HermesUsageEventPart] = []
        if counters.totalTokens > 0 {
            parts.append(HermesUsageEventPart(
                model: observation.model,
                counters: counters))
        }
        let representedModels = Set(parts.compactMap(\.model))
        for model in costOnlyModels.subtracting(representedModels).sorted() {
            parts.append(HermesUsageEventPart(model: model, counters: .zero))
        }
        if includeCostOnlyResidual,
           !parts.contains(where: { $0.model == nil }) {
            parts.append(HermesUsageEventPart(model: nil, counters: .zero))
        }
        if parts.isEmpty, includeCostOnlyFallback {
            parts.append(HermesUsageEventPart(model: observation.model, counters: .zero))
        }
        return parts
    }

    var combinedCounters = HermesTokenCounters.zero
    var parts: [HermesUsageEventPart] = []
    for model in modelDeltas.keys.sorted() {
        guard let modelCounters = modelDeltas[model] else { continue }
        combinedCounters = combinedCounters.adding(modelCounters)
        parts.append(HermesUsageEventPart(model: model, counters: modelCounters))
    }
    let representedModels = Set(parts.compactMap(\.model))
    for model in costOnlyModels.subtracting(representedModels).sorted() {
        parts.append(HermesUsageEventPart(model: model, counters: .zero))
    }

    let residual = counters.subtracting(combinedCounters)
    if residual.totalTokens > 0 {
        parts.append(HermesUsageEventPart(model: nil, counters: residual))
    } else if includeCostOnlyResidual {
        parts.append(HermesUsageEventPart(model: nil, counters: .zero))
    }
    if parts.isEmpty, includeCostOnlyFallback {
        parts.append(HermesUsageEventPart(model: observation.model, counters: .zero))
    }
    return parts
}

private func hermesAllocatedUsageCosts(
    totalCost: Double,
    parts: [HermesUsageEventPart],
    modelPricingDeltas: [String: HermesTokenCounters]?,
    modelReportedCostDeltas: [String: Double]?,
    unattributedReportedCostDelta: Double?,
    pricingTimestamp: Date) -> [Double] {
    guard totalCost > 0, !parts.isEmpty else {
        return Array(repeating: 0, count: parts.count)
    }

    let fallbackBasis = HermesUsageCostAllocationBasis(
        assignedCosts: Array(repeating: 0, count: parts.count),
        remainderTokenCounts: parts.map(\.counters.totalTokens))
    let basis = hermesUsageCostAllocationBasis(
        parts: parts,
        modelPricingDeltas: modelPricingDeltas,
        modelReportedCostDeltas: modelReportedCostDeltas,
        unattributedReportedCostDelta: unattributedReportedCostDelta,
        pricingTimestamp: pricingTimestamp) ?? fallbackBasis
    let assignedTotal = basis.assignedCosts.reduce(0, +)
    if assignedTotal > totalCost, assignedTotal > 0 {
        let scale = totalCost / assignedTotal
        return basis.assignedCosts.map { $0 * scale }
    }

    var allocations = basis.assignedCosts
    let remainder = totalCost - assignedTotal
    guard remainder > 0 else { return allocations }

    var remainderTokenCounts = basis.remainderTokenCounts
    if !remainderTokenCounts.contains(where: { $0 > 0 }) {
        remainderTokenCounts = parts.map(\.counters.totalTokens)
        if !remainderTokenCounts.contains(where: { $0 > 0 }) {
            let fallbackRecipient = parts.lastIndex(where: { $0.model == nil })
                ?? (parts.count == 1 ? parts.startIndex : nil)
            if let fallbackRecipient {
                remainderTokenCounts[fallbackRecipient] = 1
            }
        }
    }
    let recipientIndices = remainderTokenCounts.indices.filter {
        remainderTokenCounts[$0] > 0
    }
    let recipientTokens = recipientIndices.reduce(0) {
        $0 + remainderTokenCounts[$1]
    }
    guard recipientTokens > 0, let lastRecipient = recipientIndices.last else {
        return allocations
    }

    var remainingCost = remainder
    for index in recipientIndices.dropLast() {
        let proportionalShare =
            remainder * Double(remainderTokenCounts[index]) / Double(recipientTokens)
        let share = min(remainingCost, proportionalShare)
        allocations[index] += share
        remainingCost -= share
    }
    allocations[lastRecipient] += remainingCost
    return allocations
}

private func hermesUsageCostAllocationBasis(
    parts: [HermesUsageEventPart],
    modelPricingDeltas: [String: HermesTokenCounters]?,
    modelReportedCostDeltas: [String: Double]?,
    unattributedReportedCostDelta: Double?,
    pricingTimestamp: Date) -> HermesUsageCostAllocationBasis? {
    guard modelPricingDeltas != nil || modelReportedCostDeltas != nil else {
        return nil
    }

    var unmatchedPricingModels = Set(modelPricingDeltas?.keys.map { $0 } ?? [])
    var unmatchedReportedModels = Set(modelReportedCostDeltas?.keys.map { $0 } ?? [])
    var assignedCosts: [Double] = []
    var remainderTokenCounts: [Int] = []
    var unattributedCostWasAssigned = unattributedReportedCostDelta.map { $0 <= 0 } ?? true
    for part in parts {
        guard let model = part.model else {
            let unattributedCost = unattributedReportedCostDelta ?? 0
            guard unattributedCost.isFinite, unattributedCost >= 0 else {
                return nil
            }
            assignedCosts.append(unattributedCost)
            remainderTokenCounts.append(
                modelReportedCostDeltas == nil
                    ? part.counters.totalTokens
                    : max(1, part.counters.totalTokens))
            unattributedCostWasAssigned = true
            continue
        }

        let pricingCounters = modelPricingDeltas?[model] ?? .zero
        if modelPricingDeltas != nil,
           part.counters.hasDecrease(comparedTo: pricingCounters) {
            return nil
        }
        unmatchedPricingModels.remove(model)
        unmatchedReportedModels.remove(model)

        let pricedCost = hermesModelPricedCost(
            counters: pricingCounters,
            model: model,
            timestamp: pricingTimestamp)
        let reportedCost = modelReportedCostDeltas?[model] ?? 0
        let assignedCost = pricedCost + reportedCost
        guard pricedCost.isFinite,
              pricedCost >= 0,
              reportedCost.isFinite,
              reportedCost >= 0,
              assignedCost.isFinite else {
            return nil
        }

        assignedCosts.append(assignedCost)
        remainderTokenCounts.append(
            modelReportedCostDeltas == nil
                ? part.counters.subtracting(pricingCounters).totalTokens
                : 0)
    }
    guard unmatchedPricingModels.isEmpty,
          unmatchedReportedModels.isEmpty,
          unattributedCostWasAssigned else {
        return nil
    }

    return HermesUsageCostAllocationBasis(
        assignedCosts: assignedCosts,
        remainderTokenCounts: remainderTokenCounts)
}
