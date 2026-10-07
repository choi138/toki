import Foundation
import TokiUsageCore

struct CodexRolloutDailySummary {
    var dailyUsage: [String: CodexCachedDailyUsage] = [:]
    var dailyActivityTimestamps: [String: [TimeInterval]] = [:]
    var dailyTokenUsageEvents: [String: [CodexCachedTokenUsageEvent]] = [:]

    /// Whether the summary has neither usage totals nor derived activity and token events.
    var isEmpty: Bool {
        dailyUsage.isEmpty
            && dailyActivityTimestamps.isEmpty
            && dailyTokenUsageEvents.isEmpty
    }
}

struct CodexCachedDailyUsage: Codable {
    var inputTokens = 0
    var outputTokens = 0
    var cacheReadTokens = 0
    var reasoningTokens = 0
    var activeSeconds: TimeInterval = 0

    static let zero = CodexCachedDailyUsage()

    /// Total daily tokens across input, output, cached input, and reasoning categories.
    var totalTokens: Int {
        inputTokens + outputTokens + cacheReadTokens + reasoningTokens
    }

    /// Adds token categories from a parsed usage result to this daily aggregate.
    mutating func accumulate(_ usage: RawTokenUsage) {
        inputTokens += usage.inputTokens
        outputTokens += usage.outputTokens
        cacheReadTokens += usage.cacheReadTokens
        reasoningTokens += usage.reasoningTokens
    }
}

struct CodexCachedTokenUsageEvent: Codable {
    let timestamp: TimeInterval
    let inputTokens: Int
    let outputTokens: Int
    let cacheReadTokens: Int
    let reasoningTokens: Int
    let serviceTier: String?
    /// Total tokens represented by this timestamped event.
    var totalTokens: Int {
        inputTokens + outputTokens + cacheReadTokens + reasoningTokens
    }

    /// Captures a token event using an absolute timestamp and optional service tier.
    init(timestamp: Date, usage: RawTokenUsage, serviceTier: String? = nil) {
        self.timestamp = timestamp.timeIntervalSince1970
        inputTokens = usage.inputTokens
        outputTokens = usage.outputTokens
        cacheReadTokens = usage.cacheReadTokens
        reasoningTokens = usage.reasoningTokens
        self.serviceTier = serviceTier
    }
}
