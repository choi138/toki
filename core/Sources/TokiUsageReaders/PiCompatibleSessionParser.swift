import Foundation
import TokiSyncProtocol
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

    var mergePolicy: PiCompatibleMergePolicy {
        self == .senpi ? .legacy : .deterministic
    }

    var createsSharedMessageAliases: Bool {
        self == .piAndOhMyPi
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

        return usageRecord(
            data: data,
            entry: entry,
            message: message,
            usage: usage,
            sessionContext: sessionContext,
            timestamp: timestamp,
            model: model,
            lineIndex: lineIndex)
    }
}

private extension PiCompatibleSessionParser {
    func usageRecord(
        data: Data,
        entry: PiCompatibleEntry,
        message: PiCompatibleMessage,
        usage: PiCompatibleUsage,
        sessionContext: PiCompatibleSessionContext,
        timestamp: Date,
        model: String,
        lineIndex: Int) -> PiCompatibleUsageRecord {
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
        let cost = recordedCost ?? 0
        let deduplicationKey = deduplicationKey(
            sessionID: sessionContext.id,
            messageID: messageID,
            responseID: responseID,
            model: model,
            provider: provider,
            timestamp: timestamp,
            inputTokens: inputTokens,
            outputTokens: outputTokens,
            cacheReadTokens: cacheReadTokens,
            cacheWriteTokens: cacheWriteTokens,
            reasoningTokens: reasoning,
            cost: cost,
            lineIndex: lineIndex)
        let revisionDigest = source.mergePolicy == .deterministic
            ? canonicalPiPayloadDigest(data)
            : nil
        let copyPayloadDigest = source.mergePolicy == .deterministic
            ? canonicalPiCopyPayloadDigest(data)
            : nil
        let mergeAliases = mergeAliases(
            sessionID: sessionContext.id,
            messageID: messageID,
            responseID: responseID,
            model: model,
            timestamp: timestamp,
            inputTokens: inputTokens,
            outputTokens: outputTokens,
            cacheReadTokens: cacheReadTokens,
            cacheWriteTokens: cacheWriteTokens,
            reasoningTokens: reasoning,
            payloadDigest: copyPayloadDigest)
        return PiCompatibleUsageRecord(
            deduplicationKey: deduplicationKey,
            mergeAliases: mergeAliases,
            mergePolicy: source.mergePolicy,
            timestamp: timestamp,
            model: model,
            provider: provider,
            inputTokens: inputTokens,
            outputTokens: outputTokens,
            cacheReadTokens: cacheReadTokens,
            cacheWriteTokens: cacheWriteTokens,
            reasoningTokens: reasoning,
            cost: cost,
            costIsKnown: recordedCost != nil,
            attribution: UsageAttribution(
                projectPath: sessionContext.cwd,
                sessionID: sessionContext.id,
                quality: sessionContext.cwd == nil ? .unknown : .exact),
            agentKind: agentKind,
            revisionIdentity: revisionDigest.map {
                PiCompatibleRevisionIdentity(timestamp: timestamp, payloadDigest: $0)
            })
    }

    func deduplicationKey(
        sessionID: String,
        messageID: String?,
        responseID: String?,
        model: String,
        provider: String?,
        timestamp: Date,
        inputTokens: Int,
        outputTokens: Int,
        cacheReadTokens: Int,
        cacheWriteTokens: Int,
        reasoningTokens: Int,
        cost: Double,
        lineIndex: Int) -> PiCompatibleDeduplicationKey {
        if source == .senpi {
            return legacyDeduplicationKey(
                sessionID: sessionID,
                messageID: messageID,
                responseID: responseID,
                model: model,
                provider: provider,
                timestamp: timestamp,
                inputTokens: inputTokens,
                outputTokens: outputTokens,
                cacheReadTokens: cacheReadTokens,
                cacheWriteTokens: cacheWriteTokens,
                reasoningTokens: reasoningTokens,
                cost: cost,
                lineIndex: lineIndex)
        }
        if let messageID {
            if !source.usesSessionLocalMessageIDs || isGloballyUniquePiMessageID(messageID) {
                return .message(messageID)
            }
            return .sessionMessage(sessionID: sessionID, messageID: messageID)
        }
        if let responseID {
            return .sessionResponse(
                sessionID: sessionID,
                responseID: responseID)
        }
        return .record(streamID: streamID, lineIndex: lineIndex)
    }

