import Foundation
import TokiSyncProtocol
import TokiUsageCore

struct AgentSnapshotBuildLimits: Equatable {
    static let `default` = AgentSnapshotBuildLimits(
        maximumTokenEventCount: RemoteUsageSnapshotValidator.maximumTokenEventCount,
        maximumCostEventCount: RemoteUsageSnapshotValidator.maximumCostEventCount,
        maximumActivityEventCount: RemoteUsageSnapshotValidator.maximumActivityEventCount,
        maximumEncodedBytes: TokiSyncLimits.maximumEnvelopeBytes * 4)

    let maximumTokenEventCount: Int
    let maximumCostEventCount: Int
    let maximumActivityEventCount: Int
    let maximumEncodedBytes: Int
    let maximumExaminedTokenEventCount: Int
    let maximumExaminedActivityEventCount: Int
    let maximumReplacementCoverageCount: Int
    let maximumCoverageComparisonCount: Int

    init(
        maximumTokenEventCount: Int,
        maximumCostEventCount: Int,
        maximumActivityEventCount: Int,
        maximumEncodedBytes: Int,
        maximumExaminedTokenEventCount: Int? = nil,
        maximumExaminedActivityEventCount: Int? = nil,
        maximumReplacementCoverageCount: Int? = nil,
        maximumCoverageComparisonCount: Int? = nil) {
        let examinedTokenEventCount = maximumExaminedTokenEventCount
            ?? Self.saturatingSum(maximumTokenEventCount, maximumCostEventCount)
        self.maximumTokenEventCount = maximumTokenEventCount
        self.maximumCostEventCount = maximumCostEventCount
        self.maximumActivityEventCount = maximumActivityEventCount
        self.maximumEncodedBytes = maximumEncodedBytes
        self.maximumExaminedTokenEventCount = examinedTokenEventCount
        self.maximumExaminedActivityEventCount = maximumExaminedActivityEventCount
            ?? maximumActivityEventCount
        self.maximumReplacementCoverageCount = maximumReplacementCoverageCount
            ?? maximumTokenEventCount
        self.maximumCoverageComparisonCount =
            maximumCoverageComparisonCount
                ?? Self.saturatingProduct(examinedTokenEventCount, 8)
    }

    private static func saturatingSum(_ lhs: Int, _ rhs: Int) -> Int {
        let (sum, overflow) = lhs.addingReportingOverflow(rhs)
        return overflow ? Int.max : sum
    }

    private static func saturatingProduct(_ lhs: Int, _ rhs: Int) -> Int {
        let (product, overflow) = lhs.multipliedReportingOverflow(by: rhs)
        return overflow ? Int.max : product
    }
}

struct AgentSnapshotAssembler {
    let limits: AgentSnapshotBuildLimits

    struct Result {
        let snapshot: RemoteUsageSnapshot
        let earliestDeferredTimestamp: Date?
    }

    func snapshot(
        from readerUsages: [AgentReaderUsage],
        configuration: AgentConfiguration,
        generatedAt: Date,
        coveredFrom: Date,
        coveredTo: Date) throws -> Result {
        try Task.checkCancellation()
        let identifierHasher = try identifierHasher(for: configuration)
        let tokenReplacementCoverages = try boundedReplacementCoverages(from: readerUsages)
        let device = deviceDescriptor(for: configuration)
        try validateEmptySnapshotFits(
            device: device,
            generatedAt: generatedAt,
            coveredFrom: coveredFrom,
            coveredTo: coveredTo)

        var tokenEvents: [RemoteTokenEvent] = []
        var costEvents: [RemoteCostEvent] = []
        var activityEvents: [RemoteActivityEvent] = []
        var examinedTokenEventCount = 0
        var examinedActivityEventCount = 0
        var replacementCoverageComparisonCount = 0
        var earliestDeferredTimestamp: Date?
        for readerUsage in readerUsages {
            try Task.checkCancellation()
            for event in readerUsage.usage.tokenEvents {
                try Task.checkCancellation()
                try consumeBudget(
                    &examinedTokenEventCount,
                    maximum: limits.maximumExaminedTokenEventCount)
                guard event.timestamp >= coveredFrom, event.timestamp < coveredTo else {
                    continue
                }
                guard event.timestamp <= generatedAt else {
                    updateEarliestDeferredTimestamp(&earliestDeferredTimestamp, candidate: event.timestamp)
                    continue
                }
                guard try !isReplaced(
                    event,
                    by: tokenReplacementCoverages,
                    comparisonCount: &replacementCoverageComparisonCount) else {
                    continue
                }
                if let tokenEvent = remoteTokenEvent(event) {
                    tokenEvents.append(tokenEvent)
                }
                if let costEvent = remoteCostEvent(event) {
                    costEvents.append(costEvent)
                }
            }
            for event in readerUsage.usage.activityEvents {
                try Task.checkCancellation()
                try consumeBudget(
                    &examinedActivityEventCount,
                    maximum: limits.maximumExaminedActivityEventCount)
                guard event.timestamp >= coveredFrom, event.timestamp < coveredTo else {
                    continue
                }
                guard event.timestamp <= generatedAt else {
                    updateEarliestDeferredTimestamp(&earliestDeferredTimestamp, candidate: event.timestamp)
                    continue
                }
                let activityEvent = RemoteActivityEvent(
                    timestamp: event.timestamp,
                    source: readerUsage.name,
                    model: remoteModel(event.key),
                    streamID: identifierHasher.identifier(
                        for: "\(readerUsage.name)\u{0}\(event.streamID)"),
                    agentKind: event.agentKind == .subagent ? .subagent : .main)
                activityEvents.append(activityEvent)
            }
        }

        let snapshot = try boundedSnapshot(
            device: device,
            generatedAt: generatedAt,
            coveredFrom: coveredFrom,
            coveredTo: coveredTo,
            tokenEvents: tokenEvents,
            costEvents: costEvents,
            activityEvents: activityEvents)
        return Result(
            snapshot: snapshot,
            earliestDeferredTimestamp: earliestDeferredTimestamp)
    }

