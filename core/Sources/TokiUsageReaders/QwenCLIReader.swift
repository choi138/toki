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
        let sessions = projectRoots.flatMap { root in
            findFiles(in: root, withExtension: "jsonl")
                .sorted { $0.path < $1.path }
                .map { file in
                    QwenSession(
                        streamID: file.path,
                        lines: readJSONLLines(at: file),
                        fallbackDate: qwenFileModificationDate(file))
                }
        }
        return Self.usage(from: sessions, from: startDate, to: endDate)
    }

    static func usage(
        fromJSONLLines lines: [String],
        streamID: String,
        from startDate: Date,
        to endDate: Date) -> RawTokenUsage {
        usage(
            from: [QwenSession(streamID: streamID, lines: lines, fallbackDate: nil)],
            from: startDate,
            to: endDate)
    }

    static func usage(
        fromJSONLSessions sessions: [(streamID: String, lines: [String])],
        from startDate: Date,
        to endDate: Date) -> RawTokenUsage {
        usage(
            from: sessions.map {
                QwenSession(streamID: $0.streamID, lines: $0.lines, fallbackDate: nil)
            },
            from: startDate,
            to: endDate)
    }

    private static func usage(
        from sessions: [QwenSession],
        from startDate: Date,
        to endDate: Date) -> RawTokenUsage {
        let decoder = JSONDecoder()
        var eventsByKey: [String: QwenUsageEvent] = [:]

        for session in sessions {
            let pathIdentity = qwenPathIdentity(from: session.streamID)
            var contentOccurrences: [String: Int] = [:]

            for line in session.lines {
                guard let data = line.data(using: .utf8),
                      let entry = try? decoder.decode(QwenLine.self, from: data),
                      entry.type == "assistant",
                      let metadata = entry.usageMetadata,
                      let timestamp = entry.timestamp.flatMap(DateParser.parse) ?? session.fallbackDate,
                      timestamp >= startDate,
                      timestamp < endDate else {
                    continue
                }

                let tokens = QwenTokenCounts(metadata: metadata)
                guard let totalTokens = tokens.total, totalTokens > 0 else { continue }

                let sessionID = nonemptyQwenValue(entry.sessionID) ?? pathIdentity.sessionID
                let model = normalizedModelID(entry.model)
                let projectPath = nonemptyQwenValue(entry.cwd)
                let recordIdentity: String
                if let uuid = nonemptyQwenValue(entry.uuid) {
                    recordIdentity = "uuid:\(uuid)"
                } else {
                    let contentIdentity = [
                        String(timestamp.timeIntervalSince1970.bitPattern),
                        "\(model?.utf8.count ?? 0):\(model ?? "")",
                        "\(projectPath?.utf8.count ?? 0):\(projectPath ?? pathIdentity.project ?? "")",
                        String(tokens.input),
                        String(tokens.output),
                        String(tokens.cacheRead),
                        String(tokens.reasoning),
                    ].joined(separator: "|")
                    let occurrence = contentOccurrences[contentIdentity, default: 0]
                    contentOccurrences[contentIdentity] = occurrence + 1
                    recordIdentity = "content:\(contentIdentity)|occurrence:\(occurrence)"
                }
                let key = "\(sessionID):\(recordIdentity)"
                let event = QwenUsageEvent(
                    timestamp: timestamp,
                    model: model,
                    sessionID: sessionID,
                    projectPath: projectPath,
                    fallbackProjectName: pathIdentity.project,
                    tokens: tokens,
                    totalTokens: totalTokens,
                    dedupKey: key)
                if let existing = eventsByKey[key], !event.shouldReplace(existing) {
                    continue
                }
                eventsByKey[key] = event
            }
        }

        return qwenRawUsage(
            events: eventsByKey.values.sorted(by: qwenEventSort),
            clippingEndDate: endDate)
    }
}

private struct QwenSession {
    let streamID: String
    let lines: [String]
    let fallbackDate: Date?
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

private func qwenPathIdentity(from path: String) -> (project: String?, sessionID: String) {
    let url = URL(fileURLWithPath: path)
    let components = url.pathComponents
    var project: String?
    if components.count >= 4 {
        for index in 0...(components.count - 4) where
            components[index] == "projects" && components[index + 2] == "chats" {
            project = nonemptyQwenValue(components[index + 1])
        }
    }
    let fileSessionID = nonemptyQwenValue(url.deletingPathExtension().lastPathComponent) ?? "unknown"
    let sessionID = [project, fileSessionID].compactMap { $0 }.joined(separator: "-")
    return (project, sessionID.isEmpty ? "unknown" : sessionID)
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

private func qwenFileModificationDate(_ url: URL) -> Date? {
    (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
}