    func legacyDeduplicationKey(
        sessionID: String,
        messageID: String?,
        responseID: String?,
        model: String,
        provider: String?,
        timestamp: Date,
        inputTokens: Int,
        outputTokens: Int,
        cacheReadTokens: Int,
        cacheWriteTokens: Int,
        reasoningTokens: Int,
        cost: Double,
        lineIndex: Int) -> PiCompatibleDeduplicationKey {
        if let messageID { return .message(messageID) }
        if let responseID {
            return .legacySessionResponse(
                sessionID: sessionID,
                responseID: responseID,
                model: model)
        }
        return .legacyRecord(PiCompatibleLegacyRecordIdentity(
            timestamp: timestamp,
            provider: provider,
            model: model,
            inputTokens: inputTokens,
            outputTokens: outputTokens,
            cacheReadTokens: cacheReadTokens,
            cacheWriteTokens: cacheWriteTokens,
            reasoningTokens: reasoningTokens,
            cost: cost,
            location: "\(streamID)#\(lineIndex)"))
    }

    func mergeAliases(
        sessionID: String,
        messageID: String?,
        responseID: String?,
        model: String,
        timestamp: Date,
        inputTokens: Int,
        outputTokens: Int,
        cacheReadTokens: Int,
        cacheWriteTokens: Int,
        reasoningTokens: Int,
        payloadDigest: String?) -> Set<PiCompatibleMergeAlias> {
        if source == .senpi {
            guard messageID == nil, let responseID else { return [] }
            return [.legacyResponseCopy(PiCompatibleLegacyResponseCopyIdentity(
                responseID: responseID,
                timestamp: timestamp,
                model: model,
                inputTokens: inputTokens,
                outputTokens: outputTokens,
                cacheReadTokens: cacheReadTokens,
                cacheWriteTokens: cacheWriteTokens,
                reasoningTokens: reasoningTokens))]
        }
        guard let payloadDigest else { return [] }
        var aliases: Set<PiCompatibleMergeAlias> = []
        if let messageID {
            aliases.insert(.sessionMessage(sessionID: sessionID, messageID: messageID))
            if source.createsSharedMessageAliases {
                aliases.insert(.messageCopy(id: messageID, payloadDigest: payloadDigest))
            }
        }
        if let responseID {
            aliases.insert(.sessionResponse(sessionID: sessionID, responseID: responseID))
            aliases.insert(.responseCopy(id: responseID, payloadDigest: payloadDigest))
        }
        return aliases
    }
}

private func canonicalPiPayloadDigest(_ data: Data) -> String {
    guard let object = try? JSONSerialization.jsonObject(with: data) else {
        return SnapshotCipher.digest(data)
    }
    return canonicalPiPayloadDigest(object, fallback: data)
}

private func canonicalPiCopyPayloadDigest(_ data: Data) -> String {
    guard var object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          var message = object["message"] as? [String: Any] else {
        return canonicalPiPayloadDigest(data)
    }
    message.removeValue(forKey: "provider")
    if var usage = message["usage"] as? [String: Any] {
        usage.removeValue(forKey: "cost")
        message["usage"] = usage
    }
    object["message"] = message
    return canonicalPiPayloadDigest(object, fallback: data)
}

private func canonicalPiPayloadDigest(_ object: Any, fallback data: Data) -> String {
    guard JSONSerialization.isValidJSONObject(object),
          let canonicalData = try? JSONSerialization.data(
              withJSONObject: object,
              options: [.sortedKeys]) else {
        return SnapshotCipher.digest(data)
    }
    return SnapshotCipher.digest(canonicalData)
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
