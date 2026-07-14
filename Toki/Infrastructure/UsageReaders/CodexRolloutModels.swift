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
    let upstreamSessionID: String

    init(
        rolloutPath: String,
        model: String?,
        agentKind: WorkTimeAgentKind = .main,
        hasSourceAttribution: Bool = true,
        projectPath: String? = nil,
        projectAttributionQuality: AttributionQuality = .unknown,
        upstreamSessionID: String? = nil) {
        self.rolloutPath = rolloutPath
        self.model = model
        self.agentKind = agentKind
        self.hasSourceAttribution = hasSourceAttribution
        self.projectPath = projectPath?.trimmedNonEmpty
        self.projectAttributionQuality = self.projectPath == nil ? .unknown : projectAttributionQuality
        self.upstreamSessionID = upstreamSessionID?.trimmedNonEmpty ?? usageSessionID(fromPath: rolloutPath)
    }

    var attribution: UsageAttribution {
        UsageAttribution(
            projectPath: projectPath,
            sessionID: upstreamSessionID,
            quality: projectAttributionQuality)
    }
}

struct CodexSessionAttribution {
    let model: String?
    let agentKind: WorkTimeAgentKind
    let hasSourceAttribution: Bool
    let projectPath: String?
    let upstreamSessionID: String?
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
        let id: String?
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
            case id
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
        let id: String?
        let forkedFromID: String?
        let source: ForkSource?
        let threadSource: String?
        let type: String?
        let turnID: String?
        let info: Info?

        var forkParentID: String? {
            forkedFromID?.trimmedNonEmpty ?? source?.subagent?.threadSpawn?.parentThreadID?.trimmedNonEmpty
        }

        enum CodingKeys: String, CodingKey {
            case id
            case forkedFromID = "forked_from_id"
            case source
            case threadSource = "thread_source"
            case type
            case turnID = "turn_id"
            case info
        }

        struct ForkSource: Decodable {
            let subagent: Subagent?

            enum CodingKeys: String, CodingKey {
                case subagent
            }

            init(from decoder: Decoder) throws {
                guard let container = try? decoder.container(keyedBy: CodingKeys.self) else {
                    subagent = nil
                    return
                }
                subagent = try? container.decodeIfPresent(Subagent.self, forKey: .subagent)
            }

            struct Subagent: Decodable {
                let threadSpawn: ThreadSpawn?

                enum CodingKeys: String, CodingKey {
                    case threadSpawn = "thread_spawn"
                }

                struct ThreadSpawn: Decodable {
                    let parentThreadID: String?

                    enum CodingKeys: String, CodingKey {
                        case parentThreadID = "parent_thread_id"
                    }
                }
            }
        }

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
        delta = lastUsage.map { .explicit($0.snapshot) } ?? .cumulative
    }

    func usage(since previousSnapshot: CodexUsageSnapshot?) -> RawTokenUsage {
        // `last_token_usage` is an event increment, but Codex can repeat it beside an
        // unchanged cumulative total. Use it only for the first row or a genuine reset;
        // a monotonic cumulative advance always contributes its exact difference once.
        guard let previousSnapshot else {
            return delta.usage(currentSnapshot: totalSnapshot, previousSnapshot: nil)
        }
        guard totalSnapshot != previousSnapshot else { return RawTokenUsage() }
        if totalSnapshot.isMonotonicAdvance(from: previousSnapshot) {
            return totalSnapshot.delta(since: previousSnapshot).normalizedUsage
        }
        if isStaleRegression(from: previousSnapshot) {
            return RawTokenUsage()
        }
        if case .cumulative = delta {
            return RawTokenUsage()
        }
        return delta.usage(currentSnapshot: totalSnapshot, previousSnapshot: previousSnapshot)
    }

    func nextBaseline(after previousSnapshot: CodexUsageSnapshot?) -> CodexUsageSnapshot {
        guard let previousSnapshot else { return totalSnapshot }
        guard !totalSnapshot.isZero,
              !isStaleRegression(from: previousSnapshot) else {
            return previousSnapshot
        }
        return totalSnapshot
    }

    private func isStaleRegression(from previousSnapshot: CodexUsageSnapshot) -> Bool {
        guard !totalSnapshot.isMonotonicAdvance(from: previousSnapshot),
              case let .explicit(lastSnapshot) = delta else {
            return false
        }
        return totalSnapshot.looksLikeStaleRegression(
            from: previousSnapshot,
            lastSnapshot: lastSnapshot)
    }
}

enum CodexTokenDelta {
    case explicit(CodexUsageSnapshot)
    case cumulative

