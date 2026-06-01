import Foundation

enum TokenTotalPeriod: String, CaseIterable, Codable, Hashable, Identifiable {
    case last7Days
    case last30Days
    case allTime

    var id: Self {
        self
    }

    var title: String {
        switch self {
        case .last7Days:
            "Last 7 Days"
        case .last30Days:
            "Last 30 Days"
        case .allTime:
            "All Time"
        }
    }

    func dateInterval(endingAt endDate: Date, calendar: Calendar) -> DateInterval {
        let startDate: Date = switch self {
        case .last7Days:
            calendar.date(byAdding: .day, value: -7, to: endDate) ?? endDate
        case .last30Days:
            calendar.date(byAdding: .day, value: -30, to: endDate) ?? endDate
        case .allTime:
            calendar.startOfDay(for: Date(timeIntervalSince1970: 0))
        }

        return DateInterval(start: min(startDate, endDate), end: endDate)
    }
}

struct TokenTotalSummary: Codable, Equatable, Identifiable {
    let period: TokenTotalPeriod
    let startDate: Date
    let endDate: Date
    let totalTokens: Int

    var id: TokenTotalPeriod {
        period
    }
}

private struct PeriodTokenTotalsRequest: Equatable {
    let endDate: Date
    let enabledReaderNames: [String: Bool]
    let includesEmptySourceRows: Bool

    var cacheKey: PeriodTokenTotalsCacheKey {
        PeriodTokenTotalsCacheKey(
            endDate: endDate,
            enabledReaderNames: enabledReaderNames)
    }
}

struct PeriodTokenTotalsCacheKey: Codable, Equatable {
    let endDate: Date
    let enabledReaderNames: [String: Bool]
}

struct PeriodTokenTotalsCacheEntry: Codable, Equatable {
    let key: PeriodTokenTotalsCacheKey
    let summaries: [TokenTotalSummary]
    let fetchedAt: Date
}

final class PeriodTokenTotalsCache {
    private let defaults: UserDefaults
    private let key: String
    private let decoder = JSONDecoder()
    private let encoder = JSONEncoder()

    init(defaults: UserDefaults = .standard, key: String = "usagePanel.periodTokenTotalsCache.v1") {
        self.defaults = defaults
        self.key = key
    }

    func entry(for requestKey: PeriodTokenTotalsCacheKey) -> PeriodTokenTotalsCacheEntry? {
        guard let data = defaults.data(forKey: key),
              let entry = try? decoder.decode(PeriodTokenTotalsCacheEntry.self, from: data),
              entry.key == requestKey else {
            return nil
        }
        return entry
    }

    func store(_ summaries: [TokenTotalSummary], for requestKey: PeriodTokenTotalsCacheKey, fetchedAt: Date = Date()) {
        let entry = PeriodTokenTotalsCacheEntry(
            key: requestKey,
            summaries: summaries,
            fetchedAt: fetchedAt)
        guard let data = try? encoder.encode(entry) else { return }
        defaults.set(data, forKey: key)
    }
}

private struct UsageServiceSnapshot: Equatable {
    var usageData: UsageData = .empty
    var isLoading = false
    var lastFetchedAt: Date?
    var yesterdayTotalTokens: Int?
    var readerStatuses: [ReaderStatus] = []
    var periodTokenTotals: [TokenTotalSummary] = []
    var isLoadingPeriodTokenTotals = false
}

@MainActor
final class UsagePanelViewModel: ObservableObject {
    private static let periodTokenTotalsCacheMaxAge: TimeInterval = 600

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
    private let periodTokenTotalsCache: PeriodTokenTotalsCache
    private var needsRefreshAfterCurrentLoad = false
    private var followsCurrentDaySelection = true
    private var calendarDayObserver: NSObjectProtocol?
    private var yesterdayComparisonTask: Task<Void, Never>?
    private var activeRefreshRequest: UsageAggregationRequest?
    private var activePeriodTokenTotalsRequest: PeriodTokenTotalsRequest?
    private var lastPeriodTokenTotalsRequest: PeriodTokenTotalsRequest?
    private var lastPeriodTokenTotalsFetchedAt: Date?

