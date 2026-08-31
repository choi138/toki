import Foundation
import TokiSyncProtocol
import TokiUsageCore
import TokiUsageReaders

struct RemoteUsageMapper {
    func usageSlice(
        from snapshot: RemoteUsageSnapshot,
        startDate: Date,
        endDate: Date) -> UsageOriginSlice? {
        guard snapshot.coveredFrom < endDate, snapshot.coveredTo > startDate else { return nil }

        var usage = RawTokenUsage()
        var usageBySource: [String: RawTokenUsage] = [:]
        for event in snapshot.tokenEvents where event.timestamp >= startDate && event.timestamp < endDate {
            let model = normalizedModelID(event.model)
            let cost = tokenCost(for: event, model: model)
            appendTokenEvent(
                event,
                model: model,
                cost: cost,
                source: deviceSource(event.source, deviceName: snapshot.device.name),
                to: &usage)

            var sourceUsage = usageBySource[event.source] ?? RawTokenUsage()
            appendTokenEvent(
                event,
                model: model,
                cost: cost,
                source: event.source,
                to: &sourceUsage)
            usageBySource[event.source] = sourceUsage
        }
        appendCostEvents(
            from: snapshot,
            startDate: startDate,
            endDate: endDate,
            usage: &usage,
            usageBySource: &usageBySource)

        usage.activityEvents.append(contentsOf: mappedActivityEvents(
            from: snapshot,
            startDate: startDate,
            endDate: endDate))
        usage.recomputeMergedActiveEstimate(clippingEndDate: endDate)
        annotateActivityModelSources(
            from: snapshot,
            startDate: startDate,
            endDate: endDate,
            usage: &usage)

        let activityEventsBySource = mappedActivityEventsBySource(
            from: snapshot,
            startDate: startDate,
            endDate: endDate)
        for source in Set(usageBySource.keys).union(activityEventsBySource.keys) {
            var sourceUsage = usageBySource[source] ?? RawTokenUsage()
            sourceUsage.mergeActivityEvents(
                activityEventsBySource[source] ?? [],
                source: source,
                clippingEndDate: endDate)
            usageBySource[source] = sourceUsage
        }

        let sourceStats = usageBySource.compactMap { source, usage -> SourceStat? in
            guard usage.hasReportableData else { return nil }
            return SourceStat(
                source: source,
                inputTokens: usage.inputTokens,
                outputTokens: usage.outputTokens,
                cacheReadTokens: usage.cacheReadTokens,
                cacheWriteTokens: usage.cacheWriteTokens,
                reasoningTokens: usage.reasoningTokens,
                cost: usage.cost,
                activeSeconds: usage.activeSeconds,
                wallClockSeconds: usage.resolvedWorkTime.wallClockSeconds)
        }
        .sorted { lhs, rhs in
            if lhs.totalTokens != rhs.totalTokens { return lhs.totalTokens > rhs.totalTokens }
            return lhs.source < rhs.source
        }

        return UsageOriginSlice(
            origin: .remote(
                deviceID: snapshot.device.id,
                name: snapshot.device.name,
                platform: snapshot.device.platform,
                lastUpdatedAt: snapshot.generatedAt),
            usage: usage,
            sourceStats: sourceStats)
    }

    private func appendTokenEvent(
        _ event: RemoteTokenEvent,
        model: String?,
        cost: Double,
        source: String,
        to result: inout RawTokenUsage) {
        result.inputTokens += event.inputTokens
        result.outputTokens += event.outputTokens
        result.cacheReadTokens += event.cacheReadTokens
        result.cacheWriteTokens += event.cacheWriteTokens
        result.reasoningTokens += event.reasoningTokens
        result.cost += cost
        let modelGroupingKey = model ?? UsageModelGrouping.mixedOrUnattributedKey
        result.perModel[modelGroupingKey, default: PerModelUsage()].totalTokens += event.totalTokens
        result.perModel[modelGroupingKey, default: PerModelUsage()].cost += cost
        result.perModel[modelGroupingKey, default: PerModelUsage()].sources.insert(source)

        result.recordTokenEvent(
            timestamp: event.timestamp,
            source: source,
            model: model,
            provider: event.provider,
            inputTokens: event.inputTokens,
            outputTokens: event.outputTokens,
            cacheReadTokens: event.cacheReadTokens,
            cacheWriteTokens: event.cacheWriteTokens,
            reasoningTokens: event.reasoningTokens,
            cost: cost,
            costIsKnown: event.costIsKnown)
    }

