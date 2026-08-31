import Foundation
import TokiSyncProtocol
import TokiUsageCore

enum PiCompatibleMergePolicy {
    case legacy
    case deterministic
}

struct PiCompatibleRevisionIdentity: Hashable {
    let timestamp: Date
    let payloadDigest: String

    func isPreferred(over other: Self) -> Bool {
        if timestamp != other.timestamp { return timestamp > other.timestamp }
        return payloadDigest < other.payloadDigest
    }
}

enum PiCompatibleMergeAlias: Hashable {
    case sessionMessage(sessionID: String, messageID: String)
    case sessionResponse(sessionID: String, responseID: String)
    case responseCopy(id: String, payloadDigest: String)
    case messageCopy(id: String, payloadDigest: String)
    case legacyResponseCopy(PiCompatibleLegacyResponseCopyIdentity)
}

struct PiCompatibleUsageRecord {
    let deduplicationKey: PiCompatibleDeduplicationKey
    let mergeAliases: Set<PiCompatibleMergeAlias>
    let mergePolicy: PiCompatibleMergePolicy
    let timestamp: Date
    let model: String
    let provider: String?
    let inputTokens: Int
    let outputTokens: Int
    let cacheReadTokens: Int
    let cacheWriteTokens: Int
    let reasoningTokens: Int
    let cost: Double
    let costIsKnown: Bool
    let attribution: UsageAttribution
    let agentKind: WorkTimeAgentKind
    private let revisionIdentity: PiCompatibleRevisionIdentity
    private let providerRevisionIdentity: PiCompatibleRevisionIdentity?
    private let costRevisionIdentity: PiCompatibleRevisionIdentity

