import Foundation

private struct UsageServiceSnapshot: Equatable {
    var usageData: UsageData = .empty
    var isLoading = false
    var lastFetchedAt: Date?
    var yesterdayTotalTokens: Int?
    var readerStatuses: [ReaderStatus] = []
}

@MainActor
final class UsagePanelViewModel: ObservableObject {
    @Published var startDate: Date
    @Published var endDate: Date
    @Published var isRangeMode = false {
        didSet {
            if isRangeMode {
                followsCurrentDaySelection = false
            }
        }
    }

    @Published private var snapshot = UsageServiceSnapshot()

    let settings: UsagePanelSettings

    private let aggregator: UsageAggregator
    private var needsRefreshAfterCurrentLoad = false
    private var followsCurrentDaySelection = true
    private var calendarDayObserver: NSObjectProtocol?
    private var yesterdayComparisonTask: Task<Void, Never>?
    private var activeRefreshRequest: UsageAggregationRequest?

    private var calendar: Calendar {
        .autoupdatingCurrent
    }

    convenience init(readers: [any TokenReader] = UsageAggregator.defaultReaders, settings: UsagePanelSettings? = nil) {
        self.init(aggregator: UsageAggregator(readers: readers), settings: settings)
    }

    init(aggregator: UsageAggregator, settings: UsagePanelSettings? = nil) {
        self.aggregator = aggregator
        self.settings = settings ?? UsagePanelSettings(readerNames: aggregator.readerNames)

        let calendar = Calendar.autoupdatingCurrent
        let today = calendar.startOfDay(for: Date())
        startDate = today
        endDate = calendar.date(byAdding: .day, value: 1, to: today)!

        calendarDayObserver = NotificationCenter.default.addObserver(
            forName: .NSCalendarDayChanged,
            object: nil,
            queue: .main) { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.handleCalendarDayChange()
                }
            }
    }

    deinit {
        yesterdayComparisonTask?.cancel()
        if let calendarDayObserver {
            NotificationCenter.default.removeObserver(calendarDayObserver)
        }
    }

    var readerNames: [String] {
        aggregator.readerNames
    }

    var usageData: UsageData {
        snapshot.usageData
    }

    var isLoading: Bool {
        snapshot.isLoading
    }

    var lastFetchedAt: Date? {
        snapshot.lastFetchedAt
    }

    var yesterdayTotalTokens: Int? {
        snapshot.yesterdayTotalTokens
    }

    var readerStatuses: [ReaderStatus] {
        snapshot.readerStatuses
    }

    var isSingleDay: Bool {
        calendar.dateComponents([.day], from: startDate, to: endDate).day == 1
    }

    var shouldCompareAgainstYesterday: Bool {
        isSingleDay && calendar.isDateInToday(startDate)
    }

    func selectDay(_ date: Date) {
        resetYesterdayComparison()
        startDate = calendar.startOfDay(for: date)
        endDate = calendar.date(byAdding: .day, value: 1, to: startDate)!
        followsCurrentDaySelection = calendar.isDateInToday(startDate)
    }

    func selectRangeStart(_ date: Date) {
        resetYesterdayComparison()
        startDate = calendar.startOfDay(for: date)
        if startDate >= endDate {
            endDate = calendar.date(byAdding: .day, value: 1, to: startDate)!
        }
        followsCurrentDaySelection = false
    }

    func selectRangeEnd(_ date: Date) {
        resetYesterdayComparison()
        let selectedEnd = calendar.startOfDay(for: date)
        endDate = calendar.date(byAdding: .day, value: 1, to: selectedEnd)!
        if startDate >= endDate {
            startDate = selectedEnd
        }
        followsCurrentDaySelection = false
    }

    func selectRange(from: Date, to: Date) {
        resetYesterdayComparison()
        let normalizedFrom = calendar.startOfDay(for: from)
        let normalizedTo = calendar.startOfDay(for: to)
        let lowerBound = min(normalizedFrom, normalizedTo)
        let upperBound = max(normalizedFrom, normalizedTo)
        startDate = lowerBound
        endDate = calendar.date(byAdding: .day, value: 1, to: upperBound)!
        followsCurrentDaySelection = false
    }

    @discardableResult
    func syncSelectionWithTodayIfNeeded(now: Date = Date()) -> Bool {
        guard followsCurrentDaySelection else { return false }

        let today = calendar.startOfDay(for: now)
        guard startDate != today || !isSingleDay else { return false }

        resetYesterdayComparison()
        startDate = today
        endDate = calendar.date(byAdding: .day, value: 1, to: today)!
        followsCurrentDaySelection = true
        return true
    }

    func refresh() async {
        syncSelectionWithTodayIfNeeded()
        let request = makeUsageRequest(start: startDate, end: endDate)

        if snapshot.isLoading {
            guard activeRefreshRequest != request else {
                needsRefreshAfterCurrentLoad = false
                return
            }
            needsRefreshAfterCurrentLoad = true
            return
        }

        cancelYesterdayComparison()
        activeRefreshRequest = request
        updateSnapshot { $0.isLoading = true }
        var didPublishResult = false
        defer {
            activeRefreshRequest = nil
            if !didPublishResult {
                updateSnapshot { $0.isLoading = false }
            }

            if needsRefreshAfterCurrentLoad {
                needsRefreshAfterCurrentLoad = false
                Task { await refresh() }
            }
        }

        let compareAgainstYesterday = shouldCompareAgainstYesterday(
            start: request.start,
            end: request.end)
        let result = await aggregator.aggregateUsage(for: request)

        guard request == makeUsageRequest(start: startDate, end: endDate) else {
            needsRefreshAfterCurrentLoad = true
            return
        }

        updateSnapshot {
            $0.usageData = result.usageData
            $0.readerStatuses = result.readerStatuses
            $0.lastFetchedAt = Date()
            $0.isLoading = false
        }
        didPublishResult = true

        if compareAgainstYesterday {
            startYesterdayComparison(for: request)
        }
    }
}