    private var calendar: Calendar {
        .autoupdatingCurrent
    }

    convenience init(
        readers: [any TokenReader] = UsageAggregator.defaultReaders,
        settings: UsagePanelSettings? = nil,
        periodTokenTotalsCache: PeriodTokenTotalsCache = PeriodTokenTotalsCache()) {
        self.init(
            aggregator: UsageAggregator(readers: readers),
            settings: settings,
            periodTokenTotalsCache: periodTokenTotalsCache)
    }

    init(
        aggregator: UsageAggregator,
        settings: UsagePanelSettings? = nil,
        periodTokenTotalsCache: PeriodTokenTotalsCache = PeriodTokenTotalsCache()) {
        self.aggregator = aggregator
        self.settings = settings ?? UsagePanelSettings(readerNames: aggregator.readerNames)
        self.periodTokenTotalsCache = periodTokenTotalsCache

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

    var periodTokenTotals: [TokenTotalSummary] {
        snapshot.periodTokenTotals
    }

    var isLoadingPeriodTokenTotals: Bool {
        snapshot.isLoadingPeriodTokenTotals
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

extension UsagePanelViewModel {
    func refreshPeriodTokenTotals() async {
        let totalsRequest = makePeriodTokenTotalsRequest()
        publishCachedPeriodTokenTotals(for: totalsRequest)
        await refreshPeriodTokenTotals(for: totalsRequest)
    }

    func refreshPeriodTokenTotalsIfNeeded() async {
        let totalsRequest = makePeriodTokenTotalsRequest()
        if snapshot.isLoadingPeriodTokenTotals,
           activePeriodTokenTotalsRequest == totalsRequest {
            return
        }

        if isFreshPeriodTokenTotals(for: totalsRequest) { return }

        if let cachedEntry = publishCachedPeriodTokenTotals(for: totalsRequest),
           isFresh(cachedEntry) {
            return
        }

        guard periodTokenTotals.isEmpty
            || lastPeriodTokenTotalsRequest != totalsRequest
            || !hasFreshPeriodTokenTotals else {
            return
        }
        await refreshPeriodTokenTotals(for: totalsRequest)
    }
}

private extension UsagePanelViewModel {
    private func updateSnapshot(_ update: (inout UsageServiceSnapshot) -> Void) {
        var nextSnapshot = snapshot
        update(&nextSnapshot)
        guard nextSnapshot != snapshot else { return }
        snapshot = nextSnapshot
    }

    private func refreshPeriodTokenTotals(for totalsRequest: PeriodTokenTotalsRequest) async {
        if snapshot.isLoadingPeriodTokenTotals,
           activePeriodTokenTotalsRequest == totalsRequest {
            return
        }

        activePeriodTokenTotalsRequest = totalsRequest
        updateSnapshot { $0.isLoadingPeriodTokenTotals = true }
        var didPublishResult = false
        defer {
            if !didPublishResult,
               Task.isCancelled,
               activePeriodTokenTotalsRequest == totalsRequest {
                updateSnapshot { $0.isLoadingPeriodTokenTotals = false }
                activePeriodTokenTotalsRequest = nil
            }
        }

        let summaries = await periodTokenTotals(for: totalsRequest)

        guard !Task.isCancelled else { return }
        guard activePeriodTokenTotalsRequest == totalsRequest else { return }
        guard makePeriodTokenTotalsRequest() == totalsRequest else {
            activePeriodTokenTotalsRequest = nil
            updateSnapshot { $0.isLoadingPeriodTokenTotals = false }
            await refreshPeriodTokenTotalsIfNeeded()
            return
        }

        updateSnapshot {
            $0.periodTokenTotals = summaries
            $0.isLoadingPeriodTokenTotals = false
        }
        activePeriodTokenTotalsRequest = nil
        lastPeriodTokenTotalsRequest = totalsRequest
        lastPeriodTokenTotalsFetchedAt = Date()
        periodTokenTotalsCache.store(
            summaries,
            for: totalsRequest.cacheKey,
            fetchedAt: lastPeriodTokenTotalsFetchedAt ?? Date())
        didPublishResult = true
    }

    @discardableResult
    private func publishCachedPeriodTokenTotals(
        for request: PeriodTokenTotalsRequest) -> PeriodTokenTotalsCacheEntry? {
        guard let cachedEntry = periodTokenTotalsCache.entry(for: request.cacheKey),
              !cachedEntry.summaries.isEmpty else {
            return nil
        }

        updateSnapshot { snapshot in
            snapshot.periodTokenTotals = cachedEntry.summaries
            snapshot.isLoadingPeriodTokenTotals = false
        }
        activePeriodTokenTotalsRequest = nil
        lastPeriodTokenTotalsRequest = request
        lastPeriodTokenTotalsFetchedAt = cachedEntry.fetchedAt
        return cachedEntry
    }

    private func isFreshPeriodTokenTotals(for request: PeriodTokenTotalsRequest) -> Bool {
        guard lastPeriodTokenTotalsRequest == request,
              hasFreshPeriodTokenTotals else {
            return false
        }
        return true
    }

    private var hasFreshPeriodTokenTotals: Bool {
        guard let lastPeriodTokenTotalsFetchedAt else { return false }
        return Date().timeIntervalSince(lastPeriodTokenTotalsFetchedAt) < Self.periodTokenTotalsCacheMaxAge
    }

    private func isFresh(_ entry: PeriodTokenTotalsCacheEntry) -> Bool {
        Date().timeIntervalSince(entry.fetchedAt) < Self.periodTokenTotalsCacheMaxAge
    }

    private func handleCalendarDayChange(now: Date = Date()) {
        guard syncSelectionWithTodayIfNeeded(now: now) else { return }
        Task {
            await refresh()
            await refreshPeriodTokenTotalsIfNeeded()
        }
    }

    private func makeUsageRequest(start: Date, end: Date) -> UsageAggregationRequest {
        UsageAggregationRequest(
            start: start,
            end: end,
            enabledReaderNames: settings.normalizedReaderSettings(for: readerNames),
            includesEmptySourceRows: settings.showsZeroSourceRows)
    }

    private func makePeriodTokenTotalsRequest() -> PeriodTokenTotalsRequest {
        let today = calendar.startOfDay(for: Date())
        let endDate = calendar.date(byAdding: .day, value: 1, to: today) ?? today
        return PeriodTokenTotalsRequest(
            endDate: endDate,
            enabledReaderNames: settings.normalizedReaderSettings(for: readerNames),
            includesEmptySourceRows: settings.showsZeroSourceRows)
    }

    private func periodTokenTotals(for request: PeriodTokenTotalsRequest) async -> [TokenTotalSummary] {
        var summaries: [TokenTotalSummary] = []

        for period in TokenTotalPeriod.allCases {
            guard !Task.isCancelled else { return summaries }

            let interval = period.dateInterval(endingAt: request.endDate, calendar: calendar)
            let usageRequest = UsageAggregationRequest(
                start: interval.start,
                end: interval.end,
                enabledReaderNames: request.enabledReaderNames,
                includesEmptySourceRows: request.includesEmptySourceRows)
            let totalTokens = await aggregator.aggregateTotalTokens(for: usageRequest)

            guard !Task.isCancelled else { return summaries }
            summaries.append(
                TokenTotalSummary(
                    period: period,
                    startDate: interval.start,
                    endDate: interval.end,
                    totalTokens: totalTokens))
        }

        return summaries
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
            let previousTotalTokens = await aggregator.aggregateTotalTokens(for: previousRequest)

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