    private func identifierHasher(
        for configuration: AgentConfiguration) throws -> SnapshotOpaqueIdentifierHasher {
        try SnapshotCipher.makeOpaqueIdentifierHasher(key: configuration.encryptionKey)
    }

    private func deviceDescriptor(for configuration: AgentConfiguration) -> RemoteDeviceDescriptor {
        RemoteDeviceDescriptor(
            id: configuration.deviceID,
            name: configuration.deviceName,
            platform: platformName)
    }
}

private extension AgentSnapshotAssembler {
    private func boundedSnapshot(
        device: RemoteDeviceDescriptor,
        generatedAt: Date,
        coveredFrom: Date,
        coveredTo: Date,
        tokenEvents: [RemoteTokenEvent],
        costEvents: [RemoteCostEvent],
        activityEvents: [RemoteActivityEvent]) throws -> RemoteUsageSnapshot {
        let sortedTokenEvents = tokenEvents.sorted(by: tokenEventSort)
        let sortedCostEvents = costEvents.sorted(by: costEventSort)
        let sortedActivityEvents = activityEvents.sorted(by: activityEventSort)
        let cutoffs = cutoffCandidates(
            coveredFrom: coveredFrom,
            generatedAt: generatedAt,
            tokenEvents: sortedTokenEvents,
            costEvents: sortedCostEvents,
            activityEvents: sortedActivityEvents)
        let fullSnapshot = makeSnapshot(
            device: device,
            generatedAt: generatedAt,
            coveredFrom: cutoffs[0],
            coveredTo: coveredTo,
            tokenEvents: sortedTokenEvents,
            costEvents: sortedCostEvents,
            activityEvents: sortedActivityEvents)
        if try fitsAssemblyLimits(fullSnapshot) {
            return fullSnapshot
        }

        var lowerBound = 1
        var upperBound = cutoffs.count - 1
        var boundedSnapshot: RemoteUsageSnapshot?
        while lowerBound <= upperBound {
            try Task.checkCancellation()
            let index = lowerBound + (upperBound - lowerBound) / 2
            let candidate = makeSnapshot(
                device: device,
                generatedAt: generatedAt,
                coveredFrom: cutoffs[index],
                coveredTo: coveredTo,
                tokenEvents: sortedTokenEvents,
                costEvents: sortedCostEvents,
                activityEvents: sortedActivityEvents)
            if try fitsAssemblyLimits(candidate) {
                boundedSnapshot = candidate
                upperBound = index - 1
            } else {
                lowerBound = index + 1
            }
        }
        guard let boundedSnapshot else {
            throw AgentSnapshotBuilderError.snapshotLimitExceeded
        }
        return boundedSnapshot
    }

    private func makeSnapshot(
        device: RemoteDeviceDescriptor,
        generatedAt: Date,
        coveredFrom: Date,
        coveredTo: Date,
        tokenEvents: [RemoteTokenEvent],
        costEvents: [RemoteCostEvent],
        activityEvents: [RemoteActivityEvent]) -> RemoteUsageSnapshot {
        let boundedCosts = costEvents.filter { $0.timestamp >= coveredFrom }
        return RemoteUsageSnapshot(
            device: device,
            generatedAt: generatedAt,
            coveredFrom: coveredFrom,
            coveredTo: coveredTo,
            tokenEvents: tokenEvents.filter { $0.timestamp >= coveredFrom },
            costEvents: boundedCosts.isEmpty ? nil : boundedCosts,
            activityEvents: activityEvents.filter { $0.timestamp >= coveredFrom })
    }

