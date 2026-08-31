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

    fileprivate var preHeaderPolicy: PiPreHeaderPolicy {
        self == .ohMyPi ? .titles : .none
    }

    fileprivate var sessionInfoPolicy: PiSessionInfoPolicy {
        self == .pi ? .generatedSubagent : .ignored
    }

    fileprivate var usagePolicy: PiUsagePolicy {
        self == .gjc ? .gjc : .assistant
    }

    var dedupNamespace: String {
        switch self {
        case .gjc: "gjc"
        case .senpi: "senpi"
        case .pi: "pi"
        case .ohMyPi: "omp"
        case .kimchi: "kimchi"
        }
    }
}

struct PiCompatibleMessage {
    let id: String?
    let responseID: String?
    let timestamp: Date
    let sessionID: String
    let cwd: String?
    let provider: String?
    let model: String?
    let inputTokens: Int
    let outputTokens: Int
    let cacheReadTokens: Int
    let cacheWriteTokens: Int
    let reasoningTokens: Int
    let cost: Double?
    let agentName: String?
    let agentKind: WorkTimeAgentKind

    var totalTokens: Int {
        checkedTokenTotal(
            inputTokens,
            outputTokens,
            cacheReadTokens,
            cacheWriteTokens,
            reasoningTokens) ?? 0
    }

    func dedupKey(namespace: String) -> String {
        if let responseID = responseID?.nilIfBlank {
            let components: [String] = [
                namespace,
                "response",
                sessionID,
                provider ?? "unknown",
                model ?? "unknown",
                responseID,
                "\(timestamp.timeIntervalSince1970)",
                "\(inputTokens)",
                "\(outputTokens)",
                "\(cacheReadTokens)",
                "\(cacheWriteTokens)",
                "\(reasoningTokens)",
                cost.map { "\($0)" } ?? "unknown",
            ]
            return components.joined(separator: ":")
        }
        let components: [String] = [
            namespace,
            "message",
            sessionID,
            id?.nilIfBlank ?? "missing",
            "\(timestamp.timeIntervalSince1970)",
            provider ?? "unknown",
            model ?? "unknown",
            "\(inputTokens)",
            "\(outputTokens)",
            "\(cacheReadTokens)",
            "\(cacheWriteTokens)",
            "\(reasoningTokens)",
            cost.map { "\($0)" } ?? "unknown",
        ]
        return components.joined(separator: ":")
    }
}

enum PiCompatibleSessionParser {
    static func messages(
        fromJSONLLines lines: [String],
        source: PiCompatibleSource,
        fallbackSessionID: String? = nil) -> [PiCompatibleMessage] {
        let decoder = JSONDecoder()
        var context = source == .gjc
            ? fallbackSessionID?.nilIfBlank.map { PiSessionContext(id: $0, cwd: nil) }
            : nil
        var agentName: String?
        var messages: [PiCompatibleMessage] = []

        for line in lines {
            guard let data = line.data(using: .utf8),
                  let entry = try? decoder.decode(PiEntry.self, from: data) else {
                continue
            }

            guard var currentContext = context else {
                if entry.type == "session",
                   let id = entry.id?.nilIfBlank {
                    context = PiSessionContext(id: id, cwd: entry.cwd?.nilIfBlank)
                    continue
                }
                if source.preHeaderPolicy.accepts(entry.type) {
                    continue
                }
                return []
            }

            if entry.type == "session" {
                if let id = entry.id?.nilIfBlank {
                    currentContext.id = id
                }
                if let cwd = entry.cwd?.nilIfBlank {
                    currentContext.cwd = cwd
                }
                context = currentContext
                continue
            }

            if entry.type == "session_info" {
                agentName = source.sessionInfoPolicy.agentName(from: entry.name)
                continue
            }

            guard entry.type == "message",
                  let message = entry.message,
                  let usage = source.usagePolicy.usage(from: message),
                  let timestamp = entry.timestamp.flatMap(DateParser.parse) else {
                continue
            }

            guard let counts = source.usagePolicy.counts(from: usage) else {
                continue
            }
            let model = normalizedModelID(message.model)
            let provider = message.provider?.nilIfBlank
                ?? inferredUsageProvider(from: model)
            messages.append(PiCompatibleMessage(
                id: entry.id,
                responseID: message.responseID,
                timestamp: timestamp,
                sessionID: currentContext.id,
                cwd: currentContext.cwd,
                provider: provider,
                model: model,
                inputTokens: counts.input,
                outputTokens: counts.output,
                cacheReadTokens: counts.cacheRead,
                cacheWriteTokens: counts.cacheWrite,
                reasoningTokens: counts.reasoning,
                cost: usage.cost?.total.map { max(0, $0) },
                agentName: agentName,
                agentKind: agentName == nil ? .main : .subagent))
        }

        return context == nil ? [] : messages
    }
}

private enum PiPreHeaderPolicy {
    case none
    case titles

