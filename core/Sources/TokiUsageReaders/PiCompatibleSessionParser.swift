import Foundation
import TokiUsageCore

enum PiCompatibleSource {
    case senpi
    case pi
    case ohMyPi
    case piAndOhMyPi
    case kimchi

    var sourceName: String {
        switch self {
        case .senpi: "Senpi"
        case .pi: "Pi"
        case .ohMyPi: "Oh My Pi"
        case .piAndOhMyPi: "Pi / Oh My Pi"
        case .kimchi: "Kimchi"
        }
    }

    var reportsReasoningSeparately: Bool {
        self == .senpi
    }

    var acceptsLeadingTitle: Bool {
        self == .ohMyPi || self == .piAndOhMyPi
    }

    var recordsPiSessionInfo: Bool {
        self == .pi || self == .piAndOhMyPi
    }

    var usesSessionLocalMessageIDs: Bool {
        self == .pi || self == .piAndOhMyPi
    }
}

struct PiCompatibleResponseCopyKey: Hashable {
    let responseID: String
    let timestamp: Date
    let model: String
    let inputTokens: Int
    let outputTokens: Int
    let cacheReadTokens: Int
    let cacheWriteTokens: Int
    let reasoningTokens: Int

    fileprivate func isOrdered(before other: Self) -> Bool {
        if timestamp != other.timestamp { return timestamp < other.timestamp }
        if responseID != other.responseID { return responseID < other.responseID }
        if model != other.model { return model < other.model }
        let buckets = [inputTokens, outputTokens, cacheReadTokens, cacheWriteTokens, reasoningTokens]
        let otherBuckets = [
            other.inputTokens,
            other.outputTokens,
            other.cacheReadTokens,
            other.cacheWriteTokens,
            other.reasoningTokens,
        ]
        return buckets.lexicographicallyPrecedes(otherBuckets)
    }
}

struct PiCompatibleUsageRecord {
    let deduplicationKey: PiCompatibleDeduplicationKey
    let responseCopyKey: PiCompatibleResponseCopyKey?
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

    init(
        deduplicationKey: PiCompatibleDeduplicationKey,
        responseCopyKey: PiCompatibleResponseCopyKey? = nil,
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
        agentKind: WorkTimeAgentKind) {
        self.deduplicationKey = deduplicationKey
        self.responseCopyKey = responseCopyKey
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
    }

    var totalTokens: Int {
        inputTokens + outputTokens + cacheReadTokens + cacheWriteTokens + reasoningTokens
    }

    func merged(with other: Self) -> Self {
        let selfIsPreferred = isPreferred(over: other)
        let preferred = selfIsPreferred ? self : other
        let mergedCost = deterministicCost(with: other)
        return PiCompatibleUsageRecord(
            deduplicationKey: deduplicationKey.isOrdered(before: other.deduplicationKey)
                ? deduplicationKey
                : other.deduplicationKey,
            responseCopyKey: earliestResponseCopyKey(responseCopyKey, other.responseCopyKey),
            timestamp: preferred.timestamp,
            model: preferred.model,
            provider: deterministicProvider(provider, other.provider),
            inputTokens: preferred.inputTokens,
            outputTokens: preferred.outputTokens,
            cacheReadTokens: preferred.cacheReadTokens,
            cacheWriteTokens: preferred.cacheWriteTokens,
            reasoningTokens: preferred.reasoningTokens,
            cost: mergedCost.cost,
            costIsKnown: mergedCost.isKnown,
            attribution: deterministicAttribution(attribution, other.attribution),
            agentKind: agentKind == .subagent || other.agentKind == .subagent ? .subagent : .main)
    }

    private func deterministicCost(with other: Self) -> (cost: Double, isKnown: Bool) {
        switch (costIsKnown, other.costIsKnown) {
        case (true, true):
            (max(cost, other.cost), true)
        case (true, false):
            (cost, true)
        case (false, true):
            (other.cost, true)
        case (false, false):
            (max(cost, other.cost), false)
        }
    }

    private func isPreferred(over other: Self) -> Bool {
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
        return true
    }
}

enum PiCompatibleDeduplicationKey: Hashable {
    case message(String)
    case sessionMessage(sessionID: String, messageID: String)
    case sessionResponse(sessionID: String, responseID: String, model: String)
    case record(streamID: String, lineIndex: Int)

    fileprivate func isOrdered(before other: Self) -> Bool {
        let lhsRank = caseRank
        let rhsRank = other.caseRank
        guard lhsRank == rhsRank else { return lhsRank < rhsRank }
        switch (self, other) {
        case let (.message(lhs), .message(rhs)):
            return lhs <= rhs
        case let (.sessionMessage(lhsSession, lhsMessage), .sessionMessage(rhsSession, rhsMessage)):
            if lhsSession != rhsSession { return lhsSession < rhsSession }
            return lhsMessage <= rhsMessage
        case let (
            .sessionResponse(lhsSession, lhsResponse, lhsModel),
            .sessionResponse(rhsSession, rhsResponse, rhsModel)):
            if lhsSession != rhsSession { return lhsSession < rhsSession }
            if lhsResponse != rhsResponse { return lhsResponse < rhsResponse }
            return lhsModel <= rhsModel
        case let (.record(lhsStream, lhsLine), .record(rhsStream, rhsLine)):
            if lhsStream != rhsStream { return lhsStream < rhsStream }
            return lhsLine <= rhsLine
        default:
            return false
        }
    }

