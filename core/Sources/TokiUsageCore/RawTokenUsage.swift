import Foundation

public enum SupplementalUnit: String {
    case tokens
    case count
    case cents
}

public enum UsageQuality: String {
    case exact
    case contextOnly
    case derived
}

public enum UsageModelGrouping {
    public static let mixedOrUnattributedKey = "\u{0}toki:mixed-or-unattributed"
    public static let mixedOrUnattributedLabel = "Mixed / Unattributed"

    /// Key that usage should be grouped under, folding a missing model name into the shared
    /// mixed/unattributed bucket.
    public static func groupingKey(for model: String?) -> String {
        model?.trimmedNonEmpty ?? mixedOrUnattributedKey
    }
}

public enum AttributionQuality: String, Codable {
    case exact
    case inferred
    case unknown
}

public struct UsageAttribution: Equatable, Codable {
    public let projectPath: String?
    public let projectName: String?
    public let sessionID: String?
    public let sessionLabel: String?
    public let quality: AttributionQuality

    public init(
        projectPath: String? = nil,
        projectName: String? = nil,
        sessionID: String? = nil,
        sessionLabel: String? = nil,
        quality: AttributionQuality = .unknown) {
        let normalizedPath = projectPath?.nilIfBlank
        let normalizedName = projectName?.nilIfBlank ?? usageProjectName(from: normalizedPath)
        self.projectPath = normalizedPath
        self.projectName = normalizedName
        self.sessionID = sessionID?.nilIfBlank
        self.sessionLabel = sessionLabel?.nilIfBlank
        self.quality = normalizedName == nil ? .unknown : quality
    }

    public var resolvedProjectName: String {
        projectName?.nilIfBlank ?? "Unknown Project"
    }
}

public struct SupplementalUsage {
    public let id: String
    public let label: String
    public let value: Int
    public let unit: SupplementalUnit
    public let source: String
    public let model: String?
    public let includedInTotals: Bool
    public let quality: UsageQuality

    public init(
        id: String,
        label: String,
        value: Int,
        unit: SupplementalUnit,
        source: String,
        model: String?,
        includedInTotals: Bool,
        quality: UsageQuality) {
        self.id = id
        self.label = label
        self.value = value
        self.unit = unit
        self.source = source
        self.model = model
        self.includedInTotals = includedInTotals
        self.quality = quality
    }
}

public struct PerModelUsage {
    public var totalTokens: Int
    public var cost: Double
    /// Agent work time. Concurrent streams are summed, so this can exceed the elapsed
    /// time when several sessions ran in parallel.
    public var activeSeconds: TimeInterval
    /// Elapsed time the model was in use, merging concurrent streams.
    public var wallClockSeconds: TimeInterval
    public var sources: Set<String>

    public init(
        totalTokens: Int = 0,
        cost: Double = 0,
        activeSeconds: TimeInterval = 0,
        wallClockSeconds: TimeInterval = 0,
        sources: Set<String> = []) {
        self.totalTokens = totalTokens
        self.cost = cost
        self.activeSeconds = activeSeconds
        self.wallClockSeconds = wallClockSeconds
        self.sources = sources
    }
}

public struct ModelSourceUsageKey: Hashable {
    public let modelID: String
    public let source: String

    public init(modelID: String, source: String) {
        self.modelID = modelID
        self.source = source
    }
}

public struct TokenUsageEvent: Equatable, Codable {
    public let timestamp: Date
    public let source: String
    public let model: String?
    public let provider: String?
    public let inputTokens: Int
    public let outputTokens: Int
    public let cacheReadTokens: Int
    public let cacheWriteTokens: Int
    public let reasoningTokens: Int
    public let cost: Double
    public let costIsKnown: Bool?
    public let attribution: UsageAttribution?

