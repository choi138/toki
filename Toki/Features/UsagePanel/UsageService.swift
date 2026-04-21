import Foundation

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

private let defaultUsageReaders: [any TokenReader] = [
    ClaudeCodeReader(),
    CodexReader(),
    CursorReader(),
    GeminiReader(),
    OpenCodeReader(),
    OpenClawReader(),
]

@MainActor
final class UsageService: ObservableObject {
    @Published var usageData: UsageData = .empty
    @Published var isLoading = false
    @Published var lastFetchedAt: Date?
    @Published var yesterdayTotalTokens: Int?

    @Published var startDate: Date
    @Published var endDate: Date
    @Published var isRangeMode = false

    private let readers: [any TokenReader]
    private var needsRefreshAfterCurrentLoad = false

    init(readers: [any TokenReader] = defaultUsageReaders) {
        self.readers = readers
        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())
        startDate = today
        endDate = cal.date(byAdding: .day, value: 1, to: today)!
    }

    var isSingleDay: Bool {
        let cal = Calendar.current
        return cal.dateComponents([.day], from: startDate, to: endDate).day == 1
    }

    var shouldCompareAgainstYesterday: Bool {
        isSingleDay && Calendar.current.isDateInToday(startDate)
    }

    func selectDay(_ date: Date) {
        let cal = Calendar.current
        startDate = cal.startOfDay(for: date)
        endDate = cal.date(byAdding: .day, value: 1, to: startDate)!
    }

    func selectRangeStart(_ date: Date) {
        let cal = Calendar.current
        startDate = cal.startOfDay(for: date)
        if startDate >= endDate {
            endDate = cal.date(byAdding: .day, value: 1, to: startDate)!
        }
    }

    func selectRangeEnd(_ date: Date) {
        let cal = Calendar.current
        let selectedEnd = cal.startOfDay(for: date)
        endDate = cal.date(byAdding: .day, value: 1, to: selectedEnd)!
        if startDate >= endDate {
            startDate = selectedEnd
        }
    }

    func selectRange(from: Date, to: Date) {
        let cal = Calendar.current
        let normalizedFrom = cal.startOfDay(for: from)
        let normalizedTo = cal.startOfDay(for: to)
        let lowerBound = min(normalizedFrom, normalizedTo)
        let upperBound = max(normalizedFrom, normalizedTo)
        startDate = lowerBound
        endDate = cal.date(byAdding: .day, value: 1, to: upperBound)!
    }

    func refresh() async {
        guard !isLoading else {
            needsRefreshAfterCurrentLoad = true
            return
        }

        isLoading = true
        defer {
            isLoading = false

            if needsRefreshAfterCurrentLoad {
                needsRefreshAfterCurrentLoad = false
                Task { await refresh() }
            }
        }

        let requestedStart = startDate
        let requestedEnd = endDate
        let cal = Calendar.current
        let compareAgainstYesterday =
            cal.dateComponents([.day], from: requestedStart, to: requestedEnd).day == 1
                && cal.isDateInToday(requestedStart)

        let combined = await fetchRange(from: requestedStart, to: requestedEnd)

        var previousTotalTokens: Int?
        if compareAgainstYesterday {
            let prevStart = cal.date(byAdding: .day, value: -1, to: requestedStart)!
            previousTotalTokens = await fetchRange(from: prevStart, to: requestedStart).totalTokens
        }

        guard requestedStart == startDate, requestedEnd == endDate else {
            needsRefreshAfterCurrentLoad = true
            return
        }

        let sortedModels = combined.perModel
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
                    sources: $0.value.sources.sorted())
            }
            .sorted { lhs, rhs in
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

        let supplementalStats = buildSupplementalStats(from: combined.supplemental)
        let contextOnlyModels = buildContextOnlyModels(from: combined.supplemental)

        usageData = UsageData(
            date: requestedStart,
            inputTokens: combined.inputTokens,
            outputTokens: combined.outputTokens,
            cacheReadTokens: combined.cacheReadTokens,
            cacheWriteTokens: combined.cacheWriteTokens,
            reasoningTokens: combined.reasoningTokens,
            cost: combined.cost,
            activeSeconds: combined.activeSeconds,
            perModel: sortedModels,
            supplementalStats: supplementalStats,
            contextOnlyModels: contextOnlyModels)

        yesterdayTotalTokens = previousTotalTokens
        lastFetchedAt = Date()
    }

    private func fetchRange(from start: Date, to end: Date) async -> RawTokenUsage {
        var combined = RawTokenUsage()
        await withTaskGroup(of: RawTokenUsage.self) { group in
            for reader in readers {
                group.addTask {
                    await (try? reader.readUsage(from: start, to: end)) ?? RawTokenUsage()
                }
            }
            for await partial in group {
                combined += partial
            }
        }
        combined.recomputeMergedActiveEstimate(clippingEndDate: end)
        return combined
    }

    private func buildSupplementalStats(from supplemental: [SupplementalUsage]) -> [SupplementalStat] {
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
                id: "\(key.source)|\(key.label)|\(key.unit.rawValue)|\(key.quality.rawValue)",
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

    private func buildContextOnlyModels(from supplemental: [SupplementalUsage]) -> [ContextOnlyModelStat] {
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
            return lhs.model < rhs.model
        }
    }

    private func supplementalSortPriority(for stat: SupplementalStat) -> Int {
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
