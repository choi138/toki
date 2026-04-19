import Foundation

// MARK: - Per-Model Stat (for view layer)

struct ModelStat {
    let id: String
    let totalTokens: Int
    let cost: Double
    let activeSeconds: TimeInterval
    let sources: [String]
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

    let perModel: [ModelStat]

    var totalTokens: Int {
        inputTokens + outputTokens + cacheReadTokens + cacheWriteTokens + reasoningTokens
    }

    /// Fraction of input-side tokens served from cache (0–100)
    var cacheEfficiency: Double {
        let denom = Double(inputTokens + cacheReadTokens)
        guard denom > 0 else { return 0 }
        return Double(cacheReadTokens) / denom * 100
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