    public init(
        timestamp: Date,
        source: String,
        model: String?,
        provider: String? = nil,
        inputTokens: Int,
        outputTokens: Int,
        cacheReadTokens: Int,
        cacheWriteTokens: Int,
        reasoningTokens: Int,
        cost: Double,
        costIsKnown: Bool? = nil,
        attribution: UsageAttribution? = nil) {
        self.timestamp = timestamp
        self.source = source
        self.model = model
        self.provider = provider?.nilIfBlank
        let counts = Self.sanitizedTokenCounts(
            input: inputTokens,
            output: outputTokens,
            cacheRead: cacheReadTokens,
            cacheWrite: cacheWriteTokens,
            reasoning: reasoningTokens)
        self.inputTokens = counts.input
        self.outputTokens = counts.output
        self.cacheReadTokens = counts.cacheRead
        self.cacheWriteTokens = counts.cacheWrite
        self.reasoningTokens = counts.reasoning
        self.cost = cost
        self.costIsKnown = costIsKnown
        self.attribution = attribution
    }

    public var totalTokens: Int {
        saturatedTokenTotal(
            inputTokens,
            outputTokens,
            cacheReadTokens,
            cacheWriteTokens,
            reasoningTokens)
    }
}

public func checkedTokenTotal(_ counts: Int...) -> Int? {
    var total = 0
    for count in counts {
        guard count >= 0 else { return nil }
        let (next, overflow) = total.addingReportingOverflow(count)
        guard !overflow else { return nil }
        total = next
    }
    return total
}

private let maximumTokenCountPerUsageEvent = 1_000_000_000

private func checkedUsageEventTokenTotal(_ counts: Int...) -> Int? {
    guard counts.allSatisfy({ (0...maximumTokenCountPerUsageEvent).contains($0) }) else {
        return nil
    }
    return counts.reduce(0, +)
}

private func saturatedTokenTotal(_ counts: Int...) -> Int {
    var total = 0
    for count in counts {
        let (next, overflow) = total.addingReportingOverflow(max(0, count))
        if overflow { return Int.max }
        total = next
    }
    return total
}

private func saturatedTokenAddition(_ lhs: Int, _ rhs: Int) -> Int {
    let (sum, overflow) = lhs.addingReportingOverflow(rhs)
    guard overflow else { return sum }
    return lhs >= 0 && rhs >= 0 ? Int.max : Int.min
}

package struct TokenReplacementCoverage: Equatable {
    package let coveredFrom: Date
    package let coveredTo: Date
    package let sources: Set<String>

    package init(coveredFrom: Date, coveredTo: Date, sources: Set<String>) {
        self.coveredFrom = coveredFrom
        self.coveredTo = coveredTo
        self.sources = sources
    }

    package func replaces(_ event: TokenUsageEvent) -> Bool {
        sources.contains(event.source)
            && event.timestamp >= coveredFrom
            && event.timestamp < coveredTo
    }
}

public struct WorkTimeMetrics: Equatable {
    public var agentSeconds: TimeInterval
    public var mainAgentSeconds: TimeInterval
    public var subagentSeconds: TimeInterval
    public var wallClockSeconds: TimeInterval
    public var activeStreamCount: Int
    public var maxConcurrentStreams: Int

    public init(
        agentSeconds: TimeInterval = 0,
        wallClockSeconds: TimeInterval = 0,
        activeStreamCount: Int = 0,
        maxConcurrentStreams: Int = 0,
        mainAgentSeconds: TimeInterval? = nil,
        subagentSeconds: TimeInterval = 0) {
        self.agentSeconds = agentSeconds
        self.wallClockSeconds = wallClockSeconds
        self.activeStreamCount = activeStreamCount
        self.maxConcurrentStreams = maxConcurrentStreams
        self.subagentSeconds = max(0, subagentSeconds)
        self.mainAgentSeconds = max(0, mainAgentSeconds ?? (agentSeconds - self.subagentSeconds))
    }

    public static let zero = WorkTimeMetrics()

    public static func fallback(activeSeconds: TimeInterval) -> WorkTimeMetrics {
        let streamCount = activeSeconds > 0 ? 1 : 0
        return WorkTimeMetrics(
            agentSeconds: activeSeconds,
            wallClockSeconds: activeSeconds,
            activeStreamCount: streamCount,
            maxConcurrentStreams: streamCount,
            mainAgentSeconds: activeSeconds)
    }

