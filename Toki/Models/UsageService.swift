import Foundation

private let defaultUsageReaders: [any TokenReader] = [
    ClaudeCodeReader(),
    CodexReader(),
    GeminiReader(),
    OpenCodeReader(),
    OpenClawReader()
]

@MainActor
final class UsageService: ObservableObject {
    @Published var usageData: UsageData = .empty
    @Published var isLoading: Bool = false
    @Published var lastFetchedAt: Date?
    @Published var yesterdayTotalTokens: Int?

    // Date range
    @Published var startDate: Date
    @Published var endDate: Date
    @Published var isRangeMode: Bool = false

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

    func selectRange(from: Date, to: Date) {
        let cal = Calendar.current
        startDate = cal.startOfDay(for: from)
        endDate = cal.date(byAdding: .day, value: 1, to: cal.startOfDay(for: to))!
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
            .filter { $0.value.totalTokens > 0 }
            .map {
                ModelStat(
                    id: $0.key,
                    totalTokens: $0.value.totalTokens,
                    cost: $0.value.cost,
                    sources: $0.value.sources.sorted()
                )
            }
            .sorted { $0.totalTokens > $1.totalTokens }

        usageData = UsageData(
            date: requestedStart,
            inputTokens: combined.inputTokens,
            outputTokens: combined.outputTokens,
            cacheReadTokens: combined.cacheReadTokens,
            cacheWriteTokens: combined.cacheWriteTokens,
            reasoningTokens: combined.reasoningTokens,
            cost: combined.cost,
            perModel: sortedModels
        )

        yesterdayTotalTokens = previousTotalTokens
        lastFetchedAt = Date()
    }

    private func fetchRange(from start: Date, to end: Date) async -> RawTokenUsage {
        var combined = RawTokenUsage()
        await withTaskGroup(of: RawTokenUsage.self) { group in
            readers.forEach { reader in
                group.addTask {
                    (try? await reader.readUsage(from: start, to: end)) ?? RawTokenUsage()
                }
            }
            for await partial in group {
                combined += partial
            }
        }
        return combined
    }
}