typealias UsageService = UsagePanelViewModel

private extension UsagePanelViewModel {
    private func updateSnapshot(_ update: (inout UsageServiceSnapshot) -> Void) {
        var nextSnapshot = snapshot
        update(&nextSnapshot)
        guard nextSnapshot != snapshot else { return }
        snapshot = nextSnapshot
    }

    private func handleCalendarDayChange(now: Date = Date()) {
        guard syncSelectionWithTodayIfNeeded(now: now) else { return }
        Task { await refresh() }
    }

    private func makeUsageRequest(start: Date, end: Date) -> UsageAggregationRequest {
        UsageAggregationRequest(
            start: start,
            end: end,
            enabledReaderNames: settings.normalizedReaderSettings(for: readerNames),
            includesEmptySourceRows: settings.showsZeroSourceRows)
    }

    private func cancelYesterdayComparison() {
        yesterdayComparisonTask?.cancel()
        yesterdayComparisonTask = nil
    }

    private func resetYesterdayComparison() {
        cancelYesterdayComparison()
        if snapshot.yesterdayTotalTokens != nil {
            updateSnapshot { $0.yesterdayTotalTokens = nil }
        }
    }

    private func shouldCompareAgainstYesterday(start: Date, end: Date) -> Bool {
        calendar.dateComponents([.day], from: start, to: end).day == 1
            && calendar.isDateInToday(start)
    }

    private func startYesterdayComparison(for request: UsageAggregationRequest) {
        yesterdayComparisonTask = Task { [weak self] in
            guard let self else { return }
            let prevStart = calendar.date(byAdding: .day, value: -1, to: request.start)!
            guard !Task.isCancelled else { return }

            let previousRequest = UsageAggregationRequest(
                start: prevStart,
                end: request.start,
                enabledReaderNames: request.enabledReaderNames,
                includesEmptySourceRows: request.includesEmptySourceRows)
            let previousTotalTokens = await aggregator.aggregateUsage(for: previousRequest).usageData.totalTokens

            guard !Task.isCancelled else { return }
            guard request == makeUsageRequest(start: startDate, end: endDate),
                  shouldCompareAgainstYesterday(start: request.start, end: request.end) else {
                return
            }

            updateSnapshot { $0.yesterdayTotalTokens = previousTotalTokens }
            yesterdayComparisonTask = nil
        }
    }
}
