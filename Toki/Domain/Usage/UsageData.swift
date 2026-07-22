import Foundation
import TokiUsageCore

struct UsageOriginID: RawRepresentable, Codable, Hashable {
    let rawValue: String

    static let local = UsageOriginID(rawValue: "local")

    static func remote(deviceID: String) -> UsageOriginID {
        UsageOriginID(rawValue: "remote:\(deviceID)")
    }
}

enum UsageScope: Codable, Equatable, Hashable {
    case all
    case origin(UsageOriginID)
}

enum UsageOriginKind: String, Equatable {
    case local
    case remote
}

struct UsageOrigin: Identifiable, Equatable {
    let id: UsageOriginID
    let kind: UsageOriginKind
    let name: String
    let platform: String?
    let lastUpdatedAt: Date?

    static func local(lastUpdatedAt: Date?) -> UsageOrigin {
        UsageOrigin(
            id: .local,
            kind: .local,
            name: "This Mac",
            platform: "macOS",
            lastUpdatedAt: lastUpdatedAt)
    }

    static func remote(
        deviceID: String,
        name: String,
        platform: String?,
        lastUpdatedAt: Date?) -> UsageOrigin {
        UsageOrigin(
            id: .remote(deviceID: deviceID),
            kind: .remote,
            name: name,
            platform: platform,
            lastUpdatedAt: lastUpdatedAt)
    }
}

struct UsageOriginReport: Identifiable, Equatable {
    let origin: UsageOrigin
    let usageData: UsageData

    var id: UsageOriginID {
        origin.id
    }
}

// MARK: - Per-Model Stat (for view layer)

struct ModelStat: Equatable {
    let id: String
    let modelID: String
    let totalTokens: Int
    let cost: Double
    let activeSeconds: TimeInterval
    let sources: [String]
    let isPriceKnown: Bool

    init(
        id: String,
        modelID: String? = nil,
        totalTokens: Int,
        cost: Double,
        activeSeconds: TimeInterval,
        sources: [String],
        isPriceKnown: Bool) {
        self.id = id
        self.modelID = modelID ?? id
        self.totalTokens = totalTokens
        self.cost = cost
        self.activeSeconds = activeSeconds
        self.sources = sources
        self.isPriceKnown = isPriceKnown
    }
}

struct SourceStat: Equatable {
    let source: String
    let inputTokens: Int
    let outputTokens: Int
    let cacheReadTokens: Int
    let cacheWriteTokens: Int
    let reasoningTokens: Int
    let cost: Double
    let activeSeconds: TimeInterval

    var id: String {
        source
    }

    var totalTokens: Int {
        inputTokens + outputTokens + cacheReadTokens + cacheWriteTokens + reasoningTokens
    }
}

struct UsageTimeBucket: Identifiable, Equatable {
    let startDate: Date
    let endDate: Date
    var inputTokens: Int
    var outputTokens: Int
    var cacheReadTokens: Int
    var cacheWriteTokens: Int
    var reasoningTokens: Int
    var cost: Double

    var id: Date {
        startDate
    }

    var totalTokens: Int {
        inputTokens + outputTokens + cacheReadTokens + cacheWriteTokens + reasoningTokens
    }

    static func empty(startDate: Date, endDate: Date) -> UsageTimeBucket {
        UsageTimeBucket(
            startDate: startDate,
            endDate: endDate,
            inputTokens: 0,
            outputTokens: 0,
            cacheReadTokens: 0,
            cacheWriteTokens: 0,
            reasoningTokens: 0,
            cost: 0)
    }

    mutating func accumulate(_ event: TokenUsageEvent) {
        inputTokens += event.inputTokens
        outputTokens += event.outputTokens
        cacheReadTokens += event.cacheReadTokens
        cacheWriteTokens += event.cacheWriteTokens
        reasoningTokens += event.reasoningTokens
        cost += event.cost
    }
}

struct ProjectUsageStat: Identifiable, Equatable {
    let id: String
    let name: String
    let path: String?
    let quality: AttributionQuality
    let sources: [String]
    let sessionCount: Int
    let inputTokens: Int
    let outputTokens: Int
    let cacheReadTokens: Int
    let cacheWriteTokens: Int
    let reasoningTokens: Int
    let cost: Double
    let firstActivityAt: Date?
    let lastActivityAt: Date?