    init(
        deduplicationKey: PiCompatibleDeduplicationKey,
        mergeAliases: Set<PiCompatibleMergeAlias> = [],
        mergePolicy: PiCompatibleMergePolicy = .deterministic,
        timestamp: Date,
        model: String,
        provider: String?,
        inputTokens: Int,
        outputTokens: Int,
        cacheReadTokens: Int,
        cacheWriteTokens: Int,
        reasoningTokens: Int,
        cost: Double,
        costIsKnown: Bool,
        attribution: UsageAttribution,
        agentKind: WorkTimeAgentKind,
        revisionIdentity: PiCompatibleRevisionIdentity? = nil) {
        let identity = revisionIdentity ?? PiCompatibleRevisionIdentity.derived(
            timestamp: timestamp,
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
        self.init(
            deduplicationKey: deduplicationKey,
            mergeAliases: mergeAliases,
            mergePolicy: mergePolicy,
            timestamp: timestamp,
            model: model,
            provider: provider,
            inputTokens: inputTokens,
            outputTokens: outputTokens,
            cacheReadTokens: cacheReadTokens,
            cacheWriteTokens: cacheWriteTokens,
            reasoningTokens: reasoningTokens,
            cost: cost,
            costIsKnown: costIsKnown,
            attribution: attribution,
            agentKind: agentKind,
            revisionIdentity: identity,
            providerRevisionIdentity: provider == nil ? nil : identity,
            costRevisionIdentity: identity)
    }

    private init(
        deduplicationKey: PiCompatibleDeduplicationKey,
        mergeAliases: Set<PiCompatibleMergeAlias>,
        mergePolicy: PiCompatibleMergePolicy,
        timestamp: Date,
        model: String,
        provider: String?,
        inputTokens: Int,
        outputTokens: Int,
        cacheReadTokens: Int,
        cacheWriteTokens: Int,
        reasoningTokens: Int,
        cost: Double,
        costIsKnown: Bool,
        attribution: UsageAttribution,
        agentKind: WorkTimeAgentKind,
        revisionIdentity: PiCompatibleRevisionIdentity,
        providerRevisionIdentity: PiCompatibleRevisionIdentity?,
        costRevisionIdentity: PiCompatibleRevisionIdentity) {
        self.deduplicationKey = deduplicationKey
        self.mergeAliases = mergeAliases
        self.mergePolicy = mergePolicy
        self.timestamp = timestamp
        self.model = model
        self.provider = provider
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.cacheReadTokens = cacheReadTokens
        self.cacheWriteTokens = cacheWriteTokens
        self.reasoningTokens = reasoningTokens
        self.cost = cost
        self.costIsKnown = costIsKnown
        self.attribution = attribution
        self.agentKind = agentKind
        self.revisionIdentity = revisionIdentity
        self.providerRevisionIdentity = providerRevisionIdentity
        self.costRevisionIdentity = costRevisionIdentity
    }

    var totalTokens: Int {
        inputTokens + outputTokens + cacheReadTokens + cacheWriteTokens + reasoningTokens
    }
}

extension PiCompatibleUsageRecord {
    func merged(with other: Self) -> Self {
        if mergePolicy == .legacy || other.mergePolicy == .legacy {
            return legacyMerged(with: other)
        }
        let selfIsPreferred = isCorePreferred(over: other)
        let preferred = selfIsPreferred ? self : other
        let selectedProvider = deterministicProvider(with: other)
        let selectedCost = deterministicCost(with: other)
        return PiCompatibleUsageRecord(
            deduplicationKey: deduplicationKey.isOrdered(before: other.deduplicationKey)
                ? deduplicationKey
                : other.deduplicationKey,
            mergeAliases: mergeAliases.union(other.mergeAliases),
            mergePolicy: .deterministic,
            timestamp: preferred.timestamp,
            model: preferred.model,
            provider: selectedProvider.value,
            inputTokens: preferred.inputTokens,
            outputTokens: preferred.outputTokens,
            cacheReadTokens: preferred.cacheReadTokens,
            cacheWriteTokens: preferred.cacheWriteTokens,
            reasoningTokens: preferred.reasoningTokens,
            cost: selectedCost.value,
            costIsKnown: selectedCost.isKnown,
            attribution: deterministicAttribution(attribution, other.attribution),
            agentKind: agentKind == .subagent || other.agentKind == .subagent ? .subagent : .main,
            revisionIdentity: preferred.revisionIdentity,
            providerRevisionIdentity: selectedProvider.identity,
            costRevisionIdentity: selectedCost.identity)
    }

    private func legacyMerged(with other: Self) -> Self {
        let selfIsPreferred = isLegacyPreferred(over: other)
        let preferred = selfIsPreferred ? self : other
        let fallback = selfIsPreferred ? other : self
        let providerRecord = preferred.provider == nil ? fallback : preferred
        return PiCompatibleUsageRecord(
            deduplicationKey: deduplicationKey,
            mergeAliases: mergeAliases.union(other.mergeAliases),
            mergePolicy: .legacy,
            timestamp: preferred.timestamp,
            model: preferred.model,
            provider: providerRecord.provider,
            inputTokens: preferred.inputTokens,
            outputTokens: preferred.outputTokens,
            cacheReadTokens: preferred.cacheReadTokens,
            cacheWriteTokens: preferred.cacheWriteTokens,
            reasoningTokens: preferred.reasoningTokens,
            cost: preferred.cost,
            costIsKnown: preferred.costIsKnown,
            attribution: bestUsageAttribution(attribution, other.attribution) ?? attribution,
            agentKind: agentKind == .subagent || other.agentKind == .subagent ? .subagent : .main,
            revisionIdentity: preferred.revisionIdentity,
            providerRevisionIdentity: providerRecord.providerRevisionIdentity,
            costRevisionIdentity: preferred.costRevisionIdentity)
    }

    private func isLegacyPreferred(over other: Self) -> Bool {
        if totalTokens != other.totalTokens { return totalTokens > other.totalTokens }
        if cost != other.cost { return cost > other.cost }
        if costIsKnown != other.costIsKnown { return costIsKnown }
        return true
    }

