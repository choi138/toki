import Foundation

private struct ModelSourceAggregateKey: Hashable {
    let model: String
    let source: String
}

private struct ModelSourceStatAggregate {
    var inputTokens = 0
    var outputTokens = 0
    var cacheReadTokens = 0
    var cacheWriteTokens = 0
    var reasoningTokens = 0
    var cost: Double = 0
    var events: [TokenUsageEvent] = []

    mutating func accumulate(_ event: TokenUsageEvent) {
        inputTokens += event.inputTokens
        outputTokens += event.outputTokens
        cacheReadTokens += event.cacheReadTokens
        cacheWriteTokens += event.cacheWriteTokens
        reasoningTokens += event.reasoningTokens
        cost += event.cost
        events.append(event)
    }

    var totalTokens: Int {
        inputTokens + outputTokens + cacheReadTokens + cacheWriteTokens + reasoningTokens
    }
}

extension UsageReportBuilder {
    static func buildModelStats(from usage: RawTokenUsage) -> [ModelStat] {
        let eventStats = buildModelSourceStats(from: usage.tokenEvents)
        guard !eventStats.isEmpty else {
            return buildLegacyModelStats(from: usage.perModel)
        }

        let eventModels = Set(eventStats.map(\.modelID))
        let fallbackStats = buildLegacyModelStats(from: usage.perModel)
            .filter { !eventModels.contains($0.modelID) }

        return (eventStats + fallbackStats).sorted(by: modelStatSort)
    }

    static func buildLegacyModelStats(from perModel: [String: PerModelUsage]) -> [ModelStat] {
        perModel
            .filter {
                $0.value.totalTokens > 0
                    || $0.value.activeSeconds > 0
                    || $0.value.cost > 0
            }
            .map {
                ModelStat(
                    id: $0.key,
                    modelID: $0.key,
                    totalTokens: $0.value.totalTokens,
                    cost: $0.value.cost,
                    activeSeconds: $0.value.activeSeconds,
                    sources: $0.value.sources.sorted(),
                    isPriceKnown: modelPriceLookup(for: $0.key).isPriced)
            }
            .sorted(by: modelStatSort)
    }

    static func buildModelSourceStats(
        from events: [TokenUsageEvent],
        calendar: Calendar = .autoupdatingCurrent) -> [ModelStat] {
        var aggregates: [ModelSourceAggregateKey: ModelSourceStatAggregate] = [:]

        for event in events where event.totalTokens > 0 {
            guard let model = event.model?.trimmedNonEmpty else { continue }
            let key = ModelSourceAggregateKey(model: model, source: event.source)
            aggregates[key, default: ModelSourceStatAggregate()].accumulate(event)
        }

        let sourceCountByModel = Dictionary(
            grouping: aggregates.keys,
            by: \.model).mapValues(\.count)

        return aggregates.map { key, aggregate in
            let rowID = sourceCountByModel[key.model, default: 0] > 1
                ? "\(key.model)|\(key.source)"
                : key.model
            return ModelStat(
                id: rowID,
                modelID: key.model,
                totalTokens: aggregate.totalTokens,
                cost: aggregate.cost,
                activeSeconds: modelSourceActiveSeconds(
                    from: aggregate.events,
                    calendar: calendar),
                sources: [key.source],
                isPriceKnown: modelPriceLookup(for: key.model).isPriced)
        }
        .sorted(by: modelStatSort)
    }

    static func modelStatSort(_ lhs: ModelStat, _ rhs: ModelStat) -> Bool {
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

private func modelSourceActiveSeconds(
    from events: [TokenUsageEvent],
    calendar: Calendar) -> TimeInterval {
    let activityEvents = events.map { event in
        ActivityTimeEvent(
            streamID: modelSourceStreamID(for: event, calendar: calendar),
            timestamp: event.timestamp,
            key: event.model?.trimmedNonEmpty)
    }
    return ActivityTimeEstimator.estimate(events: activityEvents).totalSeconds
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

private extension String {
    var trimmedNonEmpty: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