    private func tokenCost(for event: RemoteTokenEvent, model: String?) -> Double {
        switch event.costIsKnown {
        case true:
            return event.cost ?? 0
        case false:
            return 0
        case nil:
            if let cost = event.cost, cost.isFinite, cost >= 0 {
                return cost
            }
            guard let model, let price = modelPrice(for: model, at: event.timestamp) else { return 0 }
            return price.cost(
                input: event.inputTokens,
                output: event.outputTokens + event.reasoningTokens,
                cacheRead: event.cacheReadTokens,
                cacheWrite: event.cacheWriteTokens)
        }
    }

    private func appendCostEvent(
        _ event: RemoteCostEvent,
        model: String?,
        source: String,
        to result: inout RawTokenUsage) {
        result.cost += event.cost
        let modelGroupingKey = model ?? UsageModelGrouping.mixedOrUnattributedKey
        result.perModel[modelGroupingKey, default: PerModelUsage()].cost += event.cost
        result.perModel[modelGroupingKey, default: PerModelUsage()].sources.insert(source)

        result.recordTokenEvent(
            timestamp: event.timestamp,
            source: source,
            model: model,
            inputTokens: 0,
            outputTokens: 0,
            cost: event.cost,
            costIsKnown: true)
    }

    func mappedActivityEventsBySource(
        from snapshot: RemoteUsageSnapshot,
        startDate: Date,
        endDate: Date) -> [String: [ActivityTimeEvent<String>]] {
        var eventsBySource: [String: [ActivityTimeEvent<String>]] = [:]
        for event in snapshot.activityEvents where event.timestamp >= startDate && event.timestamp < endDate {
            eventsBySource[event.source, default: []].append(ActivityTimeEvent(
                streamID: "\(snapshot.device.id):\(event.streamID)",
                timestamp: event.timestamp,
                key: activityModelID(event.model),
                agentKind: event.agentKind == .subagent ? .subagent : .main))
        }
        return eventsBySource
    }

    private func mappedActivityEvents(
        from snapshot: RemoteUsageSnapshot,
        startDate: Date,
        endDate: Date) -> [ActivityTimeEvent<String>] {
        snapshot.activityEvents.compactMap { event in
            guard event.timestamp >= startDate, event.timestamp < endDate else { return nil }
            return ActivityTimeEvent(
                streamID: "\(snapshot.device.id):\(event.streamID)",
                timestamp: event.timestamp,
                key: activityModelID(event.model),
                agentKind: event.agentKind == .subagent ? .subagent : .main)
        }
    }

    private func annotateActivityModelSources(
        from snapshot: RemoteUsageSnapshot,
        startDate: Date,
        endDate: Date,
        usage: inout RawTokenUsage) {
        for event in snapshot.activityEvents where event.timestamp >= startDate && event.timestamp < endDate {
            let model = activityModelID(event.model)
            guard usage.perModel[model] != nil else {
                continue
            }
            usage.perModel[model]?.sources.insert(
                deviceSource(event.source, deviceName: snapshot.device.name))
        }
    }

    private func activityModelID(_ model: String?) -> String {
        normalizedModelID(model) ?? UsageModelGrouping.mixedOrUnattributedKey
    }

    private func deviceSource(_ source: String, deviceName: String) -> String {
        "\(source) · \(deviceName)"
    }
}

private extension RemoteUsageMapper {
    func appendCostEvents(
        from snapshot: RemoteUsageSnapshot,
        startDate: Date,
        endDate: Date,
        usage: inout RawTokenUsage,
        usageBySource: inout [String: RawTokenUsage]) {
        for event in snapshot.costEvents ?? [] where event.timestamp >= startDate && event.timestamp < endDate {
            let model = normalizedModelID(event.model)
            appendCostEvent(
                event,
                model: model,
                source: deviceSource(event.source, deviceName: snapshot.device.name),
                to: &usage)

            var sourceUsage = usageBySource[event.source] ?? RawTokenUsage()
            appendCostEvent(
                event,
                model: model,
                source: event.source,
                to: &sourceUsage)
            usageBySource[event.source] = sourceUsage
        }
    }
}
