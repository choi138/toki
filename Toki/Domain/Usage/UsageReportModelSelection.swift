import Foundation
import TokiUsageCore
import TokiUsageReaders

private let modelAttributionCostTolerance = 0.000_000_001

extension UsageReportBuilder {
    static func buildModelReports(
        from usage: RawTokenUsage,
        startDate: Date,
        endDate: Date) -> [String: UsageModelReport] {
        let rowsByModel = Dictionary(
            grouping: buildModelStats(
                from: usage,
                startDate: startDate,
                endDate: endDate),
            by: \.modelID)
        // Grouped once so report construction stays linear in the event count rather than
        // rescanning every event, activity, and supplemental array for each model.
        let groups = ModelEventGroups(from: usage)

        return rowsByModel.reduce(into: [:]) { reports, item in
            let modelID = item.key
            let rows = item.value
            let selectedEvents = groups.tokenEvents[modelID] ?? []
            let authoritativeTokens = rows.reduce(0) { $0 + $1.totalTokens }
            let authoritativeCost = rows.reduce(0) { $0 + $1.cost }
            let eventTokens = selectedEvents.reduce(0) { $0 + $1.totalTokens }
            let eventCost = selectedEvents.reduce(0) { $0 + $1.cost }
            let hasCompatibleSources = modelEventsHaveCompatibleSources(
                selectedEvents,
                rows: rows)
            let fitsAuthoritativeSources = hasCompatibleSources
                && modelEventsFitAuthoritativeSources(selectedEvents, rows: rows)
            let isAttributionComplete = authoritativeTokens == eventTokens
                && abs(authoritativeCost - eventCost) < modelAttributionCostTolerance
                && fitsAuthoritativeSources
            let attributedEvents = eventTokens <= authoritativeTokens
                && eventCost <= authoritativeCost + modelAttributionCostTolerance
                && fitsAuthoritativeSources
                ? selectedEvents
                : []

            let selectedUsage = modelUsage(
                from: usage,
                modelID: modelID,
                rows: rows,
                groups: groups,
                selectedEvents: attributedEvents,
                authoritativeTokens: authoritativeTokens,
                authoritativeCost: authoritativeCost,
                endDate: endDate)
            let sourceStats = modelSourceStats(rows: rows, events: attributedEvents)
            let report = report(
                from: selectedUsage,
                date: startDate,
                endDate: endDate,
                sourceStats: sourceStats,
                filteredModelID: modelID,
                isModelAttributionComplete: isAttributionComplete)
            let reportRows = report.perModel.filter { $0.modelID == modelID }
            let sources = Set(reportRows.flatMap(\.sources)).sorted()
            let summary = ModelStat(
                id: modelID,
                modelID: modelID,
                totalTokens: report.totalTokens,
                cost: report.cost,
                activeSeconds: report.workTime.agentSeconds,
                wallClockSeconds: report.workTime.wallClockSeconds,
                sources: sources,
                isPriceKnown: !reportRows.isEmpty && reportRows.allSatisfy(\.isPriceKnown))

            reports[modelID] = UsageModelReport(
                modelID: modelID,
                summary: summary,
                usageData: report)
        }
    }
}

/// Per-model slices of the event-shaped fields of `RawTokenUsage`, built once per report batch.
private struct ModelEventGroups {
    let tokenEvents: [String: [TokenUsageEvent]]
    let activityEvents: [String: [ActivityTimeEvent<String>]]
    let supplemental: [String: [SupplementalUsage]]
    let perModelBySource: [String: [ModelSourceUsageKey: PerModelUsage]]

    init(from usage: RawTokenUsage) {
        tokenEvents = Dictionary(grouping: usage.tokenEvents) {
            usageModelGroupingID(for: $0.model)
        }
        activityEvents = Dictionary(grouping: usage.activityEvents) {
            usageModelGroupingID(for: $0.key)
        }
        supplemental = Dictionary(
            grouping: usage.supplemental.filter { $0.quality != .contextOnly }) {
                usageModelGroupingID(for: $0.model)
            }
        perModelBySource = usage.perModelBySource.reduce(
            into: [String: [ModelSourceUsageKey: PerModelUsage]]()) { result, item in
                result[item.key.modelID, default: [:]][item.key] = item.value
            }
    }
}

