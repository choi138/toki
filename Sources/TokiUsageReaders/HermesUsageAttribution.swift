import Foundation

private struct HermesUsageEventPart {
    let model: String?
    let counters: HermesTokenCounters
}

private struct HermesUsageCostAllocationBasis {
    let pricedCosts: [Double]
    let remainderTokenCounts: [Int]
}

func hermesUsageEvents(
    identifier: String,
    timestamp: Date,
    observation: HermesSessionObservation,
    previousModelCounters: [String: HermesTokenCounters]?,
    previousModelPricingCounters: [String: HermesTokenCounters]?,
    counters: HermesTokenCounters,
    cost: Double) -> [HermesUsageLedgerEvent] {
    let parts = hermesUsageEventParts(
        observation: observation,
        previousModelCounters: previousModelCounters,
        counters: counters)
    let modelPricingDeltas = hermesModelCounterDeltas(
        current: observation.modelPricingCounters,
        previous: previousModelPricingCounters,
        maximumDelta: counters)
    let costs = hermesAllocatedUsageCosts(
        totalCost: cost,
        parts: parts,
        modelPricingDeltas: modelPricingDeltas,
        timestamp: timestamp)
    return zip(parts, costs).map { part, allocatedCost in
        HermesUsageLedgerEvent(
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
    counters: HermesTokenCounters) -> [HermesUsageEventPart] {
    guard let modelDeltas = hermesModelCounterDeltas(
        current: observation.modelCounters,
        previous: previousModelCounters,
        maximumDelta: counters) else {
        return [HermesUsageEventPart(model: observation.model, counters: counters)]
    }

    var combinedCounters = HermesTokenCounters.zero
    var parts: [HermesUsageEventPart] = []
    for model in modelDeltas.keys.sorted() {
        guard let modelCounters = modelDeltas[model] else { continue }
        combinedCounters = combinedCounters.adding(modelCounters)
        parts.append(HermesUsageEventPart(model: model, counters: modelCounters))
    }

    let residual = counters.subtracting(combinedCounters)
    if residual.totalTokens > 0 {
        parts.append(HermesUsageEventPart(model: nil, counters: residual))
    }
    return parts
}

private func hermesAllocatedUsageCosts(
    totalCost: Double,
    parts: [HermesUsageEventPart],
    modelPricingDeltas: [String: HermesTokenCounters]?,
    timestamp: Date) -> [Double] {
    guard totalCost > 0, !parts.isEmpty else {
        return Array(repeating: 0, count: parts.count)
    }

    let fallbackBasis = HermesUsageCostAllocationBasis(
        pricedCosts: Array(repeating: 0, count: parts.count),
        remainderTokenCounts: parts.map(\.counters.totalTokens))
    let basis = hermesUsageCostAllocationBasis(
        parts: parts,
        modelPricingDeltas: modelPricingDeltas,
        timestamp: timestamp) ?? fallbackBasis
    let pricedTotal = basis.pricedCosts.reduce(0, +)
    if pricedTotal > totalCost, pricedTotal > 0 {
        let scale = totalCost / pricedTotal
        return basis.pricedCosts.map { $0 * scale }
    }

    var allocations = basis.pricedCosts
    let remainder = totalCost - pricedTotal
    guard remainder > 0 else { return allocations }

    var remainderTokenCounts = basis.remainderTokenCounts
    if !remainderTokenCounts.contains(where: { $0 > 0 }) {
        remainderTokenCounts = parts.map(\.counters.totalTokens)
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
    timestamp: Date) -> HermesUsageCostAllocationBasis? {
    guard let modelPricingDeltas else { return nil }

    var unmatchedModels = Set(modelPricingDeltas.keys)
    var pricedCosts: [Double] = []
    var remainderTokenCounts: [Int] = []
    for part in parts {
        guard let model = part.model else {
            pricedCosts.append(0)
            remainderTokenCounts.append(part.counters.totalTokens)
            continue
        }

        let pricingCounters = modelPricingDeltas[model] ?? .zero
        guard !part.counters.hasDecrease(comparedTo: pricingCounters) else {
            return nil
        }
        unmatchedModels.remove(model)

        let pricedCost = hermesModelPricedCost(
            counters: pricingCounters,
            model: model,
            timestamp: timestamp)
        guard pricedCost.isFinite, pricedCost >= 0 else { return nil }

        pricedCosts.append(pricedCost)
        remainderTokenCounts.append(
            part.counters.subtracting(pricingCounters).totalTokens)
    }
    guard unmatchedModels.isEmpty else { return nil }

    return HermesUsageCostAllocationBasis(
        pricedCosts: pricedCosts,
        remainderTokenCounts: remainderTokenCounts)
}
