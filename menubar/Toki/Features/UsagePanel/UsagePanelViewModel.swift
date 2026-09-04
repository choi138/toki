import Foundation
import TokiUsageCore

// swiftlint:disable file_length

struct UsageServiceSnapshot: Equatable {
    var combinedUsageData: UsageData = .empty
    var combinedModelReports: [String: UsageModelReport] = [:]
    var originReports: [UsageOriginReport] = []
    var isLoading = false
    var isRefreshing = false
    var lastFetchedAt: Date?
    var yesterdayTotalTokens: Int?
    var readerStatuses: [ReaderStatus] = []
    var periodTokenTotals: [TokenTotalSummary] = []
    var isLoadingPeriodTokenTotals = false
}

private struct LastSuccessfulUsage {
    let result: UsageAggregationResult
    let fetchedAt: Date
}

@MainActor
final class UsagePanelViewModel: ObservableObject {
    static let periodTokenTotalsCacheMaxAge: TimeInterval = 600

    @Published var startDate: Date
    @Published var endDate: Date
    @Published var isRangeMode = false {
        didSet {
            guard oldValue != isRangeMode else { return }
            cancelActiveUsageRefresh()
            resetYesterdayComparison()
            clearPresentedUsage()
            if isRangeMode {
                followsCurrentDaySelection = false
            }
        }
    }

    @Published private(set) var selectedUsageScope: UsageScope = .all
    @Published private(set) var selectedModelScope: UsageModelScope = .all

    @Published private var snapshot = UsageServiceSnapshot()

    let settings: UsagePanelSettings

    let aggregator: UsageAggregator
    let periodTokenTotalsCache: PeriodTokenTotalsCache
    private let usageWindowResultCache: UsageWindowResultCache
    private let comparisonDebounce: Duration
    private var followsCurrentDaySelection = true
    private var calendarDayObserver: NSObjectProtocol?
    private var yesterdayComparisonTask: Task<Void, Never>?
    private var activeUsageTask: Task<UsageAggregationResult, Never>?
    private var activeRefreshIdentity: UsageRefreshIdentity?
    private var usageRefreshGeneration: UInt64 = 0
    private var presentedUsageRequest: UsageAggregationRequest?
    private var presentedUsageWindow: CurrentUsageWindow?
    private var lastSuccessfulUsageIdentity: UsageRefreshIdentity?
    private var lastSuccessfulUsage: LastSuccessfulUsage?
    var activePeriodTokenTotalsRequest: PeriodTokenTotalsRequest?
    var periodTokenTotalsGeneration: UInt64 = 0
    var lastPeriodTokenTotalsRequest: PeriodTokenTotalsRequest?
    var lastPeriodTokenTotalsFetchedAt: Date?
    private let now: () -> Date

    var calendar: Calendar {
        .autoupdatingCurrent
    }

    convenience init(
        readers: [any TokenReader] = UsageAggregator.defaultReaders,
        settings: UsagePanelSettings? = nil,
        periodTokenTotalsCache: PeriodTokenTotalsCache = PeriodTokenTotalsCache(),
        usageWindowResultCache: UsageWindowResultCache = UsageWindowResultCache(),
        comparisonDebounce: Duration = .milliseconds(300),
        now: @escaping () -> Date = { Date() }) {
        self.init(
            aggregator: UsageAggregator(readers: readers),
            settings: settings,
            periodTokenTotalsCache: periodTokenTotalsCache,
            usageWindowResultCache: usageWindowResultCache,
            comparisonDebounce: comparisonDebounce,
            now: now)
    }

    init(
        aggregator: UsageAggregator,
        settings: UsagePanelSettings? = nil,
        periodTokenTotalsCache: PeriodTokenTotalsCache = PeriodTokenTotalsCache(),
        usageWindowResultCache: UsageWindowResultCache = UsageWindowResultCache(),
        comparisonDebounce: Duration = .milliseconds(300),
        now: @escaping () -> Date = { Date() }) {
        self.aggregator = aggregator
        self.settings = settings ?? UsagePanelSettings(readerNames: aggregator.readerNames)
        self.periodTokenTotalsCache = periodTokenTotalsCache
        self.usageWindowResultCache = usageWindowResultCache
        self.comparisonDebounce = comparisonDebounce
        self.now = now

        let calendar = Calendar.autoupdatingCurrent
        let today = calendar.startOfDay(for: now())
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
        activeUsageTask?.cancel()
        if let calendarDayObserver {
            NotificationCenter.default.removeObserver(calendarDayObserver)
        }
    }