private func modelUsage(
    from usage: RawTokenUsage,
    modelID: String,
    rows: [ModelStat],
    groups: ModelEventGroups,
    selectedEvents: [TokenUsageEvent],
    authoritativeTokens: Int,
    authoritativeCost: Double,
    endDate: Date) -> RawTokenUsage {
    var selectedUsage = RawTokenUsage()

    for event in selectedEvents {
        selectedUsage.inputTokens += event.inputTokens
        selectedUsage.outputTokens += event.outputTokens
        selectedUsage.cacheReadTokens += event.cacheReadTokens
        selectedUsage.cacheWriteTokens += event.cacheWriteTokens
        selectedUsage.reasoningTokens += event.reasoningTokens
        selectedUsage.tokenEvents.append(event)
    }

    let eventTokens = selectedUsage.totalTokens
    selectedUsage.unclassifiedTokens = max(0, authoritativeTokens - eventTokens)
    selectedUsage.cost = authoritativeCost
    selectedUsage.perModelBySource = groups.perModelBySource[modelID] ?? [:]
    selectedUsage.activityEvents = groups.activityEvents[modelID] ?? []
    selectedUsage.supplemental = groups.supplemental[modelID] ?? []

    let sources = Set(rows.flatMap(\.sources))
    let rowActiveSeconds = rows.reduce(0) { $0 + $1.activeSeconds }
    let rowWallClockSeconds = rows.map(\.wallClockSeconds).max() ?? 0
    let modelTime = usage.perModel[modelID]
    let authoritativeActiveSeconds = if let modelTime, modelTime.activeSeconds > 0 {
        modelTime.activeSeconds
    } else {
        rowActiveSeconds
    }
    let authoritativeWallClockSeconds = if let modelTime, modelTime.wallClockSeconds > 0 {
        modelTime.wallClockSeconds
    } else {
        rowWallClockSeconds
    }
    selectedUsage.perModel[modelID] = PerModelUsage(
        totalTokens: authoritativeTokens,
        cost: authoritativeCost,
        activeSeconds: authoritativeActiveSeconds,
        wallClockSeconds: authoritativeWallClockSeconds,
        sources: sources)

    let observedActiveSeconds = ActivityTimeEstimator.estimate(
        events: selectedUsage.activityEvents,
        clippingEndDate: endDate).totalSeconds
    let storedFallbackSeconds = usage.fallbackActiveSecondsByModel[modelID, default: 0]
    let uncoveredActiveSeconds = max(0, authoritativeActiveSeconds - observedActiveSeconds)
    selectedUsage.fallbackActiveSeconds = max(storedFallbackSeconds, uncoveredActiveSeconds)
    selectedUsage.fallbackActiveSecondsByModel[modelID] = selectedUsage.fallbackActiveSeconds
    selectedUsage.recomputeMergedActiveEstimate(clippingEndDate: endDate)
    applyAuthoritativeModelTime(
        to: &selectedUsage,
        modelID: modelID,
        activeSeconds: authoritativeActiveSeconds,
        wallClockSeconds: authoritativeWallClockSeconds)
    return selectedUsage
}

private func applyAuthoritativeModelTime(
    to usage: inout RawTokenUsage,
    modelID: String,
    activeSeconds: TimeInterval,
    wallClockSeconds: TimeInterval) {
    let estimatedWorkTime = usage.workTime
    let hasActivity = activeSeconds > 0 || wallClockSeconds > 0
    let subagentSeconds = min(activeSeconds, estimatedWorkTime.subagentSeconds)
    let activeStreamCount = hasActivity ? max(1, estimatedWorkTime.activeStreamCount) : 0
    let maxConcurrentStreams = hasActivity ? max(1, estimatedWorkTime.maxConcurrentStreams) : 0

    usage.activeSeconds = activeSeconds
    usage.workTime = WorkTimeMetrics(
        agentSeconds: activeSeconds,
        wallClockSeconds: wallClockSeconds,
        activeStreamCount: activeStreamCount,
        maxConcurrentStreams: maxConcurrentStreams,
        mainAgentSeconds: max(0, activeSeconds - subagentSeconds),
        subagentSeconds: subagentSeconds)
    usage.perModel[modelID]?.activeSeconds = activeSeconds
    usage.perModel[modelID]?.wallClockSeconds = wallClockSeconds
}

private struct ModelSourceStatAggregate {
    let source: String
    var inputTokens = 0
    var outputTokens = 0
    var cacheReadTokens = 0
    var cacheWriteTokens = 0
    var reasoningTokens = 0
    var unclassifiedTokens = 0
    var cost: Double = 0
    var activeSeconds: TimeInterval = 0
    var wallClockSeconds: TimeInterval = 0

    mutating func accumulate(_ event: TokenUsageEvent) {
        inputTokens += event.inputTokens
        outputTokens += event.outputTokens
        cacheReadTokens += event.cacheReadTokens
        cacheWriteTokens += event.cacheWriteTokens
        reasoningTokens += event.reasoningTokens
        cost += event.cost
    }

    var totalTokens: Int {
        inputTokens + outputTokens + cacheReadTokens + cacheWriteTokens + reasoningTokens + unclassifiedTokens
    }

    var sourceStat: SourceStat {
        SourceStat(
            source: source,
            inputTokens: inputTokens,
            outputTokens: outputTokens,
            cacheReadTokens: cacheReadTokens,
            cacheWriteTokens: cacheWriteTokens,
            reasoningTokens: reasoningTokens,
            unclassifiedTokens: unclassifiedTokens,
            cost: cost,
            activeSeconds: activeSeconds,
            wallClockSeconds: wallClockSeconds)
    }
}