    private func deterministicProvider(with other: Self) -> PiCompatibleSelectedProvider {
        guard let provider else {
            return PiCompatibleSelectedProvider(
                value: other.provider,
                identity: other.providerRevisionIdentity)
        }
        guard let otherProvider = other.provider else {
            return PiCompatibleSelectedProvider(value: provider, identity: providerRevisionIdentity)
        }
        let identity = providerRevisionIdentity ?? revisionIdentity
        let otherIdentity = other.providerRevisionIdentity ?? other.revisionIdentity
        if identity != otherIdentity {
            return identity.isPreferred(over: otherIdentity)
                ? PiCompatibleSelectedProvider(value: provider, identity: identity)
                : PiCompatibleSelectedProvider(value: otherProvider, identity: otherIdentity)
        }
        return provider <= otherProvider
            ? PiCompatibleSelectedProvider(value: provider, identity: identity)
            : PiCompatibleSelectedProvider(value: otherProvider, identity: otherIdentity)
    }

    private func deterministicCost(with other: Self) -> PiCompatibleSelectedCost {
        if costIsKnown != other.costIsKnown {
            return costIsKnown
                ? selectedCost()
                : other.selectedCost()
        }
        if costRevisionIdentity != other.costRevisionIdentity {
            return costRevisionIdentity.isPreferred(over: other.costRevisionIdentity)
                ? selectedCost()
                : other.selectedCost()
        }
        return cost <= other.cost ? selectedCost() : other.selectedCost()
    }

    private func selectedCost() -> PiCompatibleSelectedCost {
        PiCompatibleSelectedCost(
            value: cost,
            isKnown: costIsKnown,
            identity: costRevisionIdentity)
    }

    private func isCorePreferred(over other: Self) -> Bool {
        if totalTokens != other.totalTokens {
            return totalTokens > other.totalTokens
        }
        let buckets = [inputTokens, outputTokens, cacheReadTokens, cacheWriteTokens, reasoningTokens]
        let otherBuckets = [
            other.inputTokens,
            other.outputTokens,
            other.cacheReadTokens,
            other.cacheWriteTokens,
            other.reasoningTokens,
        ]
        if buckets != otherBuckets {
            return otherBuckets.lexicographicallyPrecedes(buckets)
        }
        if timestamp != other.timestamp {
            return timestamp > other.timestamp
        }
        if model != other.model {
            return model < other.model
        }
        return revisionIdentity.isPreferred(over: other.revisionIdentity)
    }
}

enum PiCompatibleDeduplicationKey: Hashable {
    case message(String)
    case sessionMessage(sessionID: String, messageID: String)
    case sessionResponse(sessionID: String, responseID: String)
    case legacySessionResponse(sessionID: String, responseID: String, model: String)
    case legacyRecord(PiCompatibleLegacyRecordIdentity)
    case record(streamID: String, lineIndex: Int)

    func isOrdered(before other: Self) -> Bool {
        let lhsRank = caseRank
        let rhsRank = other.caseRank
        guard lhsRank == rhsRank else { return lhsRank < rhsRank }
        switch (self, other) {
        case let (.message(lhs), .message(rhs)):
            return lhs < rhs
        case let (.sessionMessage(lhsSession, lhsMessage), .sessionMessage(rhsSession, rhsMessage)):
            if lhsSession != rhsSession { return lhsSession < rhsSession }
            return lhsMessage < rhsMessage
        case let (
            .sessionResponse(lhsSession, lhsResponse),
            .sessionResponse(rhsSession, rhsResponse)):
            if lhsSession != rhsSession { return lhsSession < rhsSession }
            return lhsResponse < rhsResponse
        case let (
            .legacySessionResponse(lhsSession, lhsResponse, lhsModel),
            .legacySessionResponse(rhsSession, rhsResponse, rhsModel)):
            if lhsSession != rhsSession { return lhsSession < rhsSession }
            if lhsResponse != rhsResponse { return lhsResponse < rhsResponse }
            return lhsModel < rhsModel
        case let (.legacyRecord(lhs), .legacyRecord(rhs)):
            return lhs.location < rhs.location
        case let (.record(lhsStream, lhsLine), .record(rhsStream, rhsLine)):
            if lhsStream != rhsStream { return lhsStream < rhsStream }
            return lhsLine < rhsLine
        default:
            return false
        }
    }