    private func validateEmptySnapshotFits(
        device: RemoteDeviceDescriptor,
        generatedAt: Date,
        coveredFrom: Date,
        coveredTo: Date) throws {
        let emptySnapshot = RemoteUsageSnapshot(
            device: device,
            generatedAt: generatedAt,
            coveredFrom: coveredFrom,
            coveredTo: coveredTo,
            tokenEvents: [],
            activityEvents: [])
        guard try fitsAssemblyLimits(emptySnapshot) else {
            throw AgentSnapshotBuilderError.snapshotLimitExceeded
        }
    }

    private func fitsAssemblyLimits(_ snapshot: RemoteUsageSnapshot) throws -> Bool {
        guard snapshot.tokenEvents.count <= max(0, limits.maximumTokenEventCount),
              (snapshot.costEvents?.count ?? 0) <= max(0, limits.maximumCostEventCount),
              snapshot.activityEvents.count <= max(0, limits.maximumActivityEventCount) else {
            return false
        }
        return try TokiSyncCoding.makeEncoder().encode(snapshot).count <= max(0, limits.maximumEncodedBytes)
    }

    private func cutoffCandidates(
        coveredFrom: Date,
        generatedAt: Date,
        tokenEvents: [RemoteTokenEvent],
        costEvents: [RemoteCostEvent],
        activityEvents: [RemoteActivityEvent]) -> [Date] {
        var candidates = [coveredFrom, generatedAt]
        func appendCutoffs(for timestamp: Date) {
            candidates.append(timestamp)
            let afterTimestamp = timestamp.addingTimeInterval(0.001)
            if afterTimestamp <= generatedAt {
                candidates.append(afterTimestamp)
            }
        }
        tokenEvents.forEach { appendCutoffs(for: $0.timestamp) }
        costEvents.forEach { appendCutoffs(for: $0.timestamp) }
        activityEvents.forEach { appendCutoffs(for: $0.timestamp) }
        candidates.sort()
        return candidates.reduce(into: []) { unique, candidate in
            if unique.last != candidate {
                unique.append(candidate)
            }
        }
    }

    private func boundedReplacementCoverages(
        from readerUsages: [AgentReaderUsage]) throws -> [TokenReplacementCoverage] {
        var coverages: [TokenReplacementCoverage] = []
        for readerUsage in readerUsages {
            for coverage in readerUsage.usage.tokenReplacementCoverages {
                try Task.checkCancellation()
                guard coverages.count < limits.maximumReplacementCoverageCount else {
                    throw AgentSnapshotBuilderError.snapshotLimitExceeded
                }
                coverages.append(coverage)
            }
        }
        return coverages
    }

    private func consumeBudget(_ count: inout Int, maximum: Int) throws {
        let (next, overflow) = count.addingReportingOverflow(1)
        guard !overflow, next <= maximum else {
            throw AgentSnapshotBuilderError.snapshotLimitExceeded
        }
        count = next
    }

    private func isReplaced(
        _ event: TokenUsageEvent,
        by coverages: [TokenReplacementCoverage],
        comparisonCount: inout Int) throws -> Bool {
        for coverage in coverages {
            try Task.checkCancellation()
            try consumeBudget(
                &comparisonCount,
                maximum: limits.maximumCoverageComparisonCount)
            if coverage.replaces(event) { return true }
        }
        return false
    }

    private func updateEarliestDeferredTimestamp(_ earliest: inout Date?, candidate: Date) {
        if earliest.map({ candidate < $0 }) ?? true {
            earliest = candidate
        }
    }

    private func tokenEventSort(_ lhs: RemoteTokenEvent, _ rhs: RemoteTokenEvent) -> Bool {
        if lhs.timestamp != rhs.timestamp { return lhs.timestamp < rhs.timestamp }
        if lhs.source != rhs.source { return lhs.source < rhs.source }
        if lhs.model != rhs.model { return (lhs.model ?? "") < (rhs.model ?? "") }
        if lhs.provider != rhs.provider { return (lhs.provider ?? "") < (rhs.provider ?? "") }
        if lhs.inputTokens != rhs.inputTokens { return lhs.inputTokens < rhs.inputTokens }
        if lhs.outputTokens != rhs.outputTokens { return lhs.outputTokens < rhs.outputTokens }
        if lhs.cacheReadTokens != rhs.cacheReadTokens { return lhs.cacheReadTokens < rhs.cacheReadTokens }
        if lhs.cacheWriteTokens != rhs.cacheWriteTokens { return lhs.cacheWriteTokens < rhs.cacheWriteTokens }
        if lhs.reasoningTokens != rhs.reasoningTokens { return lhs.reasoningTokens < rhs.reasoningTokens }
        if lhs.cost != rhs.cost { return (lhs.cost ?? -1) < (rhs.cost ?? -1) }
        return costKnownSortRank(lhs.costIsKnown) < costKnownSortRank(rhs.costIsKnown)
    }

