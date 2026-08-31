import Foundation
import TokiUsageCore

struct PiCompatibleReader {
    let source: PiCompatibleSource
    let sessionRoots: [URL]

    func readUsage(from startDate: Date, to endDate: Date) -> RawTokenUsage {
        let files = discoveredFiles(modifiedAfter: startDate)
        let sessions = files.map { file in
            (
                streamID: file.path,
                lines: readJSONLLines(at: file))
        }
        return Self.usage(
            fromJSONLSessions: sessions,
            source: source,
            from: startDate,
            to: endDate)
    }

    static func usage(
        fromJSONLLines lines: [String],
        streamID: String,
        source: PiCompatibleSource,
        from startDate: Date,
        to endDate: Date) -> RawTokenUsage {
        usage(
            fromJSONLSessions: [(streamID: streamID, lines: lines)],
            source: source,
            from: startDate,
            to: endDate)
    }

    private func discoveredFiles(modifiedAfter startDate: Date) -> [URL] {
        var physicalPaths = Set<String>()
        var result: [URL] = []

        for root in sessionRoots {
            for file in findFiles(in: root, withExtension: "jsonl", modifiedAfter: startDate) {
                let physicalPath = file.resolvingSymlinksInPath().standardizedFileURL.path
                guard physicalPaths.insert(physicalPath).inserted else { continue }
                result.append(file)
            }
        }
        return result.sorted { $0.path < $1.path }
    }

    private static func usage(
        fromJSONLSessions sessions: [(streamID: String, lines: [String])],
        source: PiCompatibleSource,
        from startDate: Date,
        to endDate: Date) -> RawTokenUsage {
        var result = RawTokenUsage()
        var activityEvents: [ActivityTimeEvent<String>] = []
        var dedupKeys = Set<String>()

        for session in sessions {
            let messages = PiCompatibleSessionParser.messages(
                fromJSONLLines: session.lines,
                source: source,
                fallbackSessionID: URL(fileURLWithPath: session.streamID)
                    .deletingPathExtension()
                    .lastPathComponent)
            for message in messages {
                guard message.timestamp >= startDate,
                      message.timestamp < endDate,
                      dedupKeys.insert(message.dedupKey(namespace: source.dedupNamespace)).inserted else {
                    continue
                }

                guard let totalTokens = result.accumulateTokenCounts(
                    input: message.inputTokens,
                    output: message.outputTokens,
                    cacheRead: message.cacheReadTokens,
                    cacheWrite: message.cacheWriteTokens,
                    reasoning: message.reasoningTokens) else {
                    continue
                }
                result.cost += message.cost ?? 0

                let attribution = UsageAttribution(
                    projectPath: message.cwd,
                    sessionID: message.sessionID,
                    quality: message.cwd == nil ? .unknown : .exact)
                let modelKey = UsageModelGrouping.groupingKey(for: message.model)
                activityEvents.append(ActivityTimeEvent(
                    streamID: message.sessionID,
                    timestamp: message.timestamp,
                    key: modelKey,
                    agentKind: message.agentKind))
                result.accumulatePerModelUsage(
                    model: message.model,
                    source: source.sourceName,
                    totalTokens: totalTokens,
                    cost: message.cost ?? 0)
                result.recordTokenEvent(
                    timestamp: message.timestamp,
                    source: source.sourceName,
                    model: message.model,
                    provider: message.provider,
                    inputTokens: message.inputTokens,
                    outputTokens: message.outputTokens,
                    cacheReadTokens: message.cacheReadTokens,
                    cacheWriteTokens: message.cacheWriteTokens,
                    reasoningTokens: message.reasoningTokens,
                    cost: message.cost ?? 0,
                    costIsKnown: message.cost != nil,
                    attribution: attribution)
            }
        }

        result.mergeActivityEvents(
            activityEvents,
            source: source.sourceName,
            clippingEndDate: endDate)
        return result
    }
}
