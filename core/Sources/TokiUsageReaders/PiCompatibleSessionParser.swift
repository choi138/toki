import Foundation
import TokiUsageCore

enum PiCompatibleSource {
    case gjc
    case senpi
    case pi
    case ohMyPi
    case kimchi

    var sourceName: String {
        switch self {
        case .gjc: "GJC"
        case .senpi: "Senpi"
        case .pi: "Pi"
        case .ohMyPi: "Oh My Pi"
        case .kimchi: "Kimchi"
        }
    }

    var reportsReasoningSeparately: Bool {
        self == .senpi || self == .gjc
    }
}

struct PiCompatibleUsageRecord {
    let deduplicationKey: PiCompatibleDeduplicationKey
    let timestamp: Date
    let model: String?
    let provider: String?
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

    var totalTokens: Int {
        inputTokens + outputTokens + cacheReadTokens + cacheWriteTokens + reasoningTokens
    }

    func merged(with other: Self) -> Self {
        let prefersSelf = totalTokens > other.totalTokens
            || (totalTokens == other.totalTokens && cost > other.cost)
            || (totalTokens == other.totalTokens && cost == other.cost
                && costIsKnown == true && other.costIsKnown != true)
        let preferred = prefersSelf ? self : other
        let supplemental = prefersSelf ? other : self
        let costSource: Self = if costIsKnown == true, other.costIsKnown != true {
            self
        } else if other.costIsKnown == true, costIsKnown != true {
            other
        } else if cost >= other.cost {
            self
        } else {
            other
        }
        return PiCompatibleUsageRecord(
            deduplicationKey: deduplicationKey,
            timestamp: preferred.timestamp,
            model: preferred.model,
            provider: preferred.provider ?? supplemental.provider,
            inputTokens: preferred.inputTokens,
            outputTokens: preferred.outputTokens,
            cacheReadTokens: preferred.cacheReadTokens,
            cacheWriteTokens: preferred.cacheWriteTokens,
            reasoningTokens: preferred.reasoningTokens,
            cost: costSource.cost,
            costIsKnown: costIsKnown == true || other.costIsKnown == true
                ? true
                : (preferred.costIsKnown ?? supplemental.costIsKnown),
            attribution: bestUsageAttribution(attribution, other.attribution) ?? attribution,
            agentName: preferred.agentName ?? supplemental.agentName,
            agentKind: agentKind == .subagent || other.agentKind == .subagent ? .subagent : .main)
    }
}

enum PiCompatibleDeduplicationKey: Hashable {
    case message(sessionID: String, id: String)
    case response(sessionID: String, provider: String?, id: String)
    case record(
        timestamp: Date,
        provider: String?,
        model: String?,
        inputTokens: Int,
        outputTokens: Int,
        cacheReadTokens: Int,
        cacheWriteTokens: Int,
        reasoningTokens: Int,
        cost: Double,
        location: String)
}

struct PiCompatibleSessionParser {
    private let decoder = JSONDecoder()
    private let streamID: String
    private let source: PiCompatibleSource
    private var agentKind: WorkTimeAgentKind
    private var agentName: String?
    private var sessionContext: PiCompatibleSessionContext?
    private var responseProviders: [PiCompatibleResponseScope: String] = [:]
    private var rejectedPreHeader = false

    init(
        streamID: String,
        source: PiCompatibleSource = .senpi,
        agentKind: WorkTimeAgentKind) {
        self.streamID = streamID
        self.source = source
        self.agentKind = agentKind
        agentName = nil
        sessionContext = source == .gjc
            ? PiCompatibleSessionContext(
                id: usageSessionID(fromPath: streamID),
                cwd: nil)
            : nil
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
            let nextSessionID = nonEmptyPiValue(entry.id) ?? usageSessionID(fromPath: streamID)
            if sessionContext != nil, sessionContext?.id != nextSessionID {
                agentName = nil
                agentKind = .main
            }
            sessionContext = PiCompatibleSessionContext(
                id: nextSessionID,
                cwd: nonEmptyPiValue(entry.cwd))
            return nil
        }

        guard sessionContext != nil else {
            if source == .ohMyPi, entry.type == "title" {
                return nil
            }
            if source != .senpi, source != .gjc {
                rejectedPreHeader = true
            }
            return nil
        }
        guard !rejectedPreHeader else { return nil }

