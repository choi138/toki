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
    let modelPricingTimestamp: Date?
}

struct HermesResolvedUsageCost {
    let value: Double
    let isDerivedFromModelPricing: Bool
    let modelPricingTimestamp: Date?
}

private struct HermesResolvedSessionCost {
    let value: Double
    let isDerivedFromModelPricing: Bool
    let reportedValue: Double
    let modelReportedCosts: [String: Double]?
    let modelPricingCounters: [String: HermesTokenCounters]
    let modelPricingTimestamp: Date?
}

private struct HermesSessionModelUsageAccumulator {
    var counters = HermesTokenCounters.zero
    var cost = 0.0
    var reportedCost = 0.0
    var costIsDerivedFromModelPricing = true
    var countersByModel: [String: HermesTokenCounters] = [:]
    var reportedCostsByModel: [String: Double] = [:]
    var pricingCountersByModel: [String: HermesTokenCounters] = [:]
    var pricingTimestamp: Date?
    var models = Set<String>()

    var resolvedReportedCostsByModel: [String: Double]? {
        reportedCostsByModel
    }

    var hasResolvedReportedCostBreakdown: Bool {
        resolvedReportedCostsByModel?.isEmpty == false
    }

    mutating func add(_ usage: HermesSessionModelUsage) throws {
        guard usage.counters.isValid(),
              counters.canAdd(usage.counters, maximum: hermesLedgerMaximumCumulativeTokens),
              usage.cost.isFinite,
              usage.cost >= 0,
              (cost + usage.cost).isFinite,
              usage.modelPricingTimestamp.map(hermesDateIsValid) ?? true else {
            throw HermesUsageLedgerError.invalidObservation
        }
        counters = counters.adding(usage.counters)
        cost += usage.cost
        costIsDerivedFromModelPricing =
            costIsDerivedFromModelPricing && usage.costIsDerivedFromModelPricing
        if !usage.costIsDerivedFromModelPricing {
            try addReportedCost(usage)
        }

        guard usage.counters.totalTokens > 0, let model = usage.model else { return }
        countersByModel[model] = try addingHermesCounters(
            usage.counters,
            to: countersByModel[model] ?? .zero)
        if usage.costIsDerivedFromModelPricing {
            pricingCountersByModel[model] = try addingHermesCounters(
                usage.counters,
                to: pricingCountersByModel[model] ?? .zero)
            try recordPricingTimestamp(usage.modelPricingTimestamp)
        }
        models.insert(model)
    }

    private mutating func addReportedCost(_ usage: HermesSessionModelUsage) throws {
        reportedCost += usage.cost
        guard usage.cost > 0 else { return }
        guard let model = usage.model, usage.counters.totalTokens > 0 else {
            return
        }
        let existingCost = reportedCostsByModel[model] ?? 0
        guard (existingCost + usage.cost).isFinite else {
            throw HermesUsageLedgerError.invalidObservation
        }
        reportedCostsByModel[model] = existingCost + usage.cost
    }

    private mutating func recordPricingTimestamp(_ timestamp: Date?) throws {
        guard let timestamp else { return }
        guard pricingTimestamp == nil || pricingTimestamp == timestamp else {
            throw HermesUsageLedgerError.invalidObservation
        }
        pricingTimestamp = timestamp
    }
}

private func addingHermesCounters(
    _ counters: HermesTokenCounters,
    to existing: HermesTokenCounters) throws -> HermesTokenCounters {
    guard existing.canAdd(
        counters,
        maximum: hermesLedgerMaximumCumulativeTokens) else {
        throw HermesUsageLedgerError.invalidObservation
    }
    return existing.adding(counters)
}

