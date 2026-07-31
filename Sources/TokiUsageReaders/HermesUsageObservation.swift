import Foundation
import TokiUsageCore

struct HermesSessionObservation {
    let sessionID: String
    let startedAt: Date
    let earliestActivityAt: Date?
    let latestActivityAt: Date?
    let model: String?
    let counters: HermesTokenCounters
    let modelCounters: [String: HermesTokenCounters]?
    let cost: Double
    let costIsDerivedFromModelPricing: Bool
    let reportedCost: Double?
    let modelReportedCosts: [String: Double]?
    let modelPricingCounters: [String: HermesTokenCounters]?
    let modelPricingTimestamp: Date?
    let projectName: String?
    let attributionQuality: AttributionQuality

    init(
        sessionID: String,
        startedAt: Date,
        earliestActivityAt: Date?,
        latestActivityAt: Date?,
        model: String?,
        counters: HermesTokenCounters,
        modelCounters: [String: HermesTokenCounters]? = nil,
        cost: Double,
        costIsDerivedFromModelPricing: Bool = false,
        reportedCost: Double? = nil,
        modelReportedCosts: [String: Double]? = nil,
        modelPricingCounters: [String: HermesTokenCounters]? = nil,
        modelPricingTimestamp: Date? = nil,
        projectName: String?,
        attributionQuality: AttributionQuality) {
        self.sessionID = sessionID
        self.startedAt = startedAt
        self.earliestActivityAt = earliestActivityAt
        self.latestActivityAt = latestActivityAt
        self.model = model
        self.counters = counters
        self.modelCounters = modelCounters
        self.cost = cost
        self.costIsDerivedFromModelPricing = costIsDerivedFromModelPricing
        self.reportedCost = reportedCost
        self.modelReportedCosts = modelReportedCosts
        self.modelPricingCounters = modelPricingCounters
        self.modelPricingTimestamp = modelPricingTimestamp
        self.projectName = projectName
        self.attributionQuality = attributionQuality
    }
}

func validateHermesUsageObservation(
    _ observation: HermesSessionObservation,
    observedAt: Date) throws {
    guard !observation.sessionID.isEmpty,
          observation.sessionID.utf8.count <= 4096,
          hermesDateIsValid(observation.startedAt),
          observation.startedAt <= observedAt,
          observation.earliestActivityAt.map(hermesDateIsValid) ?? true,
          observation.latestActivityAt.map(hermesDateIsValid) ?? true,
          observation.counters.isValid(),
          observation.cost.isFinite,
          observation.cost >= 0,
          (observation.modelPricingTimestamp.map {
              hermesDateIsValid($0) && $0 <= observedAt
          } ?? true),
          hermesReportedCostBreakdownIsValid(
              observation.reportedCost,
              modelReportedCosts: observation.modelReportedCosts,
              modelPricingCounters: observation.modelPricingCounters,
              totalCost: observation.cost),
          observation.reportedCost != nil
          || observation.modelPricingCounters == nil
          || observation.costIsDerivedFromModelPricing,
          hermesModelPricingCountersAreValid(
              observation.modelPricingCounters,
              within: observation.counters),
          hermesModelPricingCountersAreValid(
              observation.modelCounters,
              within: observation.counters),
          observation.model?.utf8.count ?? 0 <= 512,
          observation.projectName?.utf8.count ?? 0 <= 512 else {
        throw HermesUsageLedgerError.invalidObservation
    }
}
