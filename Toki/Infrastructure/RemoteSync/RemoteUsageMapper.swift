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

        let activitySources: Set<String> = Set(snapshot.activityEvents.compactMap { event in
            guard event.timestamp >= startDate, event.timestamp < endDate else { return nil }
            return event.source
        })
        for source in Set(usageBySource.keys).union(activitySources) {
            var sourceUsage = usageBySource[source] ?? RawTokenUsage()
            sourceUsage.mergeActivityEvents(
                mappedActivityEvents(
                    from: snapshot,
                    startDate: startDate,
                    endDate: endDate,
                    matchingSource: source),
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
                activeSeconds: usage.activeSeconds)
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
        if let model {
            result.perModel[model, default: PerModelUsage()].totalTokens += event.totalTokens
            result.perModel[model, default: PerModelUsage()].cost += cost
            result.perModel[model, default: PerModelUsage()].sources.insert(source)
        }

        result.recordTokenEvent(
            timestamp: event.timestamp,
            source: source,
            model: model,
            inputTokens: event.inputTokens,
            outputTokens: event.outputTokens,
            cacheReadTokens: event.cacheReadTokens,
            cacheWriteTokens: event.cacheWriteTokens,
            reasoningTokens: event.reasoningTokens,
            cost: cost)
    }

    private func tokenCost(for event: RemoteTokenEvent, model: String?) -> Double {
        guard let model, let price = modelPrice(for: model) else { return 0 }
        return price.cost(
            input: event.inputTokens,
            output: event.outputTokens + event.reasoningTokens,
            cacheRead: event.cacheReadTokens,
            cacheWrite: event.cacheWriteTokens)
    }

    private func mappedActivityEvents(
        from snapshot: RemoteUsageSnapshot,
        startDate: Date,
        endDate: Date,
        matchingSource: String? = nil) -> [ActivityTimeEvent<String>] {
        snapshot.activityEvents.compactMap { event in
            guard event.timestamp >= startDate, event.timestamp < endDate else { return nil }
            guard matchingSource == nil || event.source == matchingSource else { return nil }
            return ActivityTimeEvent(
                streamID: "\(snapshot.device.id):\(event.streamID)",
                timestamp: event.timestamp,
                key: normalizedModelID(event.model),
                agentKind: event.agentKind == .subagent ? .subagent : .main)
        }
    }

    private func annotateActivityModelSources(
        from snapshot: RemoteUsageSnapshot,
        startDate: Date,
        endDate: Date,
        usage: inout RawTokenUsage) {
        for event in snapshot.activityEvents where event.timestamp >= startDate && event.timestamp < endDate {
            guard let model = normalizedModelID(event.model),
                  usage.perModel[model] != nil else {
                continue
            }
            usage.perModel[model]?.sources.insert(
                deviceSource(event.source, deviceName: snapshot.device.name))
        }
    }

    private func deviceSource(_ source: String, deviceName: String) -> String {
        "\(source) · \(deviceName)"
    }
}
