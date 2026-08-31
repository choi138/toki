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
            findFiles(in: root, withExtension: "jsonl", modifiedAfter: startDate).map { file in
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
            var fingerprintOccurrences: [String: Int] = [:]

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
                guard tokens.total > 0 else { continue }

                let sessionID = nonemptyQwenValue(entry.sessionID) ?? pathIdentity.sessionID
                let model = normalizedModelID(entry.model)
                let fingerprint = qwenEventFingerprint(
                    timestamp: timestamp,
                    model: model,
                    tokens: tokens)
                let occurrence = fingerprintOccurrences[fingerprint, default: 0]
                fingerprintOccurrences[fingerprint] = occurrence + 1
                let namespace = [pathIdentity.project, sessionID]
                    .compactMap { $0 }
                    .joined(separator: ":")
                let key = "\(namespace):\(fingerprint):\(occurrence)"
                eventsByKey[key] = QwenUsageEvent(
                    timestamp: timestamp,
                    model: model,
                    sessionID: sessionID,
                    projectName: pathIdentity.project,
                    streamID: namespace,
                    tokens: tokens,
                    dedupKey: key)
            }
        }

        let events = eventsByKey.values.sorted(by: qwenEventSort)
        var result = RawTokenUsage()
        var activityEvents: [ActivityTimeEvent<String>] = []

        for event in events {
            guard let totalTokens = result.accumulateTokenCounts(
                input: event.tokens.input,
                output: event.tokens.output,
                cacheRead: event.tokens.cacheRead,
                reasoning: event.tokens.reasoning) else {
                continue
            }
            result.accumulatePerModelUsage(
                model: event.model,
                source: sourceName,
                totalTokens: totalTokens)
            result.recordTokenEvent(
                timestamp: event.timestamp,
                source: sourceName,
                model: event.model,
                provider: inferredUsageProvider(from: event.model),
                inputTokens: event.tokens.input,
                outputTokens: event.tokens.output,
                cacheReadTokens: event.tokens.cacheRead,
                reasoningTokens: event.tokens.reasoning,
                costIsKnown: false,
                attribution: UsageAttribution(
                    projectName: event.projectName,
                    sessionID: event.sessionID,
                    quality: event.projectName == nil ? .unknown : .inferred))
            activityEvents.append(
                ActivityTimeEvent(
                    streamID: event.streamID,
                    timestamp: event.timestamp,
                    key: UsageModelGrouping.groupingKey(for: event.model)))
        }

        result.mergeActivityEvents(
            activityEvents,
            source: sourceName,
            clippingEndDate: endDate)
        return result
    }
}

private struct QwenSession {
    let streamID: String
    let lines: [String]
    let fallbackDate: Date?
}

private struct QwenLine: Decodable {
    let type: String?
    let model: String?
    let timestamp: String?
    let sessionID: String?
    let usageMetadata: QwenUsageMetadata?

    enum CodingKeys: String, CodingKey {
        case type, model, timestamp, usageMetadata
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
        input = prompt - min(prompt, cached)
        output = max(0, metadata.candidatesTokenCount ?? 0)
        cacheRead = min(prompt, cached)
        reasoning = max(0, metadata.thoughtsTokenCount ?? 0)
    }

    var total: Int {
        checkedTokenTotal(input, output, cacheRead, reasoning) ?? 0
    }
}

private struct QwenUsageEvent {
    let timestamp: Date
    let model: String?
    let sessionID: String
    let projectName: String?
    let streamID: String
    let tokens: QwenTokenCounts
    let dedupKey: String
}

private func qwenEventFingerprint(
    timestamp: Date,
    model: String?,
    tokens: QwenTokenCounts) -> String {
    [
        String(timestamp.timeIntervalSince1970),
        model ?? "unknown",
        String(tokens.input),
        String(tokens.output),
        String(tokens.cacheRead),
        String(tokens.reasoning),
    ].joined(separator: ":")
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