    /// Merges metrics when their time windows cannot be aligned. This sums
    /// duration and stream counts, but keeps peak concurrency to observed peaks.
    /// If the inputs really overlap, wallClockSeconds is overestimated and
    /// parallelMultiplier moves closer to 1.
    public func mergedConservatively(with other: WorkTimeMetrics) -> WorkTimeMetrics {
        if !hasActivity { return other }
        if !other.hasActivity { return self }
        return WorkTimeMetrics(
            agentSeconds: agentSeconds + other.agentSeconds,
            wallClockSeconds: wallClockSeconds + other.wallClockSeconds,
            activeStreamCount: activeStreamCount + other.activeStreamCount,
            maxConcurrentStreams: max(maxConcurrentStreams, other.maxConcurrentStreams),
            mainAgentSeconds: mainAgentSeconds + other.mainAgentSeconds,
            subagentSeconds: subagentSeconds + other.subagentSeconds)
    }

    public var parallelMultiplier: Double {
        guard wallClockSeconds > 0 else { return 0 }
        return agentSeconds / wallClockSeconds
    }

    public var hasActivity: Bool {
        agentSeconds > 0
            || mainAgentSeconds > 0
            || subagentSeconds > 0
            || wallClockSeconds > 0
            || activeStreamCount > 0
            || maxConcurrentStreams > 0
    }
}

public struct RawTokenUsage {
    public var inputTokens: Int
    public var outputTokens: Int
    public var cacheReadTokens: Int
    public var cacheWriteTokens: Int
    public var reasoningTokens: Int
    /// Model-attributed tokens whose input/output/cache category is unavailable.
    public var unclassifiedTokens: Int
    public var cost: Double
    public var activeSeconds: TimeInterval
    public var workTime: WorkTimeMetrics
    public var perModel: [String: PerModelUsage]
    public var perModelBySource: [ModelSourceUsageKey: PerModelUsage]
    public var activityEvents: [ActivityTimeEvent<String>]
    public var tokenEvents: [TokenUsageEvent]
    package var tokenReplacementCoverages: [TokenReplacementCoverage]
    public var fallbackActiveSeconds: TimeInterval
    public var fallbackActiveSecondsByModel: [String: TimeInterval]
    public var fallbackWorkTime: WorkTimeMetrics
    public var supplemental: [SupplementalUsage]

    public init(
        inputTokens: Int = 0,
        outputTokens: Int = 0,
        cacheReadTokens: Int = 0,
        cacheWriteTokens: Int = 0,
        reasoningTokens: Int = 0,
        unclassifiedTokens: Int = 0,
        cost: Double = 0,
        activeSeconds: TimeInterval = 0,
        workTime: WorkTimeMetrics = .zero,
        perModel: [String: PerModelUsage] = [:],
        perModelBySource: [ModelSourceUsageKey: PerModelUsage] = [:],
        activityEvents: [ActivityTimeEvent<String>] = [],
        tokenEvents: [TokenUsageEvent] = [],
        fallbackActiveSeconds: TimeInterval = 0,
        fallbackActiveSecondsByModel: [String: TimeInterval] = [:],
        fallbackWorkTime: WorkTimeMetrics = .zero,
        supplemental: [SupplementalUsage] = []) {
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.cacheReadTokens = cacheReadTokens
        self.cacheWriteTokens = cacheWriteTokens
        self.reasoningTokens = reasoningTokens
        self.unclassifiedTokens = unclassifiedTokens
        self.cost = cost
        self.activeSeconds = activeSeconds
        self.workTime = workTime
        self.perModel = perModel
        self.perModelBySource = perModelBySource
        self.activityEvents = activityEvents
        self.tokenEvents = tokenEvents
        tokenReplacementCoverages = []
        self.fallbackActiveSeconds = fallbackActiveSeconds
        self.fallbackActiveSecondsByModel = fallbackActiveSecondsByModel
        self.fallbackWorkTime = fallbackWorkTime
        self.supplemental = supplemental
    }

    public var totalTokens: Int {
        saturatedTokenTotal(
            inputTokens,
            outputTokens,
            cacheReadTokens,
            cacheWriteTokens,
            reasoningTokens,
            unclassifiedTokens)
    }

    public var resolvedWorkTime: WorkTimeMetrics {
        if workTime.hasActivity { return workTime }
        return .fallback(activeSeconds: activeSeconds)
    }

    public var resolvedFallbackWorkTime: WorkTimeMetrics {
        if fallbackWorkTime.hasActivity { return fallbackWorkTime }
        if fallbackActiveSeconds > 0 { return .fallback(activeSeconds: fallbackActiveSeconds) }
        if activityEvents.isEmpty { return resolvedWorkTime }
        return .zero
    }

