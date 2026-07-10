import Foundation

struct CodexModelEntry: Decodable {
    let type: String?
    let payload: Payload?

    struct Payload: Decodable {
        let model: String?
        let cwd: String?
        let workdir: String?
        let workingDirectory: String?
        let workingDirectorySnake: String?
        let projectPath: String?
        let projectPathSnake: String?

        var resolvedProjectPath: String? {
            firstNonEmpty(
                cwd,
                workingDirectory,
                workingDirectorySnake,
                workdir,
                projectPath,
                projectPathSnake)
        }

        enum CodingKeys: String, CodingKey {
            case model
            case cwd
            case workdir
            case workingDirectory
            case workingDirectorySnake = "working_directory"
            case projectPath
            case projectPathSnake = "project_path"
        }
    }
}

struct CodexSession {
    let rolloutPath: String
    let model: String?
    let agentKind: WorkTimeAgentKind
    let hasSourceAttribution: Bool
    let projectPath: String?
    let projectAttributionQuality: AttributionQuality

    init(
        rolloutPath: String,
        model: String?,
        agentKind: WorkTimeAgentKind = .main,
        hasSourceAttribution: Bool = true,
        projectPath: String? = nil,
        projectAttributionQuality: AttributionQuality = .unknown) {
        self.rolloutPath = rolloutPath
        self.model = model
        self.agentKind = agentKind
        self.hasSourceAttribution = hasSourceAttribution
        self.projectPath = projectPath?.trimmedNonEmpty
        self.projectAttributionQuality = self.projectPath == nil ? .unknown : projectAttributionQuality
    }

    var attribution: UsageAttribution {
        UsageAttribution(
            projectPath: projectPath,
            sessionID: usageSessionID(fromPath: rolloutPath),
            quality: projectAttributionQuality)
    }
}

struct CodexSessionAttribution {
    let model: String?
    let agentKind: WorkTimeAgentKind
    let hasSourceAttribution: Bool
    let projectPath: String?
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
        let cwd: String?
        let workdir: String?
        let workingDirectory: String?
        let workingDirectorySnake: String?
        let projectPath: String?
        let projectPathSnake: String?

        var resolvedProjectPath: String? {
            firstNonEmpty(
                cwd,
                workingDirectory,
                workingDirectorySnake,
                workdir,
                projectPath,
                projectPathSnake)
        }

        enum CodingKeys: String, CodingKey {
            case source
            case cwd
            case workdir
            case workingDirectory
            case workingDirectorySnake = "working_directory"
            case projectPath
            case projectPathSnake = "project_path"
        }
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

    var tokenCount: CodexTokenCount? {
        guard type == "event_msg", payload?.type == "token_count" else {
            return nil
        }
        return payload?.info?.tokenCount
    }

    struct Payload: Decodable {
        let type: String?
        let info: Info?

        struct Info: Decodable {
            let totalTokenUsage: CodexTokenUsageCounters?
            let lastTokenUsage: CodexTokenUsageCounters?

            enum CodingKeys: String, CodingKey {
                case totalTokenUsage = "total_token_usage"
                case lastTokenUsage = "last_token_usage"
            }

            var tokenCount: CodexTokenCount? {
                CodexTokenCount(
                    totalUsage: totalTokenUsage,
                    lastUsage: lastTokenUsage)
            }
        }
    }
}

struct CodexTokenCount {
    let totalSnapshot: CodexUsageSnapshot
    let delta: CodexTokenDelta

    init?(
        totalUsage: CodexTokenUsageCounters?,
        lastUsage: CodexTokenUsageCounters?) {
        guard let totalUsage else { return nil }

        totalSnapshot = totalUsage.snapshot
        delta = lastUsage.map { .explicit($0.normalizedUsage) } ?? .cumulative
    }

    func usage(since previousSnapshot: CodexUsageSnapshot?) -> RawTokenUsage {
        delta.usage(currentSnapshot: totalSnapshot, previousSnapshot: previousSnapshot)
    }
}

enum CodexTokenDelta {
    case explicit(RawTokenUsage)
    case cumulative

    func usage(
        currentSnapshot: CodexUsageSnapshot,
        previousSnapshot: CodexUsageSnapshot?) -> RawTokenUsage {
        switch self {
        case let .explicit(usage):
            usage
        case .cumulative:
            currentSnapshot.delta(since: previousSnapshot).normalizedUsage
        }
    }
}

struct CodexTokenUsageCounters: Decodable {
    let inputTokens: Int
    let cachedInputTokens: Int
    let outputTokens: Int
    let reasoningOutputTokens: Int

    enum CodingKeys: String, CodingKey {
        case inputTokens = "input_tokens"
        case cachedInputTokens = "cached_input_tokens"
        case outputTokens = "output_tokens"
        case reasoningOutputTokens = "reasoning_output_tokens"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        inputTokens = try container.decodeIfPresent(Int.self, forKey: .inputTokens) ?? 0
        cachedInputTokens = try container.decodeIfPresent(Int.self, forKey: .cachedInputTokens) ?? 0
        outputTokens = try container.decodeIfPresent(Int.self, forKey: .outputTokens) ?? 0
        reasoningOutputTokens = try container.decodeIfPresent(Int.self, forKey: .reasoningOutputTokens) ?? 0
    }

    var snapshot: CodexUsageSnapshot {
        CodexUsageSnapshot(
            inputTokens: inputTokens,
            cachedInputTokens: cachedInputTokens,
            outputTokens: outputTokens,
            reasoningOutputTokens: reasoningOutputTokens)
    }

    var normalizedUsage: RawTokenUsage {
        snapshot.normalizedUsage
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
    let tokenCount: CodexTokenCount
    let fileOrder: Int

    var snapshot: CodexUsageSnapshot {
        tokenCount.totalSnapshot
    }

    func usage(since previousSnapshot: CodexUsageSnapshot?) -> RawTokenUsage {
        tokenCount.usage(since: previousSnapshot)
    }
}

private func firstNonEmpty(_ values: String?...) -> String? {
    for value in values {
        if let trimmed = value?.trimmedNonEmpty {
            return trimmed
        }
    }
    return nil
}
