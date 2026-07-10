import Foundation

private struct ModelSourceStatAggregate {
    var totalTokens = 0
    var cost: Double = 0
    var activeSeconds: TimeInterval = 0
    var sources = Set<String>()

    init() {}

    init(usage: PerModelUsage, source: String) {
        totalTokens = usage.totalTokens
        cost = usage.cost
        activeSeconds = usage.activeSeconds
        sources = Set(usage.sources.compactMap(\.trimmedNonEmpty))
        if sources.isEmpty {
            sources.insert(source)
        }
    }

    mutating func accumulate(_ event: TokenUsageEvent) {
        totalTokens += event.totalTokens
        cost += event.cost
        sources.insert(event.source)
    }

    var hasReportableData: Bool {
        totalTokens > 0 || cost > 0 || activeSeconds > 0
    }
}

extension UsageReportBuilder {
    static func buildModelStats(
        from usage: RawTokenUsage,
        endDate: Date,
        calendar: Calendar = .autoupdatingCurrent) -> [ModelStat] {
        let authoritativeStats = authoritativeModelSourceStats(from: usage)
        let sourceMappedModels = Set(usage.perModelBySource.compactMap { item in
            modelUsageIsReportable(item.value) ? item.key.modelID : nil
        })
        var aggregates = authoritativeStats
        let eventStats = buildEventModelSourceStats(
            from: usage.tokenEvents,
            endDate: endDate,
            calendar: calendar)

        for (key, eventStat) in eventStats
            where !sourceMappedModels.contains(key.modelID)
            && aggregates[key]?.hasReportableData != true {
            aggregates[key] = eventStat
        }

        appendLegacyResiduals(
            from: usage.perModel,
            authoritativeKeys: Set(authoritativeStats.keys),
            to: &aggregates)

        let reportableAggregates = aggregates.filter(\.value.hasReportableData)
        let sourceCountByModel = Dictionary(
            grouping: reportableAggregates.keys,
            by: \.modelID).mapValues(\.count)

        return reportableAggregates.map { key, aggregate in
            let sources = aggregate.sources.sorted()
            let rowID = sourceCountByModel[key.modelID, default: 0] > 1
                ? "\(key.modelID)|\(key.source)"
                : key.modelID
            return ModelStat(
                id: rowID,
                modelID: key.modelID,
                totalTokens: aggregate.totalTokens,
                cost: aggregate.cost,
                activeSeconds: aggregate.activeSeconds,
                sources: sources,
                isPriceKnown: modelPriceLookup(for: key.modelID).isPriced)
        }
        .sorted(by: modelStatSort)
    }

    private static func authoritativeModelSourceStats(
        from usage: RawTokenUsage) -> [ModelSourceUsageKey: ModelSourceStatAggregate] {
        var result = usage.perModelBySource.reduce(
            into: [ModelSourceUsageKey: ModelSourceStatAggregate]()) { result, item in
                guard modelUsageIsReportable(item.value) else { return }
                result[item.key] = ModelSourceStatAggregate(
                    usage: item.value,
                    source: item.key.source)
            }
        let sourceMappedModels = Set(result.keys.map(\.modelID))

        for (modelID, modelUsage) in usage.perModel where !sourceMappedModels.contains(modelID) {
            guard modelUsage.sources.count == 1,
                  let source = modelUsage.sources.first else {
                continue
            }
            let key = ModelSourceUsageKey(modelID: modelID, source: source)
            if result[key]?.hasReportableData != true {
                result[key] = ModelSourceStatAggregate(
                    usage: modelUsage,
                    source: source)
            }
        }

        return result
    }

    private static func buildEventModelSourceStats(
        from events: [TokenUsageEvent],
        endDate: Date,
        calendar: Calendar) -> [ModelSourceUsageKey: ModelSourceStatAggregate] {
        var aggregates: [ModelSourceUsageKey: ModelSourceStatAggregate] = [:]
        var activityEventsBySource: [String: [ActivityTimeEvent<String>]] = [:]

        for event in events where event.totalTokens > 0 {
            guard let modelID = event.model?.trimmedNonEmpty,
                  let source = event.source.trimmedNonEmpty else {
                continue
            }
            let key = ModelSourceUsageKey(modelID: modelID, source: source)
            aggregates[key, default: ModelSourceStatAggregate()].accumulate(event)
            activityEventsBySource[source, default: []].append(
                ActivityTimeEvent(
                    streamID: modelSourceStreamID(for: event, calendar: calendar),
                    timestamp: event.timestamp,
                    key: modelID))
        }

        for (source, activityEvents) in activityEventsBySource {
            let estimate = ActivityTimeEstimator.estimate(
                events: activityEvents,
                clippingEndDate: endDate)
            for (modelID, activeSeconds) in estimate.secondsByKey {
                let key = ModelSourceUsageKey(modelID: modelID, source: source)
                aggregates[key]?.activeSeconds = activeSeconds
            }
        }

        return aggregates
    }