private func modelSourceStats(
    rows: [ModelStat],
    events: [TokenUsageEvent]) -> [SourceStat] {
    let stats = buildModelSourceStats(rows: rows, events: events)
    let authoritativeTokens = rows.reduce(0) { $0 + $1.totalTokens }
    let authoritativeCost = rows.reduce(0) { $0 + $1.cost }
    let reportedTokens = stats.reduce(0) { $0 + $1.totalTokens }
    let reportedCost = stats.reduce(0) { $0 + $1.cost }

    guard reportedTokens != authoritativeTokens
        || abs(reportedCost - authoritativeCost) >= modelAttributionCostTolerance else {
        return stats
    }
    return buildModelSourceStats(rows: rows, events: [])
}

private func buildModelSourceStats(
    rows: [ModelStat],
    events: [TokenUsageEvent]) -> [SourceStat] {
    var aggregates: [String: ModelSourceStatAggregate] = [:]

    for event in events {
        var aggregate = aggregates[event.source] ?? ModelSourceStatAggregate(source: event.source)
        aggregate.accumulate(event)
        aggregates[event.source] = aggregate
    }

    for row in rows {
        let rowSources = row.sources.compactMap(\.trimmedNonEmpty)
        let coveredSources = rowSources.isEmpty ? [] : rowSources
        let coveredTokens = coveredSources.reduce(0) { $0 + aggregates[$1, default: .init(source: $1)].totalTokens }
        let coveredCost = coveredSources.reduce(0) { $0 + aggregates[$1, default: .init(source: $1)].cost }
        let residualTokens = max(0, row.totalTokens - coveredTokens)
        let residualCost = max(0, row.cost - coveredCost)
        let source = rowSources.count == 1
            ? rowSources[0]
            : rowSources.joined(separator: ", ").trimmedNonEmpty ?? "Unknown Source"
        var aggregate = aggregates[source] ?? ModelSourceStatAggregate(source: source)
        aggregate.unclassifiedTokens += residualTokens
        aggregate.cost += residualCost
        aggregate.activeSeconds += row.activeSeconds
        aggregate.wallClockSeconds += row.wallClockSeconds
        aggregates[source] = aggregate
    }

    return aggregates.values
        .filter { $0.totalTokens > 0 || $0.cost > 0 || $0.activeSeconds > 0 || $0.wallClockSeconds > 0 }
        .map(\.sourceStat)
        .sorted {
            if $0.activeSeconds != $1.activeSeconds { return $0.activeSeconds > $1.activeSeconds }
            if $0.totalTokens != $1.totalTokens { return $0.totalTokens > $1.totalTokens }
            if $0.cost != $1.cost { return $0.cost > $1.cost }
            return $0.source < $1.source
        }
}

private func modelEventsHaveCompatibleSources(
    _ events: [TokenUsageEvent],
    rows: [ModelStat]) -> Bool {
    guard events.allSatisfy({ $0.source.trimmedNonEmpty != nil }) else { return false }

    var authoritativeSources = Set<String>()
    for row in rows {
        let rowSources = Set(row.sources.compactMap(\.trimmedNonEmpty))
        guard authoritativeSources.isDisjoint(with: rowSources) else { return false }
        authoritativeSources.formUnion(rowSources)
    }
    let eventSources = Set(events.compactMap(\.source.trimmedNonEmpty))
    return eventSources.isSubset(of: authoritativeSources)
}

/// Reports whether every source's detailed events fit within that source's authoritative row.
///
/// The aggregate token and cost bounds alone let one source overflow its own row while another
/// source underruns, which would leave project, session, and hourly detail attributing more usage
/// to a source than its own source row reports.
///
/// Only single-source rows define an unambiguous per-source budget. Sources covered by a combined
/// row remain bounded by the aggregate checks performed by the caller.
private func modelEventsFitAuthoritativeSources(
    _ events: [TokenUsageEvent],
    rows: [ModelStat]) -> Bool {
    var tokenBudgets: [String: Int] = [:]
    var costBudgets: [String: Double] = [:]
    for row in rows {
        let rowSources = row.sources.compactMap(\.trimmedNonEmpty)
        guard rowSources.count == 1, let source = rowSources.first else { continue }
        tokenBudgets[source, default: 0] += row.totalTokens
        costBudgets[source, default: 0] += row.cost
    }
    guard !tokenBudgets.isEmpty else { return true }

    var tokensBySource: [String: Int] = [:]
    var costBySource: [String: Double] = [:]
    for event in events {
        guard let source = event.source.trimmedNonEmpty else { continue }
        tokensBySource[source, default: 0] += event.totalTokens
        costBySource[source, default: 0] += event.cost
    }

    let tokensFit = tokensBySource.allSatisfy { source, tokens in
        guard let budget = tokenBudgets[source] else { return true }
        return tokens <= budget
    }
    let costsFit = costBySource.allSatisfy { source, cost in
        guard let budget = costBudgets[source] else { return true }
        return cost <= budget + modelAttributionCostTolerance
    }
    return tokensFit && costsFit
}

private func usageModelGroupingID(for modelID: String?) -> String {
    modelID?.trimmedNonEmpty ?? UsageModelGrouping.mixedOrUnattributedKey
}