    var totalTokens: Int {
        inputTokens + outputTokens + cacheReadTokens + cacheWriteTokens + reasoningTokens
    }
}

struct SessionUsageStat: Identifiable, Equatable {
    let id: String
    let source: String
    let projectName: String
    let projectPath: String?
    let sessionID: String?
    let sessionLabel: String
    let quality: AttributionQuality
    let models: [String]
    let inputTokens: Int
    let outputTokens: Int
    let cacheReadTokens: Int
    let cacheWriteTokens: Int
    let reasoningTokens: Int
    let cost: Double
    let firstActivityAt: Date
    let lastActivityAt: Date

    var totalTokens: Int {
        inputTokens + outputTokens + cacheReadTokens + cacheWriteTokens + reasoningTokens
    }
}

enum ReaderStatusState: String {
    case loaded
    case empty
    case disabled
    case failed
}

struct ReaderStatus: Identifiable, Equatable {
    let name: String
    let state: ReaderStatusState
    let message: String?
    let lastReadAt: Date?
    let totalTokens: Int

    var id: String {
        name
    }
}

struct SupplementalStat: Equatable {
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

struct ContextOnlyModelStat: Equatable {
    let id: String
    let model: String
    let source: String
    let contextTokens: Int
    let quality: UsageQuality
}

// MARK: - Model

struct UsageData: Equatable {
    let date: Date
    let endDate: Date
    let inputTokens: Int
    let outputTokens: Int
    let cacheReadTokens: Int
    let cacheWriteTokens: Int
    let reasoningTokens: Int
    let cost: Double
    let activeSeconds: TimeInterval
    let workTime: WorkTimeMetrics

    let perModel: [ModelStat]
    let sourceStats: [SourceStat]
    let timeBuckets: [UsageTimeBucket]
    let projectStats: [ProjectUsageStat]
    let sessionStats: [SessionUsageStat]
    let supplementalStats: [SupplementalStat]
    let contextOnlyModels: [ContextOnlyModelStat]

    init(
        date: Date,
        endDate: Date? = nil,
        inputTokens: Int,
        outputTokens: Int,
        cacheReadTokens: Int,
        cacheWriteTokens: Int,
        reasoningTokens: Int,
        cost: Double,
        activeSeconds: TimeInterval,
        workTime: WorkTimeMetrics? = nil,
        perModel: [ModelStat],
        sourceStats: [SourceStat] = [],
        timeBuckets: [UsageTimeBucket] = [],
        projectStats: [ProjectUsageStat] = [],
        sessionStats: [SessionUsageStat] = [],
        supplementalStats: [SupplementalStat] = [],
        contextOnlyModels: [ContextOnlyModelStat] = []) {
        self.date = date
        self.endDate = endDate ?? date
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.cacheReadTokens = cacheReadTokens
        self.cacheWriteTokens = cacheWriteTokens
        self.reasoningTokens = reasoningTokens
        self.cost = cost
        self.activeSeconds = activeSeconds
        self.workTime = workTime ?? .fallback(activeSeconds: activeSeconds)
        self.perModel = perModel
        self.sourceStats = sourceStats
        self.timeBuckets = timeBuckets
        self.projectStats = projectStats
        self.sessionStats = sessionStats
        self.supplementalStats = supplementalStats
        self.contextOnlyModels = contextOnlyModels
    }

    var totalTokens: Int {
        inputTokens + outputTokens + cacheReadTokens + cacheWriteTokens + reasoningTokens
    }

    /// Aggregate output throughput for the selected local usage period.
    var periodOutputTokensPerSecond: Double {
        guard outputTokens > 0, workTime.wallClockSeconds > 0 else { return 0 }
        return Double(outputTokens) / workTime.wallClockSeconds
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

    var attributedCost: Double {
        projectStats
            .filter { $0.quality != .unknown }
            .reduce(0) { $0 + $1.cost }
    }

    var attributedSessionCount: Int {
        sessionStats.filter { $0.quality != .unknown }.count
    }

    var peakTokenBucket: UsageTimeBucket? {
        timeBuckets
            .filter { $0.totalTokens > 0 }
            .max { lhs, rhs in
                if lhs.totalTokens != rhs.totalTokens {
                    return lhs.totalTokens < rhs.totalTokens
                }
                return lhs.startDate > rhs.startDate
            }
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
