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
    case sessionResponse(sessionID: String, responseID: String, usageIdentity: String)
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
    let providerIsExplicit: Bool
    let inputTokens: Int
    let outputTokens: Int
    let cacheReadTokens: Int
    let cacheWriteTokens: Int
    let reasoningTokens: Int
    let cost: Double
    let costIsKnown: Bool?
    let attribution: UsageAttribution
    let agentName: String?
    let agentKind: WorkTimeAgentKind
    let replicaScope: String?
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
        providerIsExplicit: Bool? = nil,
        inputTokens: Int,
        outputTokens: Int,
        cacheReadTokens: Int,
        cacheWriteTokens: Int,
        reasoningTokens: Int,
        cost: Double,
        costIsKnown: Bool?,
        attribution: UsageAttribution,
        agentName: String? = nil,
        agentKind: WorkTimeAgentKind,
        replicaScope: String? = nil,
        revisionIdentity: PiCompatibleRevisionIdentity? = nil) {
        let explicitProvider = providerIsExplicit ?? (provider != nil)
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
            providerIsExplicit: explicitProvider,
            inputTokens: inputTokens,
            outputTokens: outputTokens,
            cacheReadTokens: cacheReadTokens,
            cacheWriteTokens: cacheWriteTokens,
            reasoningTokens: reasoningTokens,
            cost: cost,
            costIsKnown: costIsKnown,
            attribution: attribution,
            agentName: agentName,
            agentKind: agentKind,
            replicaScope: replicaScope,
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
        providerIsExplicit: Bool,
        inputTokens: Int,
        outputTokens: Int,
        cacheReadTokens: Int,
        cacheWriteTokens: Int,
        reasoningTokens: Int,
        cost: Double,
        costIsKnown: Bool?,
        attribution: UsageAttribution,
        agentName: String?,
        agentKind: WorkTimeAgentKind,
        replicaScope: String?,
        revisionIdentity: PiCompatibleRevisionIdentity,
        providerRevisionIdentity: PiCompatibleRevisionIdentity?,
        costRevisionIdentity: PiCompatibleRevisionIdentity) {
        self.deduplicationKey = deduplicationKey
        self.mergeAliases = mergeAliases
        self.mergePolicy = mergePolicy
        self.timestamp = timestamp
        self.model = model
        self.provider = provider
        self.providerIsExplicit = providerIsExplicit
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.cacheReadTokens = cacheReadTokens
        self.cacheWriteTokens = cacheWriteTokens
        self.reasoningTokens = reasoningTokens
        self.cost = cost
        self.costIsKnown = costIsKnown
        self.attribution = attribution
        self.agentName = agentName
        self.agentKind = agentKind
        self.replicaScope = replicaScope
        self.revisionIdentity = revisionIdentity
        self.providerRevisionIdentity = providerRevisionIdentity
        self.costRevisionIdentity = costRevisionIdentity
    }

    var totalTokens: Int {
        inputTokens + outputTokens + cacheReadTokens + cacheWriteTokens + reasoningTokens
    }
}

extension PiCompatibleUsageRecord {
    func merged(with other: Self, retainingAliases: Bool = true) -> Self {
        if mergePolicy == .legacy || other.mergePolicy == .legacy {
            return legacyMerged(with: other, retainingAliases: retainingAliases)
        }
        let selfIsPreferred = isCorePreferred(over: other)
        let preferred = selfIsPreferred ? self : other
        let supplemental = selfIsPreferred ? other : self
        let selectedProvider = deterministicProvider(with: other)
        let selectedCost = deterministicCost(with: other, preferred: preferred, supplemental: supplemental)
        return PiCompatibleUsageRecord(
            deduplicationKey: deduplicationKey.isOrdered(before: other.deduplicationKey)
                ? deduplicationKey
                : other.deduplicationKey,
            mergeAliases: retainingAliases ? mergeAliases.union(other.mergeAliases) : [],
            mergePolicy: .deterministic,
            timestamp: preferred.timestamp,
            model: preferred.model,
            provider: selectedProvider.value,
            providerIsExplicit: selectedProvider.isExplicit,
            inputTokens: preferred.inputTokens,
            outputTokens: preferred.outputTokens,
            cacheReadTokens: preferred.cacheReadTokens,
            cacheWriteTokens: preferred.cacheWriteTokens,
            reasoningTokens: preferred.reasoningTokens,
            cost: selectedCost.value,
            costIsKnown: selectedCost.isKnown,
            attribution: mergedAttribution(with: other),
            agentName: mergedAgentName(
                with: other,
                preferred: preferred,
                supplemental: supplemental),
            agentKind: agentKind == .subagent && other.agentKind == .subagent ? .subagent : .main,
            replicaScope: replicaScope == other.replicaScope ? replicaScope : nil,
            revisionIdentity: preferred.revisionIdentity,
            providerRevisionIdentity: selectedProvider.identity,
            costRevisionIdentity: selectedCost.identity)
    }