    private var caseRank: Int {
        switch self {
        case .message: 0
        case .sessionMessage: 1
        case .sessionResponse: 2
        case .legacySessionResponse: 3
        case .legacyRecord: 4
        case .record: 5
        }
    }
}

struct PiCompatibleLegacyResponseCopyIdentity: Hashable {
    let responseID: String
    let timestamp: Date
    let model: String
    let inputTokens: Int
    let outputTokens: Int
    let cacheReadTokens: Int
    let cacheWriteTokens: Int
    let reasoningTokens: Int
}

struct PiCompatibleLegacyRecordIdentity: Hashable {
    let timestamp: Date
    let provider: String?
    let model: String
    let inputTokens: Int
    let outputTokens: Int
    let cacheReadTokens: Int
    let cacheWriteTokens: Int
    let reasoningTokens: Int
    let cost: Double
    let location: String
}

private struct PiCompatibleSelectedProvider {
    let value: String?
    let identity: PiCompatibleRevisionIdentity?
}

private struct PiCompatibleSelectedCost {
    let value: Double
    let isKnown: Bool
    let identity: PiCompatibleRevisionIdentity
}

private extension PiCompatibleRevisionIdentity {
    static func derived(
        timestamp: Date,
        model: String,
        provider: String?,
        inputTokens: Int,
        outputTokens: Int,
        cacheReadTokens: Int,
        cacheWriteTokens: Int,
        reasoningTokens: Int,
        cost: Double,
        costIsKnown: Bool,
        attribution: UsageAttribution) -> Self {
        let fields = [
            model,
            provider ?? "",
            String(inputTokens),
            String(outputTokens),
            String(cacheReadTokens),
            String(cacheWriteTokens),
            String(reasoningTokens),
            String(cost.bitPattern),
            String(costIsKnown),
            attribution.projectPath ?? "",
            attribution.projectName ?? "",
            attribution.sessionID ?? "",
            attribution.sessionLabel ?? "",
            attribution.quality.rawValue,
        ]
        return Self(
            timestamp: timestamp,
            payloadDigest: SnapshotCipher.digest(fields.joined(separator: "\u{0}")))
    }
}

private func deterministicAttribution(
    _ lhs: UsageAttribution,
    _ rhs: UsageAttribution) -> UsageAttribution {
    let lhsRank = attributionRank(lhs)
    let rhsRank = attributionRank(rhs)
    if lhsRank != rhsRank {
        return lhsRank > rhsRank ? lhs : rhs
    }
    let lhsValues = attributionValues(lhs)
    let rhsValues = attributionValues(rhs)
    return lhsValues.lexicographicallyPrecedes(rhsValues) ? lhs : rhs
}

private func attributionRank(_ attribution: UsageAttribution) -> Int {
    let qualityRank = switch attribution.quality {
    case .exact: 300
    case .inferred: 200
    case .unknown: 100
    }
    return qualityRank
        + (attribution.projectPath == nil ? 0 : 8)
        + (attribution.projectName == nil ? 0 : 4)
        + (attribution.sessionID == nil ? 0 : 2)
        + (attribution.sessionLabel == nil ? 0 : 1)
}

private func attributionValues(_ attribution: UsageAttribution) -> [String] {
    [
        attribution.projectPath ?? "",
        attribution.projectName ?? "",
        attribution.sessionID ?? "",
        attribution.sessionLabel ?? "",
        attribution.quality.rawValue,
    ]
}
