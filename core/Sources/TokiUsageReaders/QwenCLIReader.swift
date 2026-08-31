import Foundation
import TokiUsageCore

public struct QwenCLIReader: TokenReader {
    public static let sourceName = "Qwen CLI"

    public let name = Self.sourceName
    private let projectRoots: [URL]

    public init(projectRoots: [URL]? = nil) {
        self.projectRoots = projectRoots ?? LocalUsageReaderPaths().qwenProjects
    }

    public func readUsage(from startDate: Date, to endDate: Date) async throws -> RawTokenUsage {
        var sessions: [QwenSession] = []
        for root in projectRoots {
            try Task.checkCancellation()
            try sessions.append(contentsOf: findFilesThrowing(in: root, withExtension: "jsonl")
                .sorted { $0.path < $1.path }
                .map { file in
                    QwenSession(
                        streamID: file.path,
                        lineSource: .file(file))
                })
        }
        return try Self.usage(from: sessions, from: startDate, to: endDate)
    }

    static func usage(
        fromJSONLLines lines: [String],
        streamID: String,
        from startDate: Date,
        to endDate: Date) throws -> RawTokenUsage {
        try usage(
            from: [QwenSession(streamID: streamID, lineSource: .lines(lines))],
            from: startDate,
            to: endDate)
    }

    static func usage(
        fromJSONLSessions sessions: [(streamID: String, lines: [String])],
        from startDate: Date,
        to endDate: Date) throws -> RawTokenUsage {
        try usage(
            from: sessions.map {
                QwenSession(streamID: $0.streamID, lineSource: .lines($0.lines))
            },
            from: startDate,
            to: endDate)
    }

    private static func usage(
        from sessions: [QwenSession],
        from startDate: Date,
        to endDate: Date) throws -> RawTokenUsage {
        try Task.checkCancellation()
        let decoder = JSONDecoder()
        var eventsByKey: [String: QwenUsageEvent] = [:]
        var replicaBuckets: [String: [String: QwenUsageEvent]] = [:]

        for session in sessions {
            let pathIdentity = qwenPathIdentity(from: session.streamID)
            var contentOccurrences: [String: Int] = [:]

            try session.lineSource.consume { line in
                guard let data = line.data(using: .utf8),
                      let entry = try? decoder.decode(QwenLine.self, from: data),
                      entry.type == "assistant",
                      let metadata = entry.usageMetadata,
                      let timestamp = entry.timestamp.flatMap(DateParser.parse) else {
                    return
                }

                let tokens = QwenTokenCounts(metadata: metadata)
                guard let totalTokens = tokens.total, totalTokens > 0 else { return }

                let model = normalizedModelID(entry.model)
                let projectPath = nonemptyQwenValue(entry.cwd)
                let projectIdentity = projectPath ?? pathIdentity.project
                let sessionLabel = nonemptyQwenValue(entry.sessionID) ?? pathIdentity.sessionLabel
                let sessionID = qwenSessionScope(
                    project: projectIdentity,
                    sessionLabel: sessionLabel)
                let recordIdentity: String
                let replicaBucketKey: String
                if let uuid = nonemptyQwenValue(entry.uuid) {
                    recordIdentity = "uuid:\(uuid)"
                    replicaBucketKey = qwenUUIDBucketKey(
                        uuid: uuid,
                        fallbackProject: pathIdentity.project)
                } else {
                    let contentIdentity = [
                        String(timestamp.timeIntervalSince1970.bitPattern),
                        "\(model?.utf8.count ?? 0):\(model ?? "")",
                        String(tokens.input),
                        String(tokens.output),
                        String(tokens.cacheRead),
                        String(tokens.reasoning),
                    ].joined(separator: "|")
                    let occurrence = contentOccurrences[contentIdentity, default: 0]
                    contentOccurrences[contentIdentity] = occurrence + 1
                    recordIdentity = "content:\(contentIdentity)|occurrence:\(occurrence)"
                    replicaBucketKey = qwenContentBucketKey(
                        contentIdentity: contentIdentity,
                        occurrence: occurrence,
                        fallbackProject: pathIdentity.project,
                        sessionLabel: sessionLabel)
                }
                let key = if recordIdentity.hasPrefix("uuid:"),
                             let projectIdentity {
                    "project:\(projectIdentity.utf8.count):\(projectIdentity)|\(recordIdentity)"
                } else {
                    "\(sessionID):\(recordIdentity)"
                }
                let event = QwenUsageEvent(
                    timestamp: timestamp,
                    model: model,
                    sessionID: sessionID,
                    sessionLabel: sessionLabel,
                    projectPath: projectPath,
                    fallbackProjectName: pathIdentity.project,
                    tokens: tokens,
                    totalTokens: totalTokens,
                    dedupKey: key)
                storeQwenReplica(
                    event,
                    bucketKey: replicaBucketKey,
                    replicaKey: qwenReplicaKey(projectPath: projectPath),
                    in: &replicaBuckets)
            }
        }

        try Task.checkCancellation()
        resolveQwenReplicas(replicaBuckets, into: &eventsByKey)

        return qwenRawUsage(
            events: eventsByKey.values
                .filter { $0.timestamp >= startDate && $0.timestamp < endDate }
                .sorted(by: qwenEventSort),
            clippingEndDate: endDate)
    }
}