    private func legacyMerged(with other: Self, retainingAliases: Bool) -> Self {
        let selfIsPreferred = isLegacyPreferred(over: other)
        let preferred = selfIsPreferred ? self : other
        let fallback = selfIsPreferred ? other : self
        let providerRecord = preferred.provider == nil ? fallback : preferred
        return PiCompatibleUsageRecord(
            deduplicationKey: deduplicationKey,
            mergeAliases: retainingAliases ? mergeAliases.union(other.mergeAliases) : [],
            mergePolicy: .legacy,
            timestamp: preferred.timestamp,
            model: preferred.model,
            provider: providerRecord.provider,
            providerIsExplicit: providerRecord.providerIsExplicit,
            inputTokens: preferred.inputTokens,
            outputTokens: preferred.outputTokens,
            cacheReadTokens: preferred.cacheReadTokens,
            cacheWriteTokens: preferred.cacheWriteTokens,
            reasoningTokens: preferred.reasoningTokens,
            cost: preferred.cost,
            costIsKnown: preferred.costIsKnown,
            attribution: bestUsageAttribution(attribution, other.attribution) ?? attribution,
            agentName: preferred.agentName ?? fallback.agentName,
            agentKind: agentKind == .subagent && other.agentKind == .subagent ? .subagent : .main,
            replicaScope: replicaScope == other.replicaScope ? replicaScope : nil,
            revisionIdentity: preferred.revisionIdentity,
            providerRevisionIdentity: providerRecord.providerRevisionIdentity,
            costRevisionIdentity: preferred.costRevisionIdentity)
    }

    func replacingMergeAliases(_ aliases: Set<PiCompatibleMergeAlias>) -> Self {
        PiCompatibleUsageRecord(
            deduplicationKey: deduplicationKey,
            mergeAliases: aliases,
            mergePolicy: mergePolicy,
            timestamp: timestamp,
            model: model,
            provider: provider,
            providerIsExplicit: providerIsExplicit,
            inputTokens: inputTokens,
            outputTokens: outputTokens,
            cacheReadTokens: cacheReadTokens,
            cacheWriteTokens: cacheWriteTokens,
            reasoningTokens: reasoningTokens,
            cost: cost,
            costIsKnown: costIsKnown,
            attribution: attribution,
            agentName: agentName,
            agentKind: agentKind,
            replicaScope: replicaScope,
            revisionIdentity: revisionIdentity,
            providerRevisionIdentity: providerRevisionIdentity,
            costRevisionIdentity: costRevisionIdentity)
    }

    private func isLegacyPreferred(over other: Self) -> Bool {
        if totalTokens != other.totalTokens { return totalTokens > other.totalTokens }
        if cost != other.cost { return cost > other.cost }
        if costIsKnown != other.costIsKnown {
            return costKnowledgeRank(costIsKnown) > costKnowledgeRank(other.costIsKnown)
        }
        if timestamp != other.timestamp { return timestamp > other.timestamp }
        if model != other.model { return model < other.model }
        return revisionIdentity.isPreferred(over: other.revisionIdentity)
    }

