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

struct PeriodTokenTotalsCacheKey: Codable, Equatable {
    let endDate: Date
    let enabledReaderNames: [String: Bool]
    let scope: UsageScope
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

    init(defaults: UserDefaults = .standard, key: String = "usagePanel.periodTokenTotalsCache.v2") {
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

    func clear() {
        defaults.removeObject(forKey: key)
    }
}