    func selectDay(_ date: Date) {
        cancelActiveUsageRefresh()
        resetYesterdayComparison()
        clearPresentedUsage()
        startDate = calendar.startOfDay(for: date)
        endDate = calendar.date(byAdding: .day, value: 1, to: startDate)!
        followsCurrentDaySelection = calendar.isDateInToday(startDate)
    }

    func selectRangeStart(_ date: Date) {
        cancelActiveUsageRefresh()
        resetYesterdayComparison()
        clearPresentedUsage()
        startDate = calendar.startOfDay(for: date)
        if startDate >= endDate {
            endDate = calendar.date(byAdding: .day, value: 1, to: startDate)!
        }
        followsCurrentDaySelection = false
    }

    func selectRangeEnd(_ date: Date) {
        cancelActiveUsageRefresh()
        resetYesterdayComparison()
        clearPresentedUsage()
        let selectedEnd = calendar.startOfDay(for: date)
        endDate = calendar.date(byAdding: .day, value: 1, to: selectedEnd)!
        if startDate >= endDate {
            startDate = selectedEnd
        }
        followsCurrentDaySelection = false
    }

    func refresh(usesWindowResultCache: Bool = false) async {
        let refreshNow = now()
        syncSelectionWithTodayIfNeeded(now: refreshNow)
        let request = makeUsageRequest(
            start: startDate,
            end: endDate,
            now: refreshNow)
        let refreshIdentity = makeUsageRefreshIdentity()
        var previousTotalTokens = preservedPreviousTotalTokens(for: refreshIdentity)

        cancelYesterdayComparison()
        let cacheKey = makeUsageWindowResultCacheKey()
        if usesWindowResultCache,
           let cacheKey,
           let didFallBackToAllDevices = publishCachedUsage(
               cacheKey: cacheKey,
               now: refreshNow) {
            previousTotalTokens = preservedPreviousTotalTokens(for: refreshIdentity) ?? previousTotalTokens
            refreshPeriodTokenTotalsAfterScopeFallbackIfNeeded(didFallBackToAllDevices)
        }

        if let activeUsageTask {
            guard activeRefreshIdentity != refreshIdentity || activeUsageTask.isCancelled else { return }
            cancelActiveUsageRefresh()
        }

        usageRefreshGeneration &+= 1
        let generation = usageRefreshGeneration
        activeRefreshIdentity = refreshIdentity
        updateSnapshot {
            $0.isLoading = presentedUsageRequest == nil
            $0.isRefreshing = presentedUsageRequest != nil
        }
        let usageTask = Task { await aggregator.aggregateUsage(for: request) }
        activeUsageTask = usageTask
        let result = await withTaskCancellationHandler {
            await usageTask.value
        } onCancel: {
            usageTask.cancel()
        }

        guard !Task.isCancelled,
              !usageTask.isCancelled,
              generation == usageRefreshGeneration,
              activeRefreshIdentity == refreshIdentity,
              makeUsageRefreshIdentity() == refreshIdentity else {
            finishCanceledUsageRefresh(generation: generation)
            return
        }

        activeUsageTask = nil
        activeRefreshIdentity = nil
        let fetchedAt = now()
        previousTotalTokens = canCachePreviousComparison ? previousTotalTokens : nil
        let publication = resultPreservingLastSuccessfulUsage(
            result,
            for: refreshIdentity,
            fetchedAt: fetchedAt)
        let didFallBackToAllDevices = publishUsageResult(
            publication.result,
            request: request,
            fetchedAt: publication.fetchedAt,
            previousTotalTokens: previousTotalTokens,
            currentUsageWindow: selectedCurrentUsageWindow)
        if let cacheKey, !publication.result.readerStatuses.contains(where: { $0.state == .failed }) {
            usageWindowResultCache.store(
                UsageWindowResultCacheEntry(
                    request: request,
                    result: publication.result,
                    fetchedAt: publication.fetchedAt,
                    previousTotalTokens: previousTotalTokens),
                for: cacheKey,
                now: fetchedAt)
        }

        if shouldCompareAgainstYesterday(start: request.start, end: request.end) {
            startYesterdayComparison(
                for: request,
                scope: selectedUsageScope,
                modelScope: selectedModelScope,
                cacheKey: canCachePreviousComparison ? cacheKey : nil)
        }
        refreshPeriodTokenTotalsAfterScopeFallbackIfNeeded(didFallBackToAllDevices)
    }
}