private struct QwenSession {
    let streamID: String
    let lineSource: JSONLLineSource
}

private struct QwenLine: Decodable {
    let uuid: String?
    let type: String?
    let model: String?
    let timestamp: String?
    let sessionID: String?
    let cwd: String?
    let usageMetadata: QwenUsageMetadata?

    enum CodingKeys: String, CodingKey {
        case uuid, type, model, timestamp, cwd, usageMetadata
        case sessionID = "sessionId"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        type = try container.decodeIfPresent(String.self, forKey: .type)
        uuid = try? container.decodeIfPresent(String.self, forKey: .uuid)
        model = try? container.decodeIfPresent(String.self, forKey: .model)
        timestamp = try? container.decodeIfPresent(String.self, forKey: .timestamp)
        sessionID = try? container.decodeIfPresent(String.self, forKey: .sessionID)
        cwd = try? container.decodeIfPresent(String.self, forKey: .cwd)
        usageMetadata = try container.decodeIfPresent(
            QwenUsageMetadata.self,
            forKey: .usageMetadata)
    }
}

private struct QwenUsageMetadata: Decodable {
    let promptTokenCount: Int?
    let candidatesTokenCount: Int?
    let thoughtsTokenCount: Int?
    let cachedContentTokenCount: Int?
}

private struct QwenTokenCounts {
    let input: Int
    let output: Int
    let cacheRead: Int
    let reasoning: Int

    init(metadata: QwenUsageMetadata) {
        let prompt = max(0, metadata.promptTokenCount ?? 0)
        let cached = max(0, metadata.cachedContentTokenCount ?? 0)
        input = max(0, prompt - cached)
        output = max(0, metadata.candidatesTokenCount ?? 0)
        cacheRead = cached
        reasoning = max(0, metadata.thoughtsTokenCount ?? 0)
    }

    var total: Int? {
        checkedTokenTotal(input, output, cacheRead, reasoning)
    }
}

private struct QwenUsageEvent {
    let timestamp: Date
    let model: String?
    let sessionID: String
    let sessionLabel: String
    let projectPath: String?
    let fallbackProjectName: String?
    let tokens: QwenTokenCounts
    let totalTokens: Int
    let dedupKey: String

    func shouldReplace(_ existing: QwenUsageEvent) -> Bool {
        if totalTokens != existing.totalTokens {
            return totalTokens > existing.totalTokens
        }
        if timestamp != existing.timestamp {
            return timestamp > existing.timestamp
        }
        return conflictRank > existing.conflictRank
    }

    func usingAttribution(from event: QwenUsageEvent) -> QwenUsageEvent {
        QwenUsageEvent(
            timestamp: timestamp,
            model: model,
            sessionID: event.sessionID,
            sessionLabel: event.sessionLabel,
            projectPath: event.projectPath,
            fallbackProjectName: event.fallbackProjectName,
            tokens: tokens,
            totalTokens: totalTokens,
            dedupKey: event.dedupKey)
    }

    private var conflictRank: String {
        [
            model ?? "",
            projectPath ?? "",
            fallbackProjectName ?? "",
            String(tokens.input),
            String(tokens.output),
            String(tokens.cacheRead),
            String(tokens.reasoning),
        ].joined(separator: "|")
    }
}

private func qwenRawUsage(
    events: [QwenUsageEvent],
    clippingEndDate: Date) -> RawTokenUsage {
    var result = RawTokenUsage()
    var activityEvents: [ActivityTimeEvent<String>] = []

    for event in events {
        guard let accumulatedTotal = checkedTokenTotal(
            result.inputTokens,
            result.outputTokens,
            result.cacheReadTokens,
            result.cacheWriteTokens,
            result.reasoningTokens,
            result.unclassifiedTokens),
            checkedTokenTotal(accumulatedTotal, event.totalTokens) != nil else {
            continue
        }
        result.inputTokens += event.tokens.input
        result.outputTokens += event.tokens.output
        result.cacheReadTokens += event.tokens.cacheRead
        result.reasoningTokens += event.tokens.reasoning
        result.accumulatePerModelUsage(
            model: event.model,
            source: QwenCLIReader.sourceName,
            totalTokens: event.totalTokens)
        result.recordTokenEvent(
            timestamp: event.timestamp,
            source: QwenCLIReader.sourceName,
            model: event.model,
            provider: inferredUsageProvider(from: event.model),
            inputTokens: event.tokens.input,
            outputTokens: event.tokens.output,
            cacheReadTokens: event.tokens.cacheRead,
            reasoningTokens: event.tokens.reasoning,
            costIsKnown: false,
            attribution: UsageAttribution(
                projectPath: event.projectPath,
                projectName: event.projectPath == nil ? event.fallbackProjectName : nil,
                sessionID: event.sessionID,
                sessionLabel: event.sessionLabel,
                quality: event.projectPath != nil
                    ? .exact
                    : (event.fallbackProjectName == nil ? .unknown : .inferred)))
        activityEvents.append(
            ActivityTimeEvent(
                streamID: event.sessionID,
                timestamp: event.timestamp,
                key: UsageModelGrouping.groupingKey(for: event.model)))
    }

    result.mergeActivityEvents(
        activityEvents,
        source: QwenCLIReader.sourceName,
        clippingEndDate: clippingEndDate)
    return result
}

