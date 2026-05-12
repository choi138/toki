import Foundation

enum UsageReportBuilder {
    static func report(
        from usage: RawTokenUsage,
        date: Date,
        endDate: Date,
        sourceStats: [SourceStat]) -> UsageData {
        UsageData(
            date: date,
            inputTokens: usage.inputTokens,
            outputTokens: usage.outputTokens,
            cacheReadTokens: usage.cacheReadTokens,
            cacheWriteTokens: usage.cacheWriteTokens,
            reasoningTokens: usage.reasoningTokens,
            cost: usage.cost,
            activeSeconds: usage.activeSeconds,
            workTime: usage.resolvedWorkTime,
            perModel: buildModelStats(from: usage.perModel),
            sourceStats: sourceStats,
            timeBuckets: buildTimeBuckets(
                from: usage.tokenEvents,
                startDate: date,
                endDate: endDate),
            supplementalStats: buildSupplementalStats(from: usage.supplemental),
            contextOnlyModels: buildContextOnlyModels(from: usage.supplemental))
    }
}

private struct SupplementalStatAggregateKey: Hashable {
    let label: String
    let unit: SupplementalUnit
    let source: String
    let includedInTotals: Bool
    let quality: UsageQuality
}

private struct ContextOnlyModelAggregateKey: Hashable {
    let model: String
    let source: String
    let quality: UsageQuality
}

private extension UsageReportBuilder {
    static func buildModelStats(from perModel: [String: PerModelUsage]) -> [ModelStat] {
        perModel
            .filter {
                $0.value.totalTokens > 0
                    || $0.value.activeSeconds > 0
                    || $0.value.cost > 0
            }
            .map {
                ModelStat(
                    id: $0.key,
                    totalTokens: $0.value.totalTokens,
                    cost: $0.value.cost,
                    activeSeconds: $0.value.activeSeconds,
                    sources: $0.value.sources.sorted(),
                    isPriceKnown: modelPriceLookup(for: $0.key).isPriced)
            }
            .sorted(by: modelStatSort)
    }

    static func buildTimeBuckets(
        from events: [TokenUsageEvent],
        startDate: Date,
        endDate: Date,
        calendar: Calendar = .autoupdatingCurrent) -> [UsageTimeBucket] {
        guard startDate < endDate else { return [] }

        let bucketStarts = hourlyBucketStarts(
            from: startDate,
            to: endDate,
            calendar: calendar)
        guard !bucketStarts.isEmpty else { return [] }

        var buckets = bucketStarts.reduce(into: [Date: UsageTimeBucket]()) { result, bucketStart in
            guard let nextHour = calendar.date(byAdding: .hour, value: 1, to: bucketStart) else { return }
            result[bucketStart] = .empty(
                startDate: bucketStart,
                endDate: min(nextHour, endDate))
        }

        for event in events where event.timestamp >= startDate && event.timestamp < endDate {
            guard let bucketStart = calendar.dateInterval(of: .hour, for: event.timestamp)?.start,
                  buckets[bucketStart] != nil else {
                continue
            }
            buckets[bucketStart]?.accumulate(event)
        }

        return bucketStarts.compactMap { buckets[$0] }
    }

    static func hourlyBucketStarts(
        from startDate: Date,
        to endDate: Date,
        calendar: Calendar) -> [Date] {
        guard var current = calendar.dateInterval(of: .hour, for: startDate)?.start else {
            return []
        }

        var result: [Date] = []
        while current < endDate {
            result.append(current)
            guard let next = calendar.date(byAdding: .hour, value: 1, to: current),
                  next > current else {
                break
            }
            current = next
        }
        return result
    }

    static func buildSupplementalStats(from supplemental: [SupplementalUsage]) -> [SupplementalStat] {
        var grouped: [SupplementalStatAggregateKey: Int] = [:]

        supplemental
            .filter { $0.value > 0 }
            .forEach { item in
                let key = SupplementalStatAggregateKey(
                    label: item.label,
                    unit: item.unit,
                    source: item.source,
                    includedInTotals: item.includedInTotals,
                    quality: item.quality)
                grouped[key, default: 0] += item.value
            }

        return grouped.map { key, value in
            SupplementalStat(
                id: "\(key.source)|\(key.label)|\(key.unit.rawValue)|\(key.includedInTotals)|\(key.quality.rawValue)",
                label: key.label,
                value: value,
                unit: key.unit,
                source: key.source,
                includedInTotals: key.includedInTotals,
                quality: key.quality)
        }
        .sorted { lhs, rhs in
            let lhsPriority = supplementalSortPriority(for: lhs)
            let rhsPriority = supplementalSortPriority(for: rhs)
            if lhsPriority != rhsPriority { return lhsPriority < rhsPriority }
            if lhs.source != rhs.source { return lhs.source < rhs.source }
            return lhs.value > rhs.value
        }
    }

    static func buildContextOnlyModels(from supplemental: [SupplementalUsage]) -> [ContextOnlyModelStat] {
        var grouped: [ContextOnlyModelAggregateKey: Int] = [:]

        supplemental
            .filter {
                $0.value > 0
                    && $0.unit == .tokens
                    && $0.quality == .contextOnly
                    && $0.model != nil
            }
            .forEach { item in
                let key = ContextOnlyModelAggregateKey(
                    model: item.model ?? "",
                    source: item.source,
                    quality: item.quality)
                grouped[key, default: 0] += item.value
            }

        return grouped.map { key, value in
            ContextOnlyModelStat(
                id: "\(key.model)|\(key.source)|\(key.quality.rawValue)",
                model: key.model,
                source: key.source,
                contextTokens: value,
                quality: key.quality)
        }
        .sorted { lhs, rhs in
            if lhs.contextTokens != rhs.contextTokens { return lhs.contextTokens > rhs.contextTokens }
            if lhs.model != rhs.model { return lhs.model < rhs.model }
            return lhs.source < rhs.source
        }
    }

    static func supplementalSortPriority(for stat: SupplementalStat) -> Int {
        if stat.label.contains("Context") { return 0 }
        if stat.label.contains("Sessions") { return 1 }
        if stat.label.contains("Reported Cost") { return 2 }

        switch stat.unit {
        case .tokens:
            return 3
        case .count:
            return 4
        case .cents:
            return 5
        }
    }
}

private func modelStatSort(_ lhs: ModelStat, _ rhs: ModelStat) -> Bool {
    if lhs.activeSeconds != rhs.activeSeconds {
        return lhs.activeSeconds > rhs.activeSeconds
    }
    if lhs.totalTokens != rhs.totalTokens {
        return lhs.totalTokens > rhs.totalTokens
    }
    if lhs.cost != rhs.cost {
        return lhs.cost > rhs.cost
    }
    return lhs.id < rhs.id
}