typealias UsageService = UsagePanelViewModel

extension UsagePanelViewModel {
    func selectRange(from: Date, to: Date) {
        cancelActiveUsageRefresh()
        resetYesterdayComparison()
        clearPresentedUsage()
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

        cancelActiveUsageRefresh()
        resetYesterdayComparison()
        clearPresentedUsage()
        startDate = today
        endDate = calendar.date(byAdding: .day, value: 1, to: today)!
        followsCurrentDaySelection = true
        return true
    }

    func refreshAfterRemoteSyncChange() async {
        cancelActiveUsageRefresh()
        clearLastSuccessfulUsage()
        usageWindowResultCache.clear()
        periodTokenTotalsCache.clear()
        invalidatePeriodTokenTotals()
        await refresh()
        await refreshPeriodTokenTotalsIfNeeded()
    }

    var readerNames: [String] {
        aggregator.readerNames
    }

    var presentationSnapshot: UsageServiceSnapshot {
        snapshot
    }

    var isSingleDay: Bool {
        calendar.dateComponents([.day], from: startDate, to: endDate).day == 1
    }

    var currentUsageWindowForPresentation: CurrentUsageWindow? {
        guard isShowingCurrentUsageWindow else { return nil }
        return presentedUsageRequest == nil
            ? selectedCurrentUsageWindow
            : presentedUsageWindow
    }

    var shouldCompareAgainstYesterday: Bool {
        isShowingCurrentUsageWindow
    }

    func handleModelPricingChange() {
        cancelActiveUsageRefresh()
        clearLastSuccessfulUsage()
        usageWindowResultCache.clear()
    }

    @discardableResult
    func handleCurrentUsageWindowChange() -> Bool {
        guard isShowingCurrentUsageWindow else { return false }
        cancelActiveUsageRefresh()
        resetYesterdayComparison()
        updateSnapshot {
            $0.isLoading = presentedUsageRequest == nil
            $0.isRefreshing = presentedUsageRequest != nil
        }
        return true
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

        let request = presentedUsageRequest ?? makeUsageRequest(
            start: startDate,
            end: endDate,
            now: now())
        if shouldCompareAgainstYesterday(start: request.start, end: request.end) {
            startYesterdayComparison(
                for: request,
                scope: scope,
                modelScope: selectedModelScope)
        }

        Task { [weak self] in
            await self?.refreshPeriodTokenTotalsIfNeeded()
        }
    }

    func selectModelScope(_ scope: UsageModelScope) {
        guard scope != selectedModelScope else { return }

        resetYesterdayComparison()
        selectedModelScope = scope
        invalidatePeriodTokenTotals()

        let request = presentedUsageRequest ?? makeUsageRequest(
            start: startDate,
            end: endDate,
            now: now())
        if shouldCompareAgainstYesterday(start: request.start, end: request.end) {
            startYesterdayComparison(
                for: request,
                scope: selectedUsageScope,
                modelScope: scope)
        }

        Task { [weak self] in
            await self?.refreshPeriodTokenTotalsIfNeeded()
        }
    }

    func updateSnapshot(_ update: (inout UsageServiceSnapshot) -> Void) {
        var nextSnapshot = snapshot
        update(&nextSnapshot)
        guard nextSnapshot != snapshot else { return }
        snapshot = nextSnapshot
    }
}

private extension UsagePanelViewModel {
    func resultPreservingLastSuccessfulUsage(
        _ result: UsageAggregationResult,
        for identity: UsageRefreshIdentity,
        fetchedAt: Date) -> LastSuccessfulUsage {
        guard result.readerStatuses.contains(where: { $0.state == .failed }) else {
            let successfulUsage = LastSuccessfulUsage(result: result, fetchedAt: fetchedAt)
            lastSuccessfulUsageIdentity = identity
            lastSuccessfulUsage = successfulUsage
            return successfulUsage
        }
        let participatingStatuses = result.readerStatuses.filter { $0.state != .disabled }
        guard !participatingStatuses.isEmpty,
              participatingStatuses.allSatisfy({ $0.state == .failed }),
              lastSuccessfulUsageIdentity == identity,
              let lastSuccessfulUsage else {
            return LastSuccessfulUsage(result: result, fetchedAt: fetchedAt)
        }
        return LastSuccessfulUsage(
            result: UsageAggregationResult(
                usageData: lastSuccessfulUsage.result.usageData,
                modelReports: lastSuccessfulUsage.result.modelReports,
                originReports: lastSuccessfulUsage.result.originReports,
                readerStatuses: result.readerStatuses),
            fetchedAt: lastSuccessfulUsage.fetchedAt)
    }