        if source == .pi, entry.type == "session_info" {
            agentName = strictPiSubagentName(from: entry.name)
            agentKind = agentName == nil ? .main : .subagent
            return nil
        }

        guard let sessionContext,
              entry.type == "message",
              let message = entry.message,
              let usage = usage(from: message),
              let timestamp = entry.timestamp.flatMap(DateParser.parse) else {
            return nil
        }

        return makeRecord(
            entry: entry,
            message: message,
            usage: usage,
            timestamp: timestamp,
            sessionContext: sessionContext,
            lineIndex: lineIndex)
    }

    private mutating func makeRecord(
        entry: PiCompatibleEntry,
        message: PiCompatibleMessage,
        usage: PiCompatibleUsage,
        timestamp: Date,
        sessionContext: PiCompatibleSessionContext,
        lineIndex: Int) -> PiCompatibleUsageRecord? {
        let model = normalizedModelID(message.model)
        guard source == .gjc || model != nil else { return nil }
        let outputIncludingReasoning = boundedUsageTokenCount(usage.output)
        let recordedReasoning = min(
            boundedUsageTokenCount(usage.reasoning ?? usage.reasoningTokens),
            outputIncludingReasoning)
        let reasoning = source.reportsReasoningSeparately ? recordedReasoning : 0
        let messageID = nonEmptyPiValue(entry.id)
        let responseID = nonEmptyPiValue(message.responseID)
        let responseScope = responseID.map {
            PiCompatibleResponseScope(sessionID: sessionContext.id, responseID: $0)
        }
        let provider = nonEmptyPiValue(message.provider)
            ?? responseScope.flatMap { responseProviders[$0] }
            ?? inferredUsageProvider(from: model)
        if let responseScope, let provider {
            responseProviders[responseScope] = provider
        }
        let inputTokens = boundedUsageTokenCount(usage.input)
        let outputTokens = outputIncludingReasoning - reasoning
        let cacheReadTokens = boundedUsageTokenCount(usage.cacheRead)
        let cacheWriteTokens = boundedUsageTokenCount(usage.cacheWrite)
        let cost = boundedUsageCost(usage.cost?.total)
        let costIsKnown: Bool? = if usage.cost != nil {
            true
        } else if source == .gjc {
            nil
        } else {
            false
        }
        let deduplicationKey: PiCompatibleDeduplicationKey = if let messageID {
            .message(sessionID: sessionContext.id, id: messageID)
        } else if let responseID {
            .response(
                sessionID: sessionContext.id,
                provider: provider,
                id: responseID)
        } else {
            .record(
                timestamp: timestamp,
                provider: provider,
                model: model,
                inputTokens: inputTokens,
                outputTokens: outputTokens,
                cacheReadTokens: cacheReadTokens,
                cacheWriteTokens: cacheWriteTokens,
                reasoningTokens: reasoning,
                cost: cost,
                location: "\(streamID)#\(lineIndex)")
        }
        return PiCompatibleUsageRecord(
            deduplicationKey: deduplicationKey,
            timestamp: timestamp,
            model: model,
            provider: provider,
            inputTokens: inputTokens,
            outputTokens: outputTokens,
            cacheReadTokens: cacheReadTokens,
            cacheWriteTokens: cacheWriteTokens,
            reasoningTokens: reasoning,
            cost: cost,
            costIsKnown: costIsKnown,
            attribution: UsageAttribution(
                projectPath: sessionContext.cwd,
                sessionID: sessionContext.id,
                quality: sessionContext.cwd == nil ? .unknown : .exact),
            agentName: agentName,
            agentKind: agentKind)
    }

    private func usage(from message: PiCompatibleMessage) -> PiCompatibleUsage? {
        if message.role == "assistant" {
            return message.usage
        }
        guard source == .gjc,
              message.role == "toolResult",
              message.toolName == "task" else {
            return nil
        }
        return message.details?.usage
    }
}

struct PiCompatibleMessageSnapshot {
    let provider: String?
    let model: String?
    let sessionID: String?
    let cwd: String?
    let agentName: String?
    let agentKind: WorkTimeAgentKind
}