    func usage(
        currentSnapshot: CodexUsageSnapshot,
        previousSnapshot: CodexUsageSnapshot?) -> RawTokenUsage {
        switch self {
        case let .explicit(snapshot):
            snapshot.normalizedUsage
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
    let totalTokens: Int?

    enum CodingKeys: String, CodingKey {
        case inputTokens = "input_tokens"
        case cachedInputTokens = "cached_input_tokens"
        case outputTokens = "output_tokens"
        case reasoningOutputTokens = "reasoning_output_tokens"
        case totalTokens = "total_tokens"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        inputTokens = try container.decodeIfPresent(Int.self, forKey: .inputTokens) ?? 0
        cachedInputTokens = try container.decodeIfPresent(Int.self, forKey: .cachedInputTokens) ?? 0
        outputTokens = try container.decodeIfPresent(Int.self, forKey: .outputTokens) ?? 0
        reasoningOutputTokens = try container.decodeIfPresent(Int.self, forKey: .reasoningOutputTokens) ?? 0
        totalTokens = try container.decodeIfPresent(Int.self, forKey: .totalTokens)
    }

    var snapshot: CodexUsageSnapshot {
        CodexUsageSnapshot(
            inputTokens: inputTokens,
            cachedInputTokens: cachedInputTokens,
            outputTokens: outputTokens,
            reasoningOutputTokens: reasoningOutputTokens,
            reportedTotalTokens: totalTokens)
    }

    var normalizedUsage: RawTokenUsage {
        snapshot.normalizedUsage
    }
}

struct CodexUsageSnapshot: Equatable {
    let inputTokens: Int
    let cachedInputTokens: Int
    let outputTokens: Int
    let reasoningOutputTokens: Int
    let reportedTotalTokens: Int?

    static func == (lhs: CodexUsageSnapshot, rhs: CodexUsageSnapshot) -> Bool {
        lhs.inputTokens == rhs.inputTokens
            && lhs.cachedInputTokens == rhs.cachedInputTokens
            && lhs.outputTokens == rhs.outputTokens
            && lhs.reasoningOutputTokens == rhs.reasoningOutputTokens
    }

    var isZero: Bool {
        inputTokens == 0
            && cachedInputTokens == 0
            && outputTokens == 0
            && reasoningOutputTokens == 0
    }

    func isInheritedReplay(of baseline: CodexUsageSnapshot) -> Bool {
        if let reportedTotalTokens,
           let baselineTotal = baseline.reportedTotalTokens,
           reportedTotalTokens >= 0,
           baselineTotal >= 0,
           reportedTotalTokens <= baselineTotal {
            return true
        }
        return isWithin(baseline)
    }

    func isWithin(_ baseline: CodexUsageSnapshot) -> Bool {
        inputTokens <= baseline.inputTokens
            && cachedInputTokens <= baseline.cachedInputTokens
            && outputTokens <= baseline.outputTokens
            && reasoningOutputTokens <= baseline.reasoningOutputTokens
    }

    func isMonotonicAdvance(from previous: CodexUsageSnapshot) -> Bool {
        inputTokens >= previous.inputTokens
            && cachedInputTokens >= previous.cachedInputTokens
            && outputTokens >= previous.outputTokens
            && reasoningOutputTokens >= previous.reasoningOutputTokens
    }

    func looksLikeStaleRegression(
        from previous: CodexUsageSnapshot,
        lastSnapshot: CodexUsageSnapshot) -> Bool {
        let previousTotal = previous.aggregateCounterTotal
        let currentTotal = aggregateCounterTotal
        let lastTotal = lastSnapshot.aggregateCounterTotal
        guard previousTotal > 0, currentTotal > 0, lastTotal > 0 else { return false }

        let previousValue = Double(previousTotal)
        let currentValue = Double(currentTotal)
        let lastValue = Double(lastTotal)
        return currentValue >= previousValue * 0.98
            || currentValue + lastValue * 2 >= previousValue
    }

    private var aggregateCounterTotal: Int {
        inputTokens + outputTokens + cachedInputTokens + reasoningOutputTokens
    }

    func delta(since previous: CodexUsageSnapshot?) -> CodexUsageSnapshot {
        guard let previous else { return self }

        return CodexUsageSnapshot(
            inputTokens: max(0, inputTokens - previous.inputTokens),
            cachedInputTokens: max(0, cachedInputTokens - previous.cachedInputTokens),
            outputTokens: max(0, outputTokens - previous.outputTokens),
            reasoningOutputTokens: max(0, reasoningOutputTokens - previous.reasoningOutputTokens),
            reportedTotalTokens: nil)
    }

    var normalizedUsage: RawTokenUsage {
        let uncachedInput = max(0, inputTokens - cachedInputTokens)
        // Codex raw output includes reasoning. Keep Toki's buckets disjoint so
        // non-reasoning output + reasoning reconstructs the provider output total.
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