    private var caseRank: Int {
        switch self {
        case .message: 0
        case .sessionMessage: 1
        case .sessionResponse: 2
        case .record: 3
        }
    }
}

struct PiCompatibleSessionParser {
    private let decoder = JSONDecoder()
    private let streamID: String
    private let source: PiCompatibleSource
    private var agentKind: WorkTimeAgentKind
    private var sessionContext: PiCompatibleSessionContext?
    private var rejectedPreHeader = false

    init(
        streamID: String,
        source: PiCompatibleSource = .senpi,
        agentKind: WorkTimeAgentKind) {
        self.streamID = streamID
        self.source = source
        self.agentKind = agentKind
    }

    static func records(
        fromJSONLLines lines: [String],
        streamID: String,
        source: PiCompatibleSource = .senpi,
        agentKind: WorkTimeAgentKind) -> [PiCompatibleUsageRecord] {
        var parser = Self(streamID: streamID, source: source, agentKind: agentKind)
        var records: [PiCompatibleUsageRecord] = []

        for (lineIndex, line) in lines.enumerated() {
            if let record = parser.record(fromJSONLLine: line, lineIndex: lineIndex) {
                records.append(record)
            }
        }
        return records
    }

    mutating func record(
        fromJSONLLine line: String,
        lineIndex: Int) -> PiCompatibleUsageRecord? {
        guard let data = line.data(using: .utf8),
              let entry = try? decoder.decode(PiCompatibleEntry.self, from: data) else {
            return nil
        }

        if entry.type == "session" {
            sessionContext = PiCompatibleSessionContext(
                id: nonEmptyPiValue(entry.id) ?? usageSessionID(fromPath: streamID),
                cwd: nonEmptyPiValue(entry.cwd))
            return nil
        }

        guard sessionContext != nil else {
            if source.acceptsLeadingTitle, entry.type == "title" {
                return nil
            }
            if source != .senpi {
                rejectedPreHeader = true
            }
            return nil
        }
        guard !rejectedPreHeader else { return nil }

        if source.recordsPiSessionInfo, entry.type == "session_info" {
            agentKind = strictPiSubagentName(from: entry.name) == nil ? .main : .subagent
            return nil
        }

        guard let sessionContext,
              entry.type == "message",
              let message = entry.message,
              message.role == "assistant",
              let model = normalizedModelID(message.model),
              let usage = message.usage,
              let timestamp = entry.timestamp.flatMap(DateParser.parse) else {
            return nil
        }

        let outputIncludingReasoning = boundedUsageTokenCount(usage.output)
        let recordedReasoning = min(
            boundedUsageTokenCount(usage.reasoning),
            outputIncludingReasoning)
        let reasoning = source.reportsReasoningSeparately ? recordedReasoning : 0
        let messageID = nonEmptyPiValue(entry.id)
        let responseID = nonEmptyPiValue(message.responseID)
        let provider = nonEmptyPiValue(message.provider) ?? inferredUsageProvider(from: model)
        let inputTokens = boundedUsageTokenCount(usage.input)
        let outputTokens = outputIncludingReasoning - reasoning
        let cacheReadTokens = boundedUsageTokenCount(usage.cacheRead)
        let cacheWriteTokens = boundedUsageTokenCount(usage.cacheWrite)
        let recordedCost = boundedRecordedUsageCost(usage.cost?.total)
        let deduplicationKey = deduplicationKey(
            sessionID: sessionContext.id,
            messageID: messageID,
            responseID: responseID,
            model: model,
            lineIndex: lineIndex)
        let responseCopyKey = piResponseCopyKey(
            messageID: messageID,
            responseID: responseID,
            timestamp: timestamp,
            model: model,
            inputTokens: inputTokens,
            outputTokens: outputTokens,
            cacheReadTokens: cacheReadTokens,
            cacheWriteTokens: cacheWriteTokens,
            reasoningTokens: reasoning)
        return PiCompatibleUsageRecord(
            deduplicationKey: deduplicationKey,
            responseCopyKey: responseCopyKey,
            timestamp: timestamp,
            model: model,
            provider: provider,
            inputTokens: inputTokens,
            outputTokens: outputTokens,
            cacheReadTokens: cacheReadTokens,
            cacheWriteTokens: cacheWriteTokens,
            reasoningTokens: reasoning,
            cost: recordedCost ?? 0,
            costIsKnown: recordedCost != nil,
            attribution: UsageAttribution(
                projectPath: sessionContext.cwd,
                sessionID: sessionContext.id,
                quality: sessionContext.cwd == nil ? .unknown : .exact),
            agentKind: agentKind)
    }