    public var hasReportableData: Bool {
        totalTokens > 0
            || cost > 0
            || activeSeconds > 0
            || workTime.hasActivity
            || fallbackWorkTime.hasActivity
            || fallbackActiveSeconds > 0
            || !perModel.isEmpty
            || !perModelBySource.isEmpty
            || !tokenEvents.isEmpty
            || !supplemental.isEmpty
    }

    public mutating func recordTokenEvent(
        timestamp: Date,
        source: String,
        model: String?,
        provider: String? = nil,
        inputTokens: Int,
        outputTokens: Int,
        cacheReadTokens: Int = 0,
        cacheWriteTokens: Int = 0,
        reasoningTokens: Int = 0,
        cost: Double = 0,
        costIsKnown: Bool? = nil,
        attribution: UsageAttribution? = nil) {
        guard let totalTokens = checkedUsageEventTokenTotal(
            inputTokens,
            outputTokens,
            cacheReadTokens,
            cacheWriteTokens,
            reasoningTokens) else {
            return
        }
        let event = TokenUsageEvent(
            timestamp: timestamp,
            source: source,
            model: model,
            provider: provider,
            inputTokens: inputTokens,
            outputTokens: outputTokens,
            cacheReadTokens: cacheReadTokens,
            cacheWriteTokens: cacheWriteTokens,
            reasoningTokens: reasoningTokens,
            cost: cost,
            costIsKnown: costIsKnown,
            attribution: attribution)
        guard totalTokens > 0 || event.cost > 0 else { return }
        tokenEvents.append(event)
    }

    @discardableResult
    public mutating func accumulateTokenCounts(
        input: Int,
        output: Int,
        cacheRead: Int = 0,
        cacheWrite: Int = 0,
        reasoning: Int = 0) -> Int? {
        guard let total = checkedUsageEventTokenTotal(
            input,
            output,
            cacheRead,
            cacheWrite,
            reasoning) else {
            return nil
        }
        inputTokens = saturatedTokenAddition(inputTokens, input)
        outputTokens = saturatedTokenAddition(outputTokens, output)
        cacheReadTokens = saturatedTokenAddition(cacheReadTokens, cacheRead)
        cacheWriteTokens = saturatedTokenAddition(cacheWriteTokens, cacheWrite)
        reasoningTokens = saturatedTokenAddition(reasoningTokens, reasoning)
        return total
    }

    /// Records a per-model row, folding usage with no model name into the shared
    /// mixed/unattributed key.
    ///
    /// Every source needs a per-model row. Report building trusts authoritative per-model rows
    /// over token events whose source labels disagree, so a source that contributes only events
    /// disappears from the model breakdown as soon as another source reports the same key.
    ///
    /// Pair this with `UsageModelGrouping.groupingKey(for:)` on the matching activity events:
    /// a row without active time replaces the event-derived estimate and would otherwise report
    /// zero elapsed time for the source.
    public mutating func accumulatePerModelUsage(
        model: String?,
        source: String,
        totalTokens: Int,
        cost: Double = 0) {
        let key = UsageModelGrouping.groupingKey(for: model)
        perModel[key, default: PerModelUsage()].totalTokens = saturatedTokenAddition(
            perModel[key, default: PerModelUsage()].totalTokens,
            totalTokens)
        perModel[key, default: PerModelUsage()].cost += cost
        perModel[key, default: PerModelUsage()].sources.insert(source)
    }
}

public func usageSessionID(fromPath path: String) -> String {
    URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent
}

public func bestUsageAttribution(_ lhs: UsageAttribution?, _ rhs: UsageAttribution?) -> UsageAttribution? {
    guard let lhs else { return rhs }
    guard let rhs else { return lhs }
    return usageAttributionRank(rhs) > usageAttributionRank(lhs) ? rhs : lhs
}

private func usageAttributionRank(_ attribution: UsageAttribution) -> Int {
    let qualityScore = switch attribution.quality {
    case .exact:
        300
    case .inferred:
        200
    case .unknown:
        100
    }
    let pathScore = attribution.projectPath == nil ? 0 : 20
    let sessionScore = attribution.sessionID == nil ? 0 : 1
    return qualityScore + pathScore + sessionScore
}

