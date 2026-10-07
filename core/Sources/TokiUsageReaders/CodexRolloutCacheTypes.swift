import Foundation
import TokiUsageCore

struct CodexRolloutDailySummary {
    var dailyUsage: [String: CodexCachedDailyUsage] = [:]
    var dailyActivityTimestamps: [String: [TimeInterval]] = [:]
    var dailyTokenUsageEvents: [String: [CodexCachedTokenUsageEvent]] = [:]

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

    var totalTokens: Int {
        inputTokens + outputTokens + cacheReadTokens + reasoningTokens
    }

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
    var totalTokens: Int {
        inputTokens + outputTokens + cacheReadTokens + reasoningTokens
    }

    init(timestamp: Date, usage: RawTokenUsage, serviceTier: String? = nil) {
        self.timestamp = timestamp.timeIntervalSince1970
        inputTokens = usage.inputTokens
        outputTokens = usage.outputTokens
        cacheReadTokens = usage.cacheReadTokens
        reasoningTokens = usage.reasoningTokens
        self.serviceTier = serviceTier
    }
}
