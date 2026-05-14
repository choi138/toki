import Foundation

struct CodexModelEntry: Decodable {
    let type: String?
    let payload: Payload?

    struct Payload: Decodable {
        let model: String?
    }
}

struct CodexSession {
    let rolloutPath: String
    let model: String?
    let agentKind: WorkTimeAgentKind
    let hasSourceAttribution: Bool

    init(
        rolloutPath: String,
        model: String?,
        agentKind: WorkTimeAgentKind = .main,
        hasSourceAttribution: Bool = true) {
        self.rolloutPath = rolloutPath
        self.model = model
        self.agentKind = agentKind
        self.hasSourceAttribution = hasSourceAttribution
    }
}

struct CodexSessionAttribution {
    let model: String?
    let agentKind: WorkTimeAgentKind
    let hasSourceAttribution: Bool
}

func codexAgentKind(fromSource source: String?) -> WorkTimeAgentKind {
    guard let source = source?.trimmingCharacters(in: .whitespacesAndNewlines),
          !source.isEmpty else {
        return .main
    }

    if source == "subagent" {
        return .subagent
    }

    guard let data = source.data(using: .utf8),
          let marker = try? JSONDecoder().decode(CodexSourceMarker.self, from: data) else {
        return .main
    }
    return marker.isSubagent ? .subagent : .main
}

struct CodexSessionMetaEntry: Decodable {
    let type: String?
    let payload: Payload?

    struct Payload: Decodable {
        let source: CodexSourceMarker?
    }
}

struct CodexSourceMarker: Decodable {
    let isSubagent: Bool

    init(from decoder: Decoder) throws {
        if let container = try? decoder.singleValueContainer(),
           let value = try? container.decode(String.self) {
            isSubagent = value == "subagent"
            return
        }

        guard let container = try? decoder.container(keyedBy: DynamicCodingKey.self),
              let subagentKey = DynamicCodingKey(stringValue: "subagent") else {
            isSubagent = false
            return
        }

        isSubagent = container.contains(subagentKey)
    }
}

struct DynamicCodingKey: CodingKey {
    let stringValue: String
    let intValue: Int?

    init?(stringValue: String) {
        self.stringValue = stringValue
        intValue = nil
    }

    init?(intValue: Int) {
        nil
    }
}

struct CodexRolloutEntry: Decodable {
    let timestamp: String?
    let type: String?
    let payload: Payload?

    var tokenSnapshot: CodexUsageSnapshot? {
        guard type == "event_msg",
              payload?.type == "token_count",
              let totalUsage = payload?.info?.totalTokenUsage else {
            return nil
        }

        return CodexUsageSnapshot(
            inputTokens: totalUsage.inputTokens ?? 0,
            cachedInputTokens: totalUsage.cachedInputTokens ?? 0,
            outputTokens: totalUsage.outputTokens ?? 0,
            reasoningOutputTokens: totalUsage.reasoningOutputTokens ?? 0)
    }

    struct Payload: Decodable {
        let type: String?
        let info: Info?

        struct Info: Decodable {
            let totalTokenUsage: TotalTokenUsage?

            enum CodingKeys: String, CodingKey {
                case totalTokenUsage = "total_token_usage"
            }
        }
    }
}

struct TotalTokenUsage: Decodable {
    let inputTokens: Int?
    let cachedInputTokens: Int?
    let outputTokens: Int?
    let reasoningOutputTokens: Int?

    enum CodingKeys: String, CodingKey {
        case inputTokens = "input_tokens"
        case cachedInputTokens = "cached_input_tokens"
        case outputTokens = "output_tokens"
        case reasoningOutputTokens = "reasoning_output_tokens"
    }
}

struct CodexUsageSnapshot {
    let inputTokens: Int
    let cachedInputTokens: Int
    let outputTokens: Int
    let reasoningOutputTokens: Int

    func delta(since previous: CodexUsageSnapshot?) -> CodexUsageSnapshot {
        guard let previous else { return self }

        return CodexUsageSnapshot(
            inputTokens: max(0, inputTokens - previous.inputTokens),
            cachedInputTokens: max(0, cachedInputTokens - previous.cachedInputTokens),
            outputTokens: max(0, outputTokens - previous.outputTokens),
            reasoningOutputTokens: max(0, reasoningOutputTokens - previous.reasoningOutputTokens))
    }

    var normalizedUsage: RawTokenUsage {
        let uncachedInput = max(0, inputTokens - cachedInputTokens)
        let nonReasoningOutput = max(0, outputTokens - reasoningOutputTokens)

        return RawTokenUsage(
            inputTokens: uncachedInput,
            outputTokens: nonReasoningOutput,
            cacheReadTokens: cachedInputTokens,
            reasoningTokens: reasoningOutputTokens)
    }
}

struct CodexTimedSnapshot {
    let date: Date
    let snapshot: CodexUsageSnapshot
    let fileOrder: Int
}