enum HermesUsageResolver {
    static func resolve(
        session: HermesSessionObservation,
        modelUsage: [HermesSessionModelUsage]) throws -> HermesSessionObservation {
        var accumulatedModelUsage = HermesSessionModelUsageAccumulator()
        for usage in modelUsage {
            try accumulatedModelUsage.add(usage)
        }

        var models = accumulatedModelUsage.models
        if session.counters.totalTokens > 0, let model = session.model {
            models.insert(model)
        }
        let resolvedModel = models.count == 1 ? models.first : (models.isEmpty ? session.model : nil)
        let resolvedCost = resolveCost(
            session: session,
            hasModelUsage: !modelUsage.isEmpty,
            modelUsage: accumulatedModelUsage)

        return HermesSessionObservation(
            sessionID: session.sessionID,
            startedAt: session.startedAt,
            earliestActivityAt: session.earliestActivityAt,
            latestActivityAt: session.latestActivityAt,
            model: resolvedModel,
            counters: session.counters.maximum(accumulatedModelUsage.counters),
            modelCounters: modelUsage.isEmpty ? nil : accumulatedModelUsage.countersByModel,
            cost: resolvedCost.value,
            costIsDerivedFromModelPricing: resolvedCost.isDerivedFromModelPricing,
            reportedCost: resolvedCost.reportedValue,
            modelReportedCosts: resolvedCost.modelReportedCosts,
            modelPricingCounters: resolvedCost.modelPricingCounters,
            modelPricingTimestamp: resolvedCost.modelPricingTimestamp,
            projectName: session.projectName,
            attributionQuality: session.attributionQuality)
    }

    private static func resolveCost(
        session: HermesSessionObservation,
        hasModelUsage: Bool,
        modelUsage: HermesSessionModelUsageAccumulator) -> HermesResolvedSessionCost {
        let sessionPricingCounters = session.costIsDerivedFromModelPricing
            ? pricingCounters(model: session.model, counters: session.counters)
            : [:]
        let sessionReportedCost = session.costIsDerivedFromModelPricing ? 0 : session.cost
        if !hasModelUsage {
            return HermesResolvedSessionCost(
                value: session.cost,
                isDerivedFromModelPricing: session.costIsDerivedFromModelPricing,
                reportedValue: sessionReportedCost,
                modelReportedCosts: nil,
                modelPricingCounters: sessionPricingCounters,
                modelPricingTimestamp: session.modelPricingTimestamp)
        }
        if session.cost > modelUsage.cost {
            let modelReportedCosts = !session.costIsDerivedFromModelPricing
                && modelUsage.hasResolvedReportedCostBreakdown
                ? modelUsage.resolvedReportedCostsByModel
                : nil
            return HermesResolvedSessionCost(
                value: session.cost,
                isDerivedFromModelPricing: session.costIsDerivedFromModelPricing,
                reportedValue: sessionReportedCost,
                modelReportedCosts: modelReportedCosts,
                modelPricingCounters: sessionPricingCounters,
                modelPricingTimestamp: session.modelPricingTimestamp)
        }
        if modelUsage.cost > session.cost {
            return HermesResolvedSessionCost(
                value: modelUsage.cost,
                isDerivedFromModelPricing: modelUsage.costIsDerivedFromModelPricing,
                reportedValue: modelUsage.reportedCost,
                modelReportedCosts: modelUsage.resolvedReportedCostsByModel,
                modelPricingCounters: modelUsage.pricingCountersByModel,
                modelPricingTimestamp: modelUsage.pricingTimestamp)
        }

        if !session.costIsDerivedFromModelPricing,
           !modelUsage.hasResolvedReportedCostBreakdown {
            return HermesResolvedSessionCost(
                value: session.cost,
                isDerivedFromModelPricing: false,
                reportedValue: sessionReportedCost,
                modelReportedCosts: nil,
                modelPricingCounters: sessionPricingCounters,
                modelPricingTimestamp: session.modelPricingTimestamp)
        }
        return HermesResolvedSessionCost(
            value: modelUsage.cost,
            isDerivedFromModelPricing: modelUsage.costIsDerivedFromModelPricing,
            reportedValue: modelUsage.reportedCost,
            modelReportedCosts: modelUsage.resolvedReportedCostsByModel,
            modelPricingCounters: modelUsage.pricingCountersByModel,
            modelPricingTimestamp: modelUsage.pricingTimestamp)
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
            isDerivedFromModelPricing: false,
            modelPricingTimestamp: nil)
    }
    if estimatedCost > 0 {
        return HermesResolvedUsageCost(
            value: estimatedCost,
            isDerivedFromModelPricing: false,
            modelPricingTimestamp: nil)
    }

    let modelPricingTimestamp = timestamp ?? Date()
    let value = model
        .flatMap { modelPrice(for: $0, at: modelPricingTimestamp) }?
        .cost(
            input: counters.inputTokens,
            output: counters.outputTokens + counters.reasoningTokens,
            cacheRead: counters.cacheReadTokens,
            cacheWrite: counters.cacheWriteTokens) ?? 0
    return HermesResolvedUsageCost(
        value: value,
        isDerivedFromModelPricing: true,
        modelPricingTimestamp: modelPricingTimestamp)
}