extension PiCompatibleSessionParser {
    static func messages(
        fromJSONLLines lines: [String],
        source: PiCompatibleSource) -> [PiCompatibleMessageSnapshot] {
        records(
            fromJSONLLines: lines,
            streamID: "inline-session",
            source: source,
            agentKind: .main)
            .map { record in
                PiCompatibleMessageSnapshot(
                    provider: record.provider,
                    model: record.model,
                    sessionID: record.attribution.sessionID,
                    cwd: record.attribution.projectPath,
                    agentName: record.agentName,
                    agentKind: record.agentKind)
            }
    }
}

private struct PiCompatibleSessionContext {
    let id: String
    let cwd: String?
}

private struct PiCompatibleResponseScope: Hashable {
    let sessionID: String
    let responseID: String
}

private struct PiCompatibleEntry: Decodable {
    let type: String?
    let id: String?
    let timestamp: String?
    let cwd: String?
    let name: String?
    let message: PiCompatibleMessage?

    enum CodingKeys: String, CodingKey {
        case type, id, timestamp, cwd, name, message
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        type = try? container.decodeIfPresent(String.self, forKey: .type)
        id = try? container.decodeIfPresent(String.self, forKey: .id)
        timestamp = try? container.decodeIfPresent(String.self, forKey: .timestamp)
        cwd = try? container.decodeIfPresent(String.self, forKey: .cwd)
        name = try? container.decodeIfPresent(String.self, forKey: .name)
        message = try? container.decodeIfPresent(PiCompatibleMessage.self, forKey: .message)
    }
}

private struct PiCompatibleMessage: Decodable {
    let role: String?
    let toolName: String?
    let model: String?
    let provider: String?
    let responseID: String?
    let usage: PiCompatibleUsage?
    let details: PiCompatibleDetails?

    enum CodingKeys: String, CodingKey {
        case role, toolName, model, provider, usage, details
        case responseID = "responseId"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        role = try? container.decodeIfPresent(String.self, forKey: .role)
        toolName = try? container.decodeIfPresent(String.self, forKey: .toolName)
        model = try? container.decodeIfPresent(String.self, forKey: .model)
        provider = try? container.decodeIfPresent(String.self, forKey: .provider)
        responseID = try? container.decodeIfPresent(String.self, forKey: .responseID)
        usage = try? container.decodeIfPresent(PiCompatibleUsage.self, forKey: .usage)
        details = try? container.decodeIfPresent(PiCompatibleDetails.self, forKey: .details)
    }
}

private struct PiCompatibleDetails: Decodable {
    let usage: PiCompatibleUsage?

    enum CodingKeys: String, CodingKey {
        case usage
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        usage = try? container.decodeIfPresent(PiCompatibleUsage.self, forKey: .usage)
    }
}

private struct PiCompatibleUsage: Decodable {
    let input: Int?
    let output: Int?
    let cacheRead: Int?
    let cacheWrite: Int?
    let reasoning: Int?
    let reasoningTokens: Int?
    let cost: PiCompatibleCost?

    enum CodingKeys: String, CodingKey {
        case input, output, cacheRead, cacheWrite, reasoning, reasoningTokens, cost
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        input = try? container.decodeIfPresent(Int.self, forKey: .input)
        output = try? container.decodeIfPresent(Int.self, forKey: .output)
        cacheRead = try? container.decodeIfPresent(Int.self, forKey: .cacheRead)
        cacheWrite = try? container.decodeIfPresent(Int.self, forKey: .cacheWrite)
        reasoning = try? container.decodeIfPresent(Int.self, forKey: .reasoning)
        reasoningTokens = try? container.decodeIfPresent(Int.self, forKey: .reasoningTokens)
        cost = try? container.decodeIfPresent(PiCompatibleCost.self, forKey: .cost)
    }
}

private struct PiCompatibleCost: Decodable {
    let total: Double?

    enum CodingKeys: String, CodingKey {
        case total
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        total = try? container.decodeIfPresent(Double.self, forKey: .total)
    }
}

private func nonEmptyPiValue(_ value: String?) -> String? {
    guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines),
          !trimmed.isEmpty else {
        return nil
    }
    return trimmed
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
