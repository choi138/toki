import Foundation

extension CodexReader {
    static func totalTokens(
        fromDailyUsage dailyUsage: [String: CodexCachedDailyUsage],
        from startDate: Date,
        to endDate: Date) -> Int {
        dailyTokenSum(
            fromDailyUsage: dailyUsage,
            from: startDate,
            to: endDate,
            value: \.totalTokens)
    }

    static func outputTokens(
        fromDailyUsage dailyUsage: [String: CodexCachedDailyUsage],
        from startDate: Date,
        to endDate: Date) -> Int {
        dailyTokenSum(
            fromDailyUsage: dailyUsage,
            from: startDate,
            to: endDate,
            value: \.outputTokens)
    }

    static func dailyTokenSum(
        fromDailyUsage dailyUsage: [String: CodexCachedDailyUsage],
        from startDate: Date,
        to endDate: Date,
        value: (CodexCachedDailyUsage) -> Int) -> Int {
        precondition(
            codexIsWholeDayAlignedRange(from: startDate, to: endDate),
            "Codex daily token totals require a whole-day aligned range.")

        guard !dailyUsage.isEmpty else { return 0 }

        let calendar = Calendar.current
        var currentDay = calendar.startOfDay(for: startDate)
        let endDay = calendar.startOfDay(for: endDate)
        guard currentDay < endDay else { return 0 }

        let dayCount = calendar.dateComponents([.day], from: currentDay, to: endDay).day ?? Int.max
        if dayCount > dailyUsage.count {
            let startKey = codexDayKey(for: currentDay)
            let endKey = codexDayKey(for: endDay)
            var result = 0

            for (dayKey, usage) in dailyUsage {
                guard !Task.isCancelled else { return 0 }
                guard dayKey >= startKey, dayKey < endKey else { continue }
                result += value(usage)
            }

            return result
        }

        var result = 0

        while currentDay < endDay {
            guard !Task.isCancelled else { return 0 }

            result += dailyUsage[codexDayKey(for: currentDay)].map(value) ?? 0

            guard let nextDay = calendar.date(byAdding: .day, value: 1, to: currentDay) else { break }
            currentDay = nextDay
        }

        return result
    }
}