    private func deduplicationKey(
        sessionID: String,
        messageID: String?,
        responseID: String?,
        model: String,
        lineIndex: Int) -> PiCompatibleDeduplicationKey {
        if let messageID {
            if !source.usesSessionLocalMessageIDs || isGloballyUniquePiMessageID(messageID) {
                return .message(messageID)
            }
            return .sessionMessage(sessionID: sessionID, messageID: messageID)
        }
        if let responseID {
            return .sessionResponse(
                sessionID: sessionID,
                responseID: responseID,
                model: model)
        }
        return .record(streamID: streamID, lineIndex: lineIndex)
    }
}

private func piResponseCopyKey(
    messageID: String?,
    responseID: String?,
    timestamp: Date,
    model: String,
    inputTokens: Int,
    outputTokens: Int,
    cacheReadTokens: Int,
    cacheWriteTokens: Int,
    reasoningTokens: Int) -> PiCompatibleResponseCopyKey? {
    guard messageID == nil, let responseID else { return nil }
    return PiCompatibleResponseCopyKey(
        responseID: responseID,
        timestamp: timestamp,
        model: model,
        inputTokens: inputTokens,
        outputTokens: outputTokens,
        cacheReadTokens: cacheReadTokens,
        cacheWriteTokens: cacheWriteTokens,
        reasoningTokens: reasoningTokens)
}

private func earliestResponseCopyKey(
    _ lhs: PiCompatibleResponseCopyKey?,
    _ rhs: PiCompatibleResponseCopyKey?) -> PiCompatibleResponseCopyKey? {
    guard let lhs else { return rhs }
    guard let rhs else { return lhs }
    return lhs.isOrdered(before: rhs) ? lhs : rhs
}

private func deterministicProvider(_ lhs: String?, _ rhs: String?) -> String? {
    guard let lhs else { return rhs }
    guard let rhs else { return lhs }
    return min(lhs, rhs)
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
        + (attribution.projectPath == nil ? 0 : 20)
        + (attribution.sessionID == nil ? 0 : 1)
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

private struct PiCompatibleSessionContext {
    let id: String
    let cwd: String?
}

private struct PiCompatibleEntry: Decodable {
    let type: String?
    let id: String?
    let timestamp: String?
    let cwd: String?
    let name: String?
    let message: PiCompatibleMessage?
}

private struct PiCompatibleMessage: Decodable {
    let role: String?
    let model: String?
    let provider: String?
    let responseID: String?
    let usage: PiCompatibleUsage?

    enum CodingKeys: String, CodingKey {
        case role, model, provider, usage
        case responseID = "responseId"
    }
}

private struct PiCompatibleUsage: Decodable {
    let input: Int?
    let output: Int?
    let cacheRead: Int?
    let cacheWrite: Int?
    let reasoning: Int?
    let cost: PiCompatibleCost?
}

private struct PiCompatibleCost: Decodable {
    let total: Double?
}

private func nonEmptyPiValue(_ value: String?) -> String? {
    guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines),
          !trimmed.isEmpty else {
        return nil
    }
    return trimmed
}

private func isGloballyUniquePiMessageID(_ value: String) -> Bool {
    UUID(uuidString: value) != nil
}

private func strictPiSubagentName(from value: String?) -> String? {
    guard var name = nonEmptyPiValue(value),
          name.hasPrefix("subagent-") else {
        return nil
    }
    name.removeFirst("subagent-".count)
    if let parsed = piAgentName(fromGeneratedSuffix: name) {
        return parsed
    }
    guard let index = name.lastIndex(of: "-") else { return nil }
    let numericSuffix = name[name.index(after: index)...]
    guard !numericSuffix.isEmpty,
          numericSuffix.allSatisfy(\.isNumber) else {
        return nil
    }
    return piAgentName(fromGeneratedSuffix: String(name[..<index]))
}

private func piAgentName(fromGeneratedSuffix name: String) -> String? {
    if name.count > 36 {
        let suffixStart = name.index(name.endIndex, offsetBy: -36)
        let separator = name.index(before: suffixStart)
        let suffix = String(name[suffixStart...])
        if name[separator] == "-", UUID(uuidString: suffix) != nil {
            return nonEmptyPiValue(String(name[..<separator]))
        }
    }
    guard name.count > 8 else { return nil }
    let suffixStart = name.index(name.endIndex, offsetBy: -8)
    let separator = name.index(before: suffixStart)
    let suffix = name[suffixStart...]
    guard name[separator] == "-",
          suffix.allSatisfy(\.isHexDigit) else {
        return nil
    }
    return nonEmptyPiValue(String(name[..<separator]))
}
