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

    func snapshot(
        from readerUsages: [AgentReaderUsage],
        configuration: AgentConfiguration,
        generatedAt: Date,
        coveredFrom: Date,
        coveredTo: Date) throws -> RemoteUsageSnapshot {
        try Task.checkCancellation()
        let identifierHasher = try identifierHasher(for: configuration)
        let tokenReplacementCoverages = try boundedReplacementCoverages(from: readerUsages)
        let device = deviceDescriptor(for: configuration)
        var encodedBytes = try initialEncodedByteCount(
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
                guard event.timestamp <= generatedAt else { continue }
                guard try !isReplaced(
                    event,
                    by: tokenReplacementCoverages,
                    comparisonCount: &replacementCoverageComparisonCount) else {
                    continue
                }
                if let tokenEvent = remoteTokenEvent(event) {
                    guard tokenEvents.count < limits.maximumTokenEventCount else {
                        throw AgentSnapshotBuilderError.snapshotLimitExceeded
                    }
                    try reserveSnapshotBytes(for: tokenEvent, used: &encodedBytes)
                    tokenEvents.append(tokenEvent)
                }
                if let costEvent = remoteCostEvent(event) {
                    guard costEvents.count < limits.maximumCostEventCount else {
                        throw AgentSnapshotBuilderError.snapshotLimitExceeded
                    }
                    try reserveSnapshotBytes(for: costEvent, used: &encodedBytes)
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
                guard event.timestamp <= generatedAt else { continue }
                guard activityEvents.count < limits.maximumActivityEventCount else {
                    throw AgentSnapshotBuilderError.snapshotLimitExceeded
                }
                let activityEvent = RemoteActivityEvent(
                    timestamp: event.timestamp,
                    source: readerUsage.name,
                    model: remoteModel(event.key),
                    streamID: identifierHasher.identifier(
                        for: "\(readerUsage.name)\u{0}\(event.streamID)"),
                    agentKind: event.agentKind == .subagent ? .subagent : .main)
                try reserveSnapshotBytes(for: activityEvent, used: &encodedBytes)
                activityEvents.append(activityEvent)
            }
        }

        return try validatedSnapshot(
            device: device,
            generatedAt: generatedAt,
            coveredFrom: coveredFrom,
            coveredTo: coveredTo,
            tokenEvents: tokenEvents,
            costEvents: costEvents,
            activityEvents: activityEvents)
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
    private func validatedSnapshot(
        device: RemoteDeviceDescriptor,
        generatedAt: Date,
        coveredFrom: Date,
        coveredTo: Date,
        tokenEvents: [RemoteTokenEvent],
        costEvents: [RemoteCostEvent],
        activityEvents: [RemoteActivityEvent]) throws -> RemoteUsageSnapshot {
        let snapshot = RemoteUsageSnapshot(
            device: device,
            generatedAt: generatedAt,
            coveredFrom: coveredFrom,
            coveredTo: coveredTo,
            tokenEvents: tokenEvents.sorted(by: tokenEventSort),
            costEvents: costEvents.isEmpty ? nil : costEvents.sorted(by: costEventSort),
            activityEvents: activityEvents.sorted(by: activityEventSort))
        guard try TokiSyncCoding.makeEncoder().encode(snapshot).count <= limits.maximumEncodedBytes else {
            throw AgentSnapshotBuilderError.snapshotLimitExceeded
        }
        return snapshot
    }

    private func initialEncodedByteCount(
        device: RemoteDeviceDescriptor,
        generatedAt: Date,
        coveredFrom: Date,
        coveredTo: Date) throws -> Int {
        let emptySnapshot = RemoteUsageSnapshot(
            device: device,
            generatedAt: generatedAt,
            coveredFrom: coveredFrom,
            coveredTo: coveredTo,
            tokenEvents: [],
            activityEvents: [])
        let count = try TokiSyncCoding.makeEncoder().encode(emptySnapshot).count
        guard count <= limits.maximumEncodedBytes else {
            throw AgentSnapshotBuilderError.snapshotLimitExceeded
        }
        return count
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

    private func reserveSnapshotBytes(
        for event: some Encodable,
        used: inout Int) throws {
        let eventBytes = try TokiSyncCoding.makeEncoder().encode(event).count
        let (reservedBytes, separatorOverflow) = eventBytes.addingReportingOverflow(1)
        let (next, totalOverflow) = used.addingReportingOverflow(reservedBytes)
        guard !separatorOverflow,
              !totalOverflow,
              next <= limits.maximumEncodedBytes else {
            throw AgentSnapshotBuilderError.snapshotLimitExceeded
        }
        used = next
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
        case true:
            event.cost
        case false:
            0
        case nil:
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
        case nil: 0
        case false: 1
        case true: 2
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