private func usageProjectName(from path: String?) -> String? {
    guard let path = path?.nilIfBlank else { return nil }
    return URL(fileURLWithPath: path).lastPathComponent.nilIfBlank
}

private extension String {
    var nilIfBlank: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

public func += (lhs: inout RawTokenUsage, rhs: RawTokenUsage) {
    let lhsWorkTime = lhs.resolvedWorkTime
    let rhsWorkTime = rhs.resolvedWorkTime
    let lhsFallbackWorkTime = lhs.resolvedFallbackWorkTime
    let rhsFallbackWorkTime = rhs.resolvedFallbackWorkTime

    lhs.inputTokens = saturatedTokenAddition(lhs.inputTokens, rhs.inputTokens)
    lhs.outputTokens = saturatedTokenAddition(lhs.outputTokens, rhs.outputTokens)
    lhs.cacheReadTokens = saturatedTokenAddition(lhs.cacheReadTokens, rhs.cacheReadTokens)
    lhs.cacheWriteTokens = saturatedTokenAddition(lhs.cacheWriteTokens, rhs.cacheWriteTokens)
    lhs.reasoningTokens = saturatedTokenAddition(lhs.reasoningTokens, rhs.reasoningTokens)
    lhs.unclassifiedTokens = saturatedTokenAddition(lhs.unclassifiedTokens, rhs.unclassifiedTokens)
    lhs.cost += rhs.cost
    lhs.activeSeconds += rhs.activeSeconds
    lhs.activityEvents.append(contentsOf: rhs.activityEvents)
    lhs.tokenEvents.append(contentsOf: rhs.tokenEvents)
    lhs.tokenReplacementCoverages.append(contentsOf: rhs.tokenReplacementCoverages)
    lhs.fallbackActiveSeconds += rhs.fallbackActiveSeconds

    if rhs.activityEvents.isEmpty, rhs.activeSeconds > 0 {
        lhs.fallbackActiveSeconds += rhs.activeSeconds
    }

    // Wall-clock time is summed here only so readers that never expose activity events
    // still report something. When events exist, recomputeMergedActiveEstimate()
    // replaces both values with one merged estimate over every event.
    for (id, usage) in rhs.perModel {
        lhs.perModel[id, default: PerModelUsage()].totalTokens = saturatedTokenAddition(
            lhs.perModel[id, default: PerModelUsage()].totalTokens,
            usage.totalTokens)
        lhs.perModel[id, default: PerModelUsage()].cost += usage.cost
        lhs.perModel[id, default: PerModelUsage()].activeSeconds += usage.activeSeconds
        lhs.perModel[id, default: PerModelUsage()].wallClockSeconds += usage.wallClockSeconds
        lhs.perModel[id, default: PerModelUsage()].sources.formUnion(usage.sources)
    }

    for (key, usage) in rhs.perModelBySource {
        lhs.perModelBySource[key, default: PerModelUsage()].totalTokens = saturatedTokenAddition(
            lhs.perModelBySource[key, default: PerModelUsage()].totalTokens,
            usage.totalTokens)
        lhs.perModelBySource[key, default: PerModelUsage()].cost += usage.cost
        lhs.perModelBySource[key, default: PerModelUsage()].activeSeconds += usage.activeSeconds
        lhs.perModelBySource[key, default: PerModelUsage()].wallClockSeconds += usage.wallClockSeconds
        lhs.perModelBySource[key, default: PerModelUsage()].sources.formUnion(usage.sources)
    }

    for (id, seconds) in rhs.fallbackActiveSecondsByModel {
        lhs.fallbackActiveSecondsByModel[id, default: 0] += seconds
    }

    lhs.supplemental.append(contentsOf: rhs.supplemental)

    if rhs.activityEvents.isEmpty {
        for (id, usage) in rhs.perModel where usage.activeSeconds > 0 {
            lhs.fallbackActiveSecondsByModel[id, default: 0] += usage.activeSeconds
        }
    }

    lhs.fallbackWorkTime = lhsFallbackWorkTime.mergedConservatively(with: rhsFallbackWorkTime)
    lhs.workTime = lhsWorkTime.mergedConservatively(with: rhsWorkTime)
}