    func accepts(_ type: String?) -> Bool {
        self == .titles && type == "title"
    }
}

private enum PiSessionInfoPolicy {
    case ignored
    case generatedSubagent

    func agentName(from value: String?) -> String? {
        switch self {
        case .ignored:
            nil
        case .generatedSubagent:
            piSubagentName(from: value)
        }
    }
}

private enum PiUsagePolicy {
    case assistant
    case gjc

    func usage(from message: PiMessage) -> PiUsage? {
        switch self {
        case .assistant:
            return message.role == "assistant" ? message.usage : nil
        case .gjc:
            if message.role == "assistant" {
                return message.usage
            }
            return message.role == "toolResult" && message.toolName == "task"
                ? message.details?.usage
                : nil
        }
    }

    func counts(from usage: PiUsage) -> PiTokenCounts? {
        guard let input = normalizedPiTokenCount(usage.input),
              let output = normalizedPiTokenCount(usage.output),
              let cacheRead = normalizedPiTokenCount(usage.cacheRead),
              let cacheWrite = normalizedPiTokenCount(usage.cacheWrite) else {
            return nil
        }
        guard self == .gjc else {
            guard let reasoning = normalizedPiTokenCount(
                usage.reasoning ?? usage.reasoningTokens) else {
                return nil
            }
            return PiTokenCounts(
                input: input,
                output: output,
                cacheRead: cacheRead,
                cacheWrite: cacheWrite,
                reasoning: reasoning)
        }
        guard let reasoning = normalizedPiTokenCount(usage.reasoningTokens) else {
            return nil
        }
        return PiTokenCounts(
            input: input,
            output: max(0, output - reasoning),
            cacheRead: cacheRead,
            cacheWrite: cacheWrite,
            reasoning: reasoning)
    }
}

private func normalizedPiTokenCount(_ value: Int?) -> Int? {
    let value = max(0, value ?? 0)
    return value <= 1_000_000_000_000 ? value : nil
}

private struct PiSessionContext {
    var id: String
    var cwd: String?
}

private struct PiTokenCounts {
    let input: Int
    let output: Int
    let cacheRead: Int
    let cacheWrite: Int
    let reasoning: Int
}

private struct PiEntry: Decodable {
    let type: String?
    let id: String?
    let timestamp: String?
    let cwd: String?
    let name: String?
    let message: PiMessage?

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
        message = try? container.decodeIfPresent(PiMessage.self, forKey: .message)
    }
}

private struct PiMessage: Decodable {
    let role: String?
    let toolName: String?
    let model: String?
    let provider: String?
    let responseID: String?
    let usage: PiUsage?
    let details: PiDetails?

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
        usage = try? container.decodeIfPresent(PiUsage.self, forKey: .usage)
        details = try? container.decodeIfPresent(PiDetails.self, forKey: .details)
    }
}

private struct PiDetails: Decodable {
    let usage: PiUsage?

    enum CodingKeys: String, CodingKey {
        case usage
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        usage = try? container.decodeIfPresent(PiUsage.self, forKey: .usage)
    }
}

private struct PiUsage: Decodable {
    let input: Int?
    let output: Int?
    let cacheRead: Int?
    let cacheWrite: Int?
    let reasoning: Int?
    let reasoningTokens: Int?
    let cost: PiCost?

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
        cost = try? container.decodeIfPresent(PiCost.self, forKey: .cost)
    }
}

private struct PiCost: Decodable {
    let total: Double?

    enum CodingKeys: String, CodingKey {
        case total
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        total = try? container.decodeIfPresent(Double.self, forKey: .total)
    }
}

private func piSubagentName(from value: String?) -> String? {
    guard var name = value?.nilIfBlank,
          name.hasPrefix("subagent-") else {
        return nil
    }
    name.removeFirst("subagent-".count)
    if let agentName = piAgentName(fromGeneratedSuffix: name) {
        return agentName
    }
    if let index = name.lastIndex(of: "-"),
       name[name.index(after: index)...].allSatisfy(\.isNumber) {
        name = String(name[..<index])
        return piAgentName(fromGeneratedSuffix: name)
    }
    return nil
}

private func piAgentName(fromGeneratedSuffix name: String) -> String? {
    if name.count > 36 {
        let uuidStart = name.index(name.endIndex, offsetBy: -36)
        let separator = name.index(before: uuidStart)
        let generatedID = String(name[uuidStart...])
        if name[separator] == "-",
           UUID(uuidString: generatedID) != nil {
            return String(name[..<separator]).nilIfBlank
        }
    }
    guard let separator = name.lastIndex(of: "-") else { return nil }
    let generatedID = String(name[name.index(after: separator)...])
    let agentName = String(name[..<separator])
    let isShortID = generatedID.count == 8 && generatedID.allSatisfy(\.isHexDigit)
    return isShortID ? agentName.nilIfBlank : nil
}

private extension String {
    var nilIfBlank: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
