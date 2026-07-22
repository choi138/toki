import Foundation
import TokiUsageCore

private struct PeriodTokenTotalsRequest: Equatable {
    let endDate: Date
    let enabledReaderNames: [String: Bool]
    let includesEmptySourceRows: Bool
    let scope: UsageScope

    var cacheKey: PeriodTokenTotalsCacheKey {
        PeriodTokenTotalsCacheKey(
            endDate: endDate,
            enabledReaderNames: enabledReaderNames,
            scope: scope)
    }
}

private struct UsageServiceSnapshot: Equatable {
    var combinedUsageData: UsageData = .empty
    var originReports: [UsageOriginReport] = []
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

    @Published private(set) var selectedUsageScope: UsageScope = .all

    @Published private var snapshot = UsageServiceSnapshot()

    let settings: UsagePanelSettings

    private let aggregator: UsageAggregator
    private let periodTokenTotalsCache: PeriodTokenTotalsCache
    private var needsRefreshAfterCurrentLoad = false
    private var needsRemoteSyncRefreshAfterCurrentLoad = false
    private var needsTotalsRefreshAfterCurrentLoad = false
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

            if needsRefreshAfterCurrentLoad || needsRemoteSyncRefreshAfterCurrentLoad {
                let refreshesPeriodTokenTotals = needsTotalsRefreshAfterCurrentLoad
                needsRefreshAfterCurrentLoad = false
                needsRemoteSyncRefreshAfterCurrentLoad = false
                needsTotalsRefreshAfterCurrentLoad = false
                Task { [weak self] in
                    guard let self else { return }
                    await refresh()
                    if refreshesPeriodTokenTotals {
                        await refreshPeriodTokenTotalsIfNeeded()
                    }
                }
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

        let didFallBackToAllDevices = resolveSelectedUsageScope(
            availableReports: result.originReports)
        updateSnapshot {
            $0.combinedUsageData = result.usageData
            $0.originReports = result.originReports
            $0.readerStatuses = result.readerStatuses
            $0.lastFetchedAt = Date()
            $0.isLoading = false
        }
        didPublishResult = true

        if compareAgainstYesterday {
            startYesterdayComparison(for: request, scope: selectedUsageScope)
        }
        if didFallBackToAllDevices {
            Task { [weak self] in
                await self?.refreshPeriodTokenTotalsIfNeeded()
            }
        }
    }

    func refreshAfterRemoteSyncChange() async {
        periodTokenTotalsCache.clear()
        invalidatePeriodTokenTotals()
        if snapshot.isLoading {
            needsRemoteSyncRefreshAfterCurrentLoad = true
            needsTotalsRefreshAfterCurrentLoad = true
            return
        }
        await refresh()
        await refreshPeriodTokenTotalsIfNeeded()
    }
}

typealias UsageService = UsagePanelViewModel

extension UsagePanelViewModel {
    var readerNames: [String] {
        aggregator.readerNames
    }

    var usageData: UsageData {
        switch selectedUsageScope {
        case .all:
            snapshot.combinedUsageData
        case let .origin(originID):
            snapshot.originReports.first { $0.id == originID }?.usageData
                ?? snapshot.combinedUsageData
        }
    }

    var originReports: [UsageOriginReport] {
        snapshot.originReports
    }

    var selectedUsageOrigin: UsageOrigin? {
        guard case let .origin(originID) = selectedUsageScope else { return nil }
        return snapshot.originReports.first { $0.id == originID }?.origin
    }

    var usageScopeTitle: String {
        selectedUsageOrigin?.name ?? "All Devices"
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

    func selectUsageScope(_ scope: UsageScope) {
        guard scope != selectedUsageScope else { return }
        if case let .origin(originID) = scope,
           !snapshot.originReports.contains(where: { $0.id == originID }) {
            return
        }

        resetYesterdayComparison()
        selectedUsageScope = scope
        invalidatePeriodTokenTotals()

        let request = makeUsageRequest(start: startDate, end: endDate)
        if shouldCompareAgainstYesterday(start: request.start, end: request.end) {
            startYesterdayComparison(for: request, scope: scope)
        }

        Task { [weak self] in
            await self?.refreshPeriodTokenTotalsIfNeeded()
        }
    }

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
            includesEmptySourceRows: settings.showsZeroSourceRows,
            scope: selectedUsageScope)
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
            let totalTokens = await aggregator.aggregateTotalTokens(
                for: usageRequest,
                scope: request.scope)

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

    private func invalidatePeriodTokenTotals() {
        activePeriodTokenTotalsRequest = nil
        lastPeriodTokenTotalsRequest = nil
        lastPeriodTokenTotalsFetchedAt = nil
        updateSnapshot {
            $0.periodTokenTotals = []
            $0.isLoadingPeriodTokenTotals = false
        }
    }

    @discardableResult
    private func resolveSelectedUsageScope(
        availableReports: [UsageOriginReport]) -> Bool {
        guard case let .origin(originID) = selectedUsageScope,
              !availableReports.contains(where: { $0.id == originID }) else {
            return false
        }

        resetYesterdayComparison()
        selectedUsageScope = .all
        invalidatePeriodTokenTotals()
        return true
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

    private func startYesterdayComparison(
        for request: UsageAggregationRequest,
        scope: UsageScope) {
        yesterdayComparisonTask = Task { [weak self] in
            guard let self else { return }
            let prevStart = calendar.date(byAdding: .day, value: -1, to: request.start)!
            guard !Task.isCancelled else { return }

            let previousRequest = UsageAggregationRequest(
                start: prevStart,
                end: request.start,
                enabledReaderNames: request.enabledReaderNames,
                includesEmptySourceRows: request.includesEmptySourceRows)
            let previousTotalTokens = await aggregator.aggregateTotalTokens(
                for: previousRequest,
                scope: scope)

            guard !Task.isCancelled else { return }
            guard request == makeUsageRequest(start: startDate, end: endDate),
                  selectedUsageScope == scope,
                  shouldCompareAgainstYesterday(start: request.start, end: request.end) else {
                return
            }

            updateSnapshot { $0.yesterdayTotalTokens = previousTotalTokens }
            yesterdayComparisonTask = nil
        }
    }
}
