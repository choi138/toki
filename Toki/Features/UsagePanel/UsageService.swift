import Foundation

private let defaultUsageReaders: [any TokenReader] = [
    ClaudeCodeReader(),
    CodexReader(),
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

    // Date range
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

        // Keep the previous-day comparison only for today's single-day view.
        // Running this for arbitrary past dates doubles the slow path without
        // affecting what the UI can show.
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
            .filter { $0.value.totalTokens > 0 || $0.value.activeSeconds > 0 }
            .map {
                ModelStat(
                    id: $0.key,
                    totalTokens: $0.value.totalTokens,
                    cost: $0.value.cost,
                    activeSeconds: $0.value.activeSeconds,
                    sources: $0.value.sources.sorted())
            }
            .sorted {
                if $0.activeSeconds == $1.activeSeconds {
                    return $0.totalTokens > $1.totalTokens
                }
                return $0.activeSeconds > $1.activeSeconds
            }

        usageData = UsageData(
            date: requestedStart,
            inputTokens: combined.inputTokens,
            outputTokens: combined.outputTokens,
            cacheReadTokens: combined.cacheReadTokens,
            cacheWriteTokens: combined.cacheWriteTokens,
            reasoningTokens: combined.reasoningTokens,
            cost: combined.cost,
            activeSeconds: combined.activeSeconds,
            perModel: sortedModels)

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
}