    private func costEventSort(_ lhs: RemoteCostEvent, _ rhs: RemoteCostEvent) -> Bool {
        if lhs.timestamp != rhs.timestamp { return lhs.timestamp < rhs.timestamp }
        if lhs.source != rhs.source { return lhs.source < rhs.source }
        if lhs.model != rhs.model { return (lhs.model ?? "") < (rhs.model ?? "") }
        return lhs.cost < rhs.cost
    }

    private func activityEventSort(_ lhs: RemoteActivityEvent, _ rhs: RemoteActivityEvent) -> Bool {
        if lhs.timestamp != rhs.timestamp { return lhs.timestamp < rhs.timestamp }
        if lhs.source != rhs.source { return lhs.source < rhs.source }
        if lhs.model != rhs.model { return (lhs.model ?? "") < (rhs.model ?? "") }
        if lhs.streamID != rhs.streamID { return lhs.streamID < rhs.streamID }
        return lhs.agentKind.rawValue < rhs.agentKind.rawValue
    }

    private func remoteModel(_ model: String?) -> String? {
        guard let model,
              model != UsageModelGrouping.mixedOrUnattributedKey,
              TokiSyncValidation.isSafeDisplayText(
                  model,
                  maximumLength: RemoteUsageSnapshotValidator.maximumModelLength) else {
            return nil
        }
        return model
    }

    private func remoteTokenEvent(_ event: TokenUsageEvent) -> RemoteTokenEvent? {
        let counts = [
            event.inputTokens,
            event.outputTokens,
            event.cacheReadTokens,
            event.cacheWriteTokens,
            event.reasoningTokens,
        ]
        let validRange = 0...RemoteUsageSnapshotValidator.maximumTokenCountPerBucket
        let validCostRange = 0...RemoteUsageSnapshotValidator.maximumCostPerEvent
        guard counts.allSatisfy(validRange.contains),
              event.cost.isFinite,
              validCostRange.contains(event.cost),
              counts.contains(where: { $0 > 0 }) else {
            return nil
        }
        let reportedCost: Double? = switch event.costIsKnown {
        case .some(true):
            event.cost
        case .some(false):
            0
        case .none:
            event.cost > 0 ? event.cost : nil
        }
        return RemoteTokenEvent(
            timestamp: event.timestamp,
            source: event.source,
            model: remoteModel(event.model),
            provider: remoteProvider(event.provider),
            inputTokens: event.inputTokens,
            outputTokens: event.outputTokens,
            cacheReadTokens: event.cacheReadTokens,
            cacheWriteTokens: event.cacheWriteTokens,
            reasoningTokens: event.reasoningTokens,
            cost: reportedCost,
            costIsKnown: event.costIsKnown)
    }

    private func remoteProvider(_ provider: String?) -> String? {
        let normalized = provider?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return normalized.flatMap { Self.remoteProviderIdentifiers.contains($0) ? $0 : nil }
    }

    private static let remoteProviderIdentifiers = Set([
        "anthropic", "aws-bedrock", "azure", "bedrock", "cerebras",
        "deepseek", "fireworks", "github", "google", "groq", "kimchi-dev",
        "mistral", "moonshot", "ollama", "openai", "openrouter",
        "qwen", "together", "vertex-ai", "xai", "zai",
    ])

    private func remoteCostEvent(_ event: TokenUsageEvent) -> RemoteCostEvent? {
        let counts = [
            event.inputTokens,
            event.outputTokens,
            event.cacheReadTokens,
            event.cacheWriteTokens,
            event.reasoningTokens,
        ]
        let validCostRange = 0...RemoteUsageSnapshotValidator.maximumCostPerEvent
        guard counts.allSatisfy({ $0 == 0 }),
              event.costIsKnown != false,
              event.cost.isFinite,
              event.cost > 0,
              validCostRange.contains(event.cost) else {
            return nil
        }
        return RemoteCostEvent(
            timestamp: event.timestamp,
            source: event.source,
            model: remoteModel(event.model),
            cost: event.cost)
    }

    private func costKnownSortRank(_ value: Bool?) -> Int {
        switch value {
        case .none: 0
        case .some(false): 1
        case .some(true): 2
        }
    }

    private var platformName: String {
        #if os(Linux)
            "linux"
        #elseif os(macOS)
            "macos"
        #else
            "unknown"
        #endif
    }
}
