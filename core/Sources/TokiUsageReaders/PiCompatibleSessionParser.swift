import Foundation
import TokiUsageCore

enum PiCompatibleSource {
    case senpi
    case pi
    case ohMyPi
    case kimchi

    var sourceName: String {
        switch self {
        case .senpi: "Senpi"
        case .pi: "Pi"
        case .ohMyPi: "Oh My Pi"
        case .kimchi: "Kimchi"
        }
    }

    var reportsReasoningSeparately: Bool {
        self == .senpi
    }
}

struct PiCompatibleUsageRecord {
    let deduplicationKey: PiCompatibleDeduplicationKey
    let timestamp: Date
    let model: String
    let provider: String?
    let inputTokens: Int
    let outputTokens: Int
    let cacheReadTokens: Int
    let cacheWriteTokens: Int
    let reasoningTokens: Int
    let cost: Double
    let attribution: UsageAttribution
    let agentKind: WorkTimeAgentKind

    var totalTokens: Int {
        inputTokens + outputTokens + cacheReadTokens + cacheWriteTokens + reasoningTokens
    }

    func merged(with other: Self) -> Self {
        let prefersSelf = totalTokens > other.totalTokens
            || (totalTokens == other.totalTokens && cost >= other.cost)
        let preferred = prefersSelf ? self : other
        let supplemental = prefersSelf ? other : self
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
            cost: preferred.cost,
            attribution: bestUsageAttribution(attribution, other.attribution) ?? attribution,
            agentKind: agentKind == .subagent || other.agentKind == .subagent ? .subagent : .main)
    }
}

enum PiCompatibleDeduplicationKey: Hashable {
    case message(String)
    case response(String)
    case record(
        timestamp: Date,
        provider: String?,
        model: String,
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
            if source == .ohMyPi, entry.type == "title" {
                return nil
            }
            if source != .senpi {
                rejectedPreHeader = true
            }
            return nil
        }
        guard !rejectedPreHeader else { return nil }

        if source == .pi, entry.type == "session_info" {
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
        let cost = boundedUsageCost(usage.cost?.total)
        let deduplicationKey: PiCompatibleDeduplicationKey = if let messageID {
            .message(messageID)
        } else if let responseID {
            .response(responseID)
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
            attribution: UsageAttribution(
                projectPath: sessionContext.cwd,
                sessionID: sessionContext.id,
                quality: sessionContext.cwd == nil ? .unknown : .exact),
            agentKind: agentKind)
    }
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
