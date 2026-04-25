import Foundation

// MARK: - Per-Model Stat (for view layer)

struct ModelStat {
    let id: String
    let totalTokens: Int
    let cost: Double
    let activeSeconds: TimeInterval
    let sources: [String]
}

struct SupplementalStat {
    let id: String
    let label: String
    let value: Int
    let unit: SupplementalUnit
    let source: String
    let includedInTotals: Bool
    let quality: UsageQuality

    var formattedValue: String {
        switch unit {
        case .tokens:
            value.formattedTokens()
        case .count:
            "\(value)"
        case .cents:
            (Double(value) / 100).formattedCost()
        }
    }
}

struct ContextOnlyModelStat {
    let id: String
    let model: String
    let source: String
    let contextTokens: Int
    let quality: UsageQuality
}

// MARK: - Model

struct UsageData {
    let date: Date
    let inputTokens: Int
    let outputTokens: Int
    let cacheReadTokens: Int
    let cacheWriteTokens: Int
    let reasoningTokens: Int
    let cost: Double
    let activeSeconds: TimeInterval
    let workTime: WorkTimeMetrics

    let perModel: [ModelStat]
    let supplementalStats: [SupplementalStat]
    let contextOnlyModels: [ContextOnlyModelStat]

    init(
        date: Date,
        inputTokens: Int,
        outputTokens: Int,
        cacheReadTokens: Int,
        cacheWriteTokens: Int,
        reasoningTokens: Int,
        cost: Double,
        activeSeconds: TimeInterval,
        workTime: WorkTimeMetrics? = nil,
        perModel: [ModelStat],
        supplementalStats: [SupplementalStat] = [],
        contextOnlyModels: [ContextOnlyModelStat] = []) {
        self.date = date
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.cacheReadTokens = cacheReadTokens
        self.cacheWriteTokens = cacheWriteTokens
        self.reasoningTokens = reasoningTokens
        self.cost = cost
        self.activeSeconds = activeSeconds
        self.workTime = workTime ?? .fallback(activeSeconds: activeSeconds)
        self.perModel = perModel
        self.supplementalStats = supplementalStats
        self.contextOnlyModels = contextOnlyModels
    }

    var totalTokens: Int {
        inputTokens + outputTokens + cacheReadTokens + cacheWriteTokens + reasoningTokens
    }

    /// Fraction of input-side tokens served from cache (0–100)
    var cacheEfficiency: Double {
        let denom = Double(inputTokens + cacheReadTokens)
        guard denom > 0 else { return 0 }
        return Double(cacheReadTokens) / denom * 100
    }

    var hasExcludedSupplementalStats: Bool {
        supplementalStats.contains { !$0.includedInTotals }
    }
}

// MARK: - Static Values

extension UsageData {
    static let mock = UsageData(
        date: Calendar.current.date(
            from: DateComponents(year: 2026, month: 4, day: 8))!,
        inputTokens: 11_000_000,
        outputTokens: 401_900,
        cacheReadTokens: 112_600_000,
        cacheWriteTokens: 0,
        reasoningTokens: 176_400,
        cost: 64.33,
        activeSeconds: 12840,
        perModel: [])

    static var empty: UsageData {
        UsageData(
            date: Date(),
            inputTokens: 0,
            outputTokens: 0,
            cacheReadTokens: 0,
            cacheWriteTokens: 0,
            reasoningTokens: 0,
            cost: 0,
            activeSeconds: 0,
            perModel: [])
    }
}