    private func mergedAttribution(with other: Self) -> UsageAttribution {
        if agentKind != other.agentKind {
            return agentKind == .main ? attribution : other.attribution
        }
        return deterministicAttribution(attribution, other.attribution)
    }

    private func mergedAgentName(
        with other: Self,
        preferred: Self,
        supplemental: Self) -> String? {
        if agentKind != other.agentKind {
            return agentKind == .main ? agentName : other.agentName
        }
        return preferred.agentName ?? supplemental.agentName
    }

    private func deterministicProvider(with other: Self) -> PiCompatibleSelectedProvider {
        if providerIsExplicit != other.providerIsExplicit {
            return providerIsExplicit
                ? PiCompatibleSelectedProvider(
                    value: provider,
                    isExplicit: true,
                    identity: providerRevisionIdentity)
                : PiCompatibleSelectedProvider(
                    value: other.provider,
                    isExplicit: true,
                    identity: other.providerRevisionIdentity)
        }
        guard let provider else {
            return PiCompatibleSelectedProvider(
                value: other.provider,
                isExplicit: other.providerIsExplicit,
                identity: other.providerRevisionIdentity)
        }
        guard let otherProvider = other.provider else {
            return PiCompatibleSelectedProvider(
                value: provider,
                isExplicit: providerIsExplicit,
                identity: providerRevisionIdentity)
        }
        let identity = providerRevisionIdentity ?? revisionIdentity
        let otherIdentity = other.providerRevisionIdentity ?? other.revisionIdentity
        if identity != otherIdentity {
            return identity.isPreferred(over: otherIdentity)
                ? PiCompatibleSelectedProvider(
                    value: provider,
                    isExplicit: providerIsExplicit,
                    identity: identity)
                : PiCompatibleSelectedProvider(
                    value: otherProvider,
                    isExplicit: other.providerIsExplicit,
                    identity: otherIdentity)
        }
        return provider <= otherProvider
            ? PiCompatibleSelectedProvider(
                value: provider,
                isExplicit: providerIsExplicit,
                identity: identity)
            : PiCompatibleSelectedProvider(
                value: otherProvider,
                isExplicit: other.providerIsExplicit,
                identity: otherIdentity)
    }

    private func deterministicCost(
        with other: Self,
        preferred: Self,
        supplemental: Self) -> PiCompatibleSelectedCost {
        if costIsKnown != other.costIsKnown {
            return costKnowledgeRank(costIsKnown) > costKnowledgeRank(other.costIsKnown)
                ? selectedCost()
                : other.selectedCost()
        }
        if preferred.timestamp == supplemental.timestamp {
            return preferred.selectedCost()
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
    case sessionResponse(sessionID: String, provider: String?, responseID: String)
    case legacySessionResponse(sessionID: String, responseID: String)
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
            .sessionResponse(lhsSession, lhsProvider, lhsResponse),
            .sessionResponse(rhsSession, rhsProvider, rhsResponse)):
            if lhsSession != rhsSession { return lhsSession < rhsSession }
            if lhsProvider != rhsProvider { return (lhsProvider ?? "") < (rhsProvider ?? "") }
            return lhsResponse < rhsResponse
        case let (
            .legacySessionResponse(lhsSession, lhsResponse),
            .legacySessionResponse(rhsSession, rhsResponse)):
            if lhsSession != rhsSession { return lhsSession < rhsSession }
            return lhsResponse < rhsResponse
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
    let payloadDigest: String
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
    let isExplicit: Bool
    let identity: PiCompatibleRevisionIdentity?
}

private struct PiCompatibleSelectedCost {
    let value: Double
    let isKnown: Bool?
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
        costIsKnown: Bool?,
        attribution: UsageAttribution) -> Self {
        let fields: [String] = [
            model,
            provider ?? "",
            String(inputTokens),
            String(outputTokens),
            String(cacheReadTokens),
            String(cacheWriteTokens),
            String(reasoningTokens),
            String(cost.bitPattern),
            String(describing: costIsKnown),
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

private func costKnowledgeRank(_ value: Bool?) -> Int {
    switch value {
    case .some(true): 2
    case nil: 1
    case .some(false): 0
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