    func clearLastSuccessfulUsage() {
        lastSuccessfulUsageIdentity = nil
        lastSuccessfulUsage = nil
    }

    func clearPresentedUsage() {
        presentedUsageRequest = nil
        presentedUsageWindow = nil
        updateSnapshot {
            $0.combinedUsageData = .empty
            $0.combinedModelReports = [:]
            $0.originReports = []
            $0.readerStatuses = []
            $0.lastFetchedAt = nil
            $0.yesterdayTotalTokens = nil
            $0.isLoading = false
            $0.isRefreshing = false
        }
    }

    func publishCachedUsage(
        cacheKey: UsageWindowResultCacheKey,
        now: Date) -> Bool? {
        guard let cachedEntry = usageWindowResultCache.entry(for: cacheKey, now: now) else { return nil }
        if case let .origin(originID) = selectedUsageScope,
           !cachedEntry.result.originReports.contains(where: { $0.id == originID }) {
            return nil
        }
        let previousTotalTokens = canCachePreviousComparison ? cachedEntry.previousTotalTokens : nil
        let didFallBackToAllDevices = publishUsageResult(
            cachedEntry.result,
            request: cachedEntry.request,
            fetchedAt: cachedEntry.fetchedAt,
            previousTotalTokens: previousTotalTokens,
            currentUsageWindow: selectedCurrentUsageWindow,
            resolvesMissingScope: false)
        lastSuccessfulUsageIdentity = makeUsageRefreshIdentity()
        lastSuccessfulUsage = LastSuccessfulUsage(
            result: cachedEntry.result,
            fetchedAt: cachedEntry.fetchedAt)
        updateSnapshot {
            $0.isLoading = false
            $0.isRefreshing = true
        }
        return didFallBackToAllDevices
    }

    var isShowingCurrentUsageWindow: Bool {
        !isRangeMode && followsCurrentDaySelection && isSingleDay
    }

    var selectedCurrentUsageWindow: CurrentUsageWindow? {
        guard isShowingCurrentUsageWindow else { return nil }
        return settings.currentUsageWindow
    }

    var canCachePreviousComparison: Bool {
        selectedUsageScope == .all && selectedModelScope == .all
    }

    func preservedPreviousTotalTokens(for identity: UsageRefreshIdentity) -> Int? {
        guard canCachePreviousComparison,
              lastSuccessfulUsageIdentity == identity else {
            return nil
        }
        return snapshot.yesterdayTotalTokens
    }

    private func cancelActiveUsageRefresh() {
        usageRefreshGeneration &+= 1
        activeUsageTask?.cancel()
        activeUsageTask = nil
        activeRefreshIdentity = nil
        updateSnapshot {
            $0.isLoading = false
            $0.isRefreshing = false
        }
    }

    private func finishCanceledUsageRefresh(generation: UInt64) {
        guard generation == usageRefreshGeneration else { return }
        activeUsageTask = nil
        activeRefreshIdentity = nil
        updateSnapshot {
            $0.isLoading = false
            $0.isRefreshing = false
        }
    }

    private func makeUsageWindowResultCacheKey() -> UsageWindowResultCacheKey? {
        guard let window = selectedCurrentUsageWindow else { return nil }
        let enabledReaderNames = settings.normalizedReaderSettings(for: readerNames)
            .filter(\.value)
            .map(\.key)
            .sorted()
        return UsageWindowResultCacheKey(
            window: window,
            calendarDayStart: window == .calendarDay ? startDate : nil,
            enabledReaderNames: enabledReaderNames,
            includesEmptySourceRows: settings.showsZeroSourceRows)
    }