private func qwenPathIdentity(from path: String) -> (project: String?, sessionLabel: String) {
    let url = URL(fileURLWithPath: path)
    let components = url.pathComponents
    var project: String?
    if components.count >= 4 {
        for index in 0...(components.count - 4) where
            components[index] == "projects" && components[index + 2] == "chats" {
            project = nonemptyQwenValue(components[index + 1])
        }
    }
    let sessionLabel = nonemptyQwenValue(url.deletingPathExtension().lastPathComponent) ?? "unknown"
    return (project, sessionLabel)
}

private func qwenSessionScope(project: String?, sessionLabel: String) -> String {
    [
        "\(project?.utf8.count ?? 0):\(project ?? "")",
        "\(sessionLabel.utf8.count):\(sessionLabel)",
    ].joined(separator: "|")
}

private func qwenUUIDBucketKey(uuid: String, fallbackProject: String?) -> String {
    [
        "\(fallbackProject?.utf8.count ?? 0):\(fallbackProject ?? "")",
        "\(uuid.utf8.count):\(uuid)",
    ].joined(separator: "|")
}

private func qwenContentBucketKey(
    contentIdentity: String,
    occurrence: Int,
    fallbackProject: String?,
    sessionLabel: String) -> String {
    [
        "\(fallbackProject?.utf8.count ?? 0):\(fallbackProject ?? "")",
        "\(sessionLabel.utf8.count):\(sessionLabel)",
        "\(contentIdentity.utf8.count):\(contentIdentity)",
        "occurrence:\(occurrence)",
    ].joined(separator: "|")
}

private func qwenReplicaKey(projectPath: String?) -> String {
    guard let projectPath else { return "fallback" }
    return "cwd:\(projectPath.utf8.count):\(projectPath)"
}

private func storeQwenEvent(
    _ event: QwenUsageEvent,
    in eventsByKey: inout [String: QwenUsageEvent]) {
    if let existing = eventsByKey[event.dedupKey], !event.shouldReplace(existing) {
        return
    }
    eventsByKey[event.dedupKey] = event
}

private func storeQwenReplica(
    _ event: QwenUsageEvent,
    bucketKey: String,
    replicaKey: String,
    in buckets: inout [String: [String: QwenUsageEvent]]) {
    var replicas = buckets[bucketKey, default: [:]]
    if let existing = replicas[replicaKey], !event.shouldReplace(existing) {
        return
    }
    replicas[replicaKey] = event
    buckets[bucketKey] = replicas
}

private func resolveQwenReplicas(
    _ buckets: [String: [String: QwenUsageEvent]],
    into eventsByKey: inout [String: QwenUsageEvent]) {
    for replicas in buckets.values {
        let exactReplicas = replicas.values.filter { $0.projectPath != nil }
        let fallbackReplica = replicas.values.first { $0.projectPath == nil }
        if exactReplicas.isEmpty {
            if let fallbackReplica {
                storeQwenEvent(fallbackReplica, in: &eventsByKey)
            }
        } else if exactReplicas.count == 1, let exactReplica = exactReplicas.first {
            let event = if let fallbackReplica, fallbackReplica.shouldReplace(exactReplica) {
                fallbackReplica.usingAttribution(from: exactReplica)
            } else {
                exactReplica
            }
            storeQwenEvent(event, in: &eventsByKey)
        } else {
            // A cwd-less replica is ambiguous once the same layout maps to multiple projects.
            for event in exactReplicas {
                storeQwenEvent(event, in: &eventsByKey)
            }
        }
    }
}

private func qwenEventSort(_ lhs: QwenUsageEvent, _ rhs: QwenUsageEvent) -> Bool {
    if lhs.timestamp != rhs.timestamp { return lhs.timestamp < rhs.timestamp }
    return lhs.dedupKey < rhs.dedupKey
}

private func nonemptyQwenValue(_ value: String?) -> String? {
    guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines),
          !value.isEmpty else {
        return nil
    }
    return value
}