    private static func appendLegacyResiduals(
        from legacyStats: [String: PerModelUsage],
        authoritativeKeys: Set<ModelSourceUsageKey>,
        to aggregates: inout [ModelSourceUsageKey: ModelSourceStatAggregate]) {
        for (modelID, legacyStat) in legacyStats where modelUsageIsReportable(legacyStat) {
            if authoritativeKeys.contains(where: { $0.modelID == modelID }) {
                continue
            }

            let matchingStats = aggregates.filter { $0.key.modelID == modelID }
            let coveredTokens = matchingStats.values.reduce(0) { $0 + $1.totalTokens }
            let coveredCost = matchingStats.values.reduce(0) { $0 + $1.cost }
            let coveredActiveSeconds = matchingStats.values.reduce(0) { $0 + $1.activeSeconds }
            let residualTokens = max(0, legacyStat.totalTokens - coveredTokens)
            let residualCost = positiveDifference(legacyStat.cost, coveredCost)
            let residualActiveSeconds = positiveDifference(
                legacyStat.activeSeconds,
                coveredActiveSeconds)

            guard residualTokens > 0 || residualCost > 0 || residualActiveSeconds > 0 else {
                continue
            }

            let coveredSources = matchingStats.values.reduce(into: Set<String>()) {
                $0.formUnion($1.sources)
            }
            let uncoveredSources = legacyStat.sources.subtracting(coveredSources)
            let residualSources = uncoveredSources.isEmpty ? legacyStat.sources : uncoveredSources
            let sourceID = residualSources.isEmpty
                ? "fallback"
                : residualSources.sorted().joined(separator: "+")
            let key = ModelSourceUsageKey(modelID: modelID, source: sourceID)

            aggregates[key, default: ModelSourceStatAggregate()].totalTokens += residualTokens
            aggregates[key, default: ModelSourceStatAggregate()].cost += residualCost
            aggregates[key, default: ModelSourceStatAggregate()].activeSeconds += residualActiveSeconds
            aggregates[key, default: ModelSourceStatAggregate()].sources.formUnion(residualSources)
        }
    }

    private static func modelStatSort(_ lhs: ModelStat, _ rhs: ModelStat) -> Bool {
        if lhs.activeSeconds != rhs.activeSeconds {
            return lhs.activeSeconds > rhs.activeSeconds
        }
        if lhs.totalTokens != rhs.totalTokens {
            return lhs.totalTokens > rhs.totalTokens
        }
        if lhs.cost != rhs.cost {
            return lhs.cost > rhs.cost
        }
        if lhs.modelID != rhs.modelID {
            return lhs.modelID < rhs.modelID
        }
        return lhs.sources.joined(separator: ",") < rhs.sources.joined(separator: ",")
    }
}

private func modelUsageIsReportable(_ usage: PerModelUsage) -> Bool {
    usage.totalTokens > 0 || usage.cost > 0 || usage.activeSeconds > 0
}

private func positiveDifference(_ total: Double, _ covered: Double) -> Double {
    let difference = max(0, total - covered)
    return difference < 0.000_000_001 ? 0 : difference
}

private func modelSourceStreamID(
    for event: TokenUsageEvent,
    calendar: Calendar) -> String {
    if let sessionID = event.attribution?.sessionID?.trimmedNonEmpty {
        return "\(event.source)|\(sessionID)"
    }

    let projectKey = event.attribution?.projectPath?.trimmedNonEmpty
        ?? event.attribution?.projectName?.trimmedNonEmpty
        ?? "unknown"
    let hourStart = calendar.dateInterval(of: .hour, for: event.timestamp)?.start
        ?? event.timestamp
    return "\(event.source)|\(projectKey)|\(Int(hourStart.timeIntervalSince1970))"
}