    @discardableResult
    private func publishUsageResult(
        _ result: UsageAggregationResult,
        request: UsageAggregationRequest,
        fetchedAt: Date,
        previousTotalTokens: Int?,
        currentUsageWindow: CurrentUsageWindow?,
        resolvesMissingScope: Bool = true) -> Bool {
        let didFallBackToAllDevices = resolvesMissingScope
            ? resolveSelectedUsageScope(availableReports: result.originReports)
            : false
        updateSnapshot {
            $0.combinedUsageData = result.usageData
            $0.combinedModelReports = result.modelReports
            $0.originReports = result.originReports
            $0.readerStatuses = result.readerStatuses
            $0.lastFetchedAt = fetchedAt
            $0.yesterdayTotalTokens = previousTotalTokens
            $0.isLoading = false
            $0.isRefreshing = false
        }
        presentedUsageRequest = request
        presentedUsageWindow = currentUsageWindow
        return didFallBackToAllDevices
    }

    private func refreshPeriodTokenTotalsAfterScopeFallbackIfNeeded(_ isNeeded: Bool) {
        guard isNeeded else { return }
        Task { [weak self] in
            await self?.refreshPeriodTokenTotalsIfNeeded()
        }
    }

    private func handleCalendarDayChange(now: Date = Date()) {
        guard syncSelectionWithTodayIfNeeded(now: now) else { return }
        Task {
            await refresh()
            await refreshPeriodTokenTotalsIfNeeded()
        }
    }

    private func makeUsageRefreshIdentity() -> UsageRefreshIdentity {
        UsageRefreshIdentity(
            selectionStart: startDate,
            selectionEnd: endDate,
            isRangeMode: isRangeMode,
            currentUsageWindow: selectedCurrentUsageWindow,
            enabledReaderNames: settings.normalizedReaderSettings(for: readerNames),
            includesEmptySourceRows: settings.showsZeroSourceRows)
    }

    private func makeUsageRequest(
        start: Date,
        end: Date,
        now: Date) -> UsageAggregationRequest {
        let interval = selectedCurrentUsageWindow?.dateInterval(
            at: now,
            calendar: calendar) ?? DateInterval(start: start, end: end)
        return UsageAggregationRequest(
            start: interval.start,
            end: interval.end,
            enabledReaderNames: settings.normalizedReaderSettings(for: readerNames),
            includesEmptySourceRows: settings.showsZeroSourceRows,
            liveContextWindow: selectedCurrentUsageWindow.map {
                switch $0 {
                case .calendarDay:
                    .calendarDay
                case .rolling24Hours:
                    .rolling24Hours
                }
            })
    }

    private func cancelYesterdayComparison() {
        yesterdayComparisonTask?.cancel()
        yesterdayComparisonTask = nil
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

    private func shouldCompareAgainstYesterday(start _: Date, end _: Date) -> Bool {
        isShowingCurrentUsageWindow
    }

    private func startYesterdayComparison(
        for request: UsageAggregationRequest,
        scope: UsageScope,
        modelScope: UsageModelScope,
        cacheKey: UsageWindowResultCacheKey? = nil) {
        guard let window = selectedCurrentUsageWindow else { return }
        yesterdayComparisonTask = Task { [weak self] in
            guard let self else { return }
            if comparisonDebounce > .zero {
                try? await Task.sleep(for: comparisonDebounce)
            }
            guard !Task.isCancelled else { return }
            let previousInterval = window.previousDateInterval(
                before: request.dateInterval,
                calendar: calendar)
            guard !Task.isCancelled else { return }

            let previousRequest = UsageAggregationRequest(
                start: previousInterval.start,
                end: previousInterval.end,
                enabledReaderNames: request.enabledReaderNames,
                includesEmptySourceRows: request.includesEmptySourceRows)
            let previousResult = await aggregator.aggregateTotalTokenResult(
                for: previousRequest,
                scope: scope,
                modelScope: modelScope)

            guard !Task.isCancelled else { return }
            guard request == presentedUsageRequest,
                  selectedCurrentUsageWindow == window,
                  selectedUsageScope == scope,
                  selectedModelScope == modelScope,
                  shouldCompareAgainstYesterday(start: request.start, end: request.end) else {
                return
            }

            guard !previousResult.hasReaderFailures else {
                yesterdayComparisonTask = nil
                return
            }

            updateSnapshot { $0.yesterdayTotalTokens = previousResult.totalTokens }
            if let cacheKey {
                usageWindowResultCache.storePreviousTotalTokens(
                    previousResult.totalTokens,
                    for: cacheKey,
                    matching: request)
            }
            yesterdayComparisonTask = nil
        }
    }
}
