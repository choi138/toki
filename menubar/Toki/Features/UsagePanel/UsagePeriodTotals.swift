import Foundation

struct PeriodTokenTotalsRequest: Equatable {
    let endDate: Date
    let enabledReaderNames: [String: Bool]
    let includesEmptySourceRows: Bool
    let scope: UsageScope
    let modelScope: UsageModelScope

    var cacheKey: PeriodTokenTotalsCacheKey {
        PeriodTokenTotalsCacheKey(
            endDate: endDate,
            enabledReaderNames: enabledReaderNames,
            scope: scope,
            modelScope: modelScope)
    }
}

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

struct PeriodTokenTotalsCacheKey: Codable, Equatable {
    let endDate: Date
    let enabledReaderNames: [String: Bool]
    let scope: UsageScope
    let modelScope: UsageModelScope
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

    /// Cache keys this type no longer reads.
    ///
    /// Bumping the key leaves the previous entry unreachable but still stored, so its historical
    /// token totals and origin metadata would survive the app's own cache cleanup. Drop them
    /// whenever the cache is created or cleared.
    private static let supersededKeys = ["usagePanel.periodTokenTotalsCache.v2"]

    init(defaults: UserDefaults = .standard, key: String = "usagePanel.periodTokenTotalsCache.v3") {
        self.defaults = defaults
        self.key = key
        removeSupersededEntries()
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

    func clear() {
        defaults.removeObject(forKey: key)
        removeSupersededEntries()
    }

    private func removeSupersededEntries() {
        for supersededKey in Self.supersededKeys where supersededKey != key {
            defaults.removeObject(forKey: supersededKey)
        }
    }
}

@MainActor
extension UsagePanelViewModel {
    func refreshPeriodTokenTotals() async {
        let totalsRequest = makePeriodTokenTotalsRequest()
        publishCachedPeriodTokenTotals(for: totalsRequest)
        await refreshPeriodTokenTotals(for: totalsRequest)
    }

    func refreshPeriodTokenTotalsIfNeeded() async {
        let totalsRequest = makePeriodTokenTotalsRequest()
        if presentationSnapshot.isLoadingPeriodTokenTotals,
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

    func invalidatePeriodTokenTotals() {
        periodTokenTotalsGeneration &+= 1
        activePeriodTokenTotalsRequest = nil
        lastPeriodTokenTotalsRequest = nil
        lastPeriodTokenTotalsFetchedAt = nil
        updateSnapshot {
            $0.periodTokenTotals = []
            $0.isLoadingPeriodTokenTotals = false
        }
    }
}

private extension UsagePanelViewModel {
    func refreshPeriodTokenTotals(for totalsRequest: PeriodTokenTotalsRequest) async {
        if presentationSnapshot.isLoadingPeriodTokenTotals,
           activePeriodTokenTotalsRequest == totalsRequest {
            return
        }

        let generation = periodTokenTotalsGeneration
        activePeriodTokenTotalsRequest = totalsRequest
        updateSnapshot { $0.isLoadingPeriodTokenTotals = true }
        var didPublishResult = false
        defer {
            if !didPublishResult,
               Task.isCancelled,
               generation == periodTokenTotalsGeneration,
               activePeriodTokenTotalsRequest == totalsRequest {
                updateSnapshot { $0.isLoadingPeriodTokenTotals = false }
                activePeriodTokenTotalsRequest = nil
            }
        }

        let summaries = await periodTokenTotals(for: totalsRequest)

        guard !Task.isCancelled else { return }
        guard generation == periodTokenTotalsGeneration else { return }
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
    func publishCachedPeriodTokenTotals(
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

    func isFreshPeriodTokenTotals(for request: PeriodTokenTotalsRequest) -> Bool {
        guard lastPeriodTokenTotalsRequest == request,
              hasFreshPeriodTokenTotals else {
            return false
        }
        return true
    }

    var hasFreshPeriodTokenTotals: Bool {
        guard let lastPeriodTokenTotalsFetchedAt else { return false }
        return Date().timeIntervalSince(lastPeriodTokenTotalsFetchedAt) < Self.periodTokenTotalsCacheMaxAge
    }

    func isFresh(_ entry: PeriodTokenTotalsCacheEntry) -> Bool {
        Date().timeIntervalSince(entry.fetchedAt) < Self.periodTokenTotalsCacheMaxAge
    }

    func makePeriodTokenTotalsRequest() -> PeriodTokenTotalsRequest {
        let today = calendar.startOfDay(for: Date())
        let endDate = calendar.date(byAdding: .day, value: 1, to: today) ?? today
        return PeriodTokenTotalsRequest(
            endDate: endDate,
            enabledReaderNames: settings.normalizedReaderSettings(for: readerNames),
            includesEmptySourceRows: settings.showsZeroSourceRows,
            scope: selectedUsageScope,
            modelScope: selectedModelScope)
    }

    func periodTokenTotals(for request: PeriodTokenTotalsRequest) async -> [TokenTotalSummary] {
        var summaries: [TokenTotalSummary] = []

        for period in TokenTotalPeriod.allCases {
            guard !Task.isCancelled else { return summaries }

            let interval = period.dateInterval(endingAt: request.endDate, calendar: calendar)
            let usageRequest = UsageAggregationRequest(
                start: interval.start,
                end: interval.end,
                enabledReaderNames: request.enabledReaderNames,
                includesEmptySourceRows: request.includesEmptySourceRows)
            let result = await aggregator.aggregateTotalTokenResult(
                for: usageRequest,
                scope: request.scope,
                modelScope: request.modelScope)
            guard !Task.isCancelled else { return summaries }
            summaries.append(
                TokenTotalSummary(
                    period: period,
                    startDate: interval.start,
                    endDate: interval.end,
                    totalTokens: result.totalTokens))
        }

        return summaries
    }
}
