import Foundation
import TokiUsageCore

public struct CopilotCLIReader: TokenReader {
    public static let sourceName = "GitHub Copilot CLI"

    public let name = Self.sourceName
    private let otelDirectoryURLOverride: URL?
    private let exporterFileURLOverride: URL?

    public init(
        otelDirectoryURLOverride: URL? = nil,
        exporterFileURLOverride: URL? = nil) {
        self.otelDirectoryURLOverride = otelDirectoryURLOverride
        self.exporterFileURLOverride = exporterFileURLOverride
    }

    private var otelDirectoryURL: URL {
        otelDirectoryURLOverride ?? homeDir().appendingPathComponent(".copilot/otel")
    }

    public func readUsage(from startDate: Date, to endDate: Date) async throws -> RawTokenUsage {
        Self.usage(
            fromJSONLFiles: sourceFiles().map { file in
                (streamID: file.path, lines: readJSONLLines(at: file))
            },
            from: startDate,
            to: endDate)
    }

    static func usage(
        fromJSONLLines lines: [String],
        streamID: String,
        from startDate: Date,
        to endDate: Date) -> RawTokenUsage {
        usage(
            fromJSONLFiles: [(streamID: streamID, lines: lines)],
            from: startDate,
            to: endDate)
    }

    private static func usage(
        fromJSONLFiles files: [(streamID: String, lines: [String])],
        from startDate: Date,
        to endDate: Date) -> RawTokenUsage {
        let decoder = JSONDecoder()
        var decodedRecords: [DecodedCopilotRecord] = []
        for file in files {
            for (lineIndex, line) in file.lines.enumerated() {
                let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty,
                      let data = trimmed.data(using: .utf8),
                      let record = try? decoder.decode(CopilotOTELRecord.self, from: data) else {
                    continue
                }
                decodedRecords.append(
                    DecodedCopilotRecord(
                        record: record,
                        streamID: file.streamID,
                        lineIndex: lineIndex))
            }
        }
        let traceContexts = copilotTraceContexts(from: decodedRecords.map(\.record))
        let candidates = decodedRecords.compactMap { item in
            CopilotUsageCandidate(
                record: item.record,
                traceContext: item.record.validTraceID.flatMap { traceContexts[$0] },
                streamID: item.streamID,
                lineIndex: item.lineIndex)
        }
        let merged = reconcileTraceCandidates(mergeDuplicateCandidates(candidates))
        let selected = selectPreferredCandidates(merged)

        var result = RawTokenUsage()
        var activityEvents: [ActivityTimeEvent<String>] = []
        for candidate in selected where candidate.timestamp >= startDate && candidate.timestamp < endDate {
            guard let totalTokens = result.accumulateTokenCounts(
                input: candidate.inputTokens,
                output: candidate.outputTokens,
                cacheRead: candidate.cacheReadTokens,
                cacheWrite: candidate.cacheWriteTokens,
                reasoning: candidate.reasoningTokens) else {
                continue
            }

            result.accumulatePerModelUsage(
                model: candidate.model,
                source: sourceName,
                totalTokens: totalTokens)
            result.recordTokenEvent(
                timestamp: candidate.timestamp,
                source: sourceName,
                model: candidate.model,
                provider: candidate.provider,
                inputTokens: candidate.inputTokens,
                outputTokens: candidate.outputTokens,
                cacheReadTokens: candidate.cacheReadTokens,
                cacheWriteTokens: candidate.cacheWriteTokens,
                reasoningTokens: candidate.reasoningTokens,
                costIsKnown: false,
                attribution: UsageAttribution(
                    sessionID: candidate.sessionID,
                    quality: .unknown))
            activityEvents.append(
                ActivityTimeEvent(
                    streamID: candidate.sessionID ?? candidate.streamID,
                    timestamp: candidate.timestamp,
                    key: UsageModelGrouping.groupingKey(for: candidate.model)))
        }

        result.mergeActivityEvents(
            activityEvents,
            source: sourceName,
            clippingEndDate: endDate)
        return result
    }
}

private extension CopilotCLIReader {
    func sourceFiles() -> [URL] {
        var files: Set<URL> = []
        if let defaultFiles = try? FileManager.default.contentsOfDirectory(
            at: otelDirectoryURL,
            includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey],
            options: [.skipsHiddenFiles]) {
            for file in defaultFiles where isReadableJSONLFile(file) {
                files.insert(canonicalFileURL(file))
            }
        }
        if let exporterFileURLOverride,
           isReadableJSONLFile(exporterFileURLOverride) {
            files.insert(canonicalFileURL(exporterFileURLOverride))
        }
        return files.sorted { $0.path < $1.path }
    }

    func isReadableJSONLFile(_ url: URL) -> Bool {
        guard url.pathExtension.lowercased() == "jsonl",
              let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey]) else {
            return false
        }
        return values.isRegularFile == true && values.isSymbolicLink != true
    }

    func canonicalFileURL(_ url: URL) -> URL {
        url.standardizedFileURL.resolvingSymlinksInPath()
    }
}

private struct DecodedCopilotRecord {
    let record: CopilotOTELRecord
    let streamID: String
    let lineIndex: Int
}

enum CopilotUsageSource: Int {
    case chatSpan
    case inferenceLog
    case agentTurnLog
    case agentSummarySpan

    var priority: Int {
        switch self {
        case .chatSpan:
            4
        case .inferenceLog:
            3
        case .agentTurnLog:
            2
        case .agentSummarySpan:
            1
        }
    }
}

private struct CopilotUsageCandidate {
    let source: CopilotUsageSource
    let traceID: String?
    let spanID: String?
    let responseID: String?
    let streamID: String
    let lineIndex: Int
    let model: String?
    let provider: String?
    let sessionID: String?
    let timestamp: Date
    let inputTokens: Int
    let outputTokens: Int
    let cacheReadTokens: Int
    let cacheWriteTokens: Int
    let reasoningTokens: Int

    init?(
        record: CopilotOTELRecord,
        traceContext: CopilotTraceContext?,
        streamID: String,
        lineIndex: Int) {
        guard let source = record.usageSource,
              let timestamp = record.timestamp else {
            return nil
        }
        let attributes = record.attributes
        let inclusiveInput = max(0, attributes.inputTokens ?? 0)
        let cacheRead = max(0, attributes.cacheReadTokens ?? 0)
        let cacheWrite = max(0, attributes.cacheWriteTokens ?? 0)
        let output = max(0, attributes.outputTokens ?? 0)
        let reasoning = max(0, attributes.reasoningTokens ?? 0)
        let input = max(0, inclusiveInput - min(inclusiveInput, cacheRead))
        guard let totalTokens = checkedTokenTotal(
            input,
            output,
            cacheRead,
            cacheWrite,
            reasoning),
            totalTokens > 0 else {
            return nil
        }

        self.source = source
        traceID = record.validTraceID
        spanID = record.validSpanID
        responseID = attributes.responseID?.trimmedNonEmpty
        self.streamID = streamID
        self.lineIndex = lineIndex
        let resolvedModel = normalizedModelID(attributes.responseModel)
            ?? normalizedModelID(attributes.requestModel)
            ?? traceContext?.model
        model = resolvedModel
        provider = attributes.provider?.trimmedNonEmpty
            ?? traceContext?.provider
            ?? inferredUsageProvider(from: resolvedModel)
        sessionID = [
            attributes.conversationID,
            attributes.copilotSessionID,
            attributes.copilotChatSessionID,
            attributes.sessionID,
            attributes.interactionID,
            traceContext?.sessionID,
            responseID,
            traceID,
        ].compactMap { $0?.trimmedNonEmpty }.first
        self.timestamp = timestamp
        inputTokens = input
        outputTokens = output
        cacheReadTokens = cacheRead
        cacheWriteTokens = cacheWrite
        reasoningTokens = reasoning
    }

    var totalTokens: Int {
        checkedTokenTotal(
            inputTokens,
            outputTokens,
            cacheReadTokens,
            cacheWriteTokens,
            reasoningTokens) ?? 0
    }

    var stableIdentity: String? {
        if let responseID {
            return "response:\(responseID)"
        }
        if let traceID, let spanID {
            return "span:\(traceID):\(spanID)"
        }
        if let spanID {
            return "span:\(spanID)"
        }
        return nil
    }

    var uniqueIdentity: String {
        stableIdentity ?? "line:\(streamID):\(lineIndex)"
    }

    func merged(with other: Self) -> Self {
        let preferred = source.priority >= other.source.priority ? self : other
        let fallback = source.priority >= other.source.priority ? other : self
        return Self(
            source: preferred.source,
            traceID: preferred.traceID ?? fallback.traceID,
            spanID: preferred.spanID ?? fallback.spanID,
            responseID: preferred.responseID ?? fallback.responseID,
            streamID: preferred.streamID,
            lineIndex: min(lineIndex, other.lineIndex),
            model: preferred.model ?? fallback.model,
            provider: preferred.provider ?? fallback.provider,
            sessionID: preferred.sessionID ?? fallback.sessionID,
            timestamp: min(timestamp, other.timestamp),
            inputTokens: preferred.inputTokens > 0
                ? preferred.inputTokens
                : fallback.inputTokens,
            outputTokens: preferred.outputTokens > 0
                ? preferred.outputTokens
                : fallback.outputTokens,
            cacheReadTokens: preferred.cacheReadTokens > 0
                ? preferred.cacheReadTokens
                : fallback.cacheReadTokens,
            cacheWriteTokens: preferred.cacheWriteTokens > 0
                ? preferred.cacheWriteTokens
                : fallback.cacheWriteTokens,
            reasoningTokens: preferred.reasoningTokens > 0
                ? preferred.reasoningTokens
                : fallback.reasoningTokens)
    }

    private init(
        source: CopilotUsageSource,
        traceID: String?,
        spanID: String?,
        responseID: String?,
        streamID: String,
        lineIndex: Int,
        model: String?,
        provider: String?,
        sessionID: String?,
        timestamp: Date,
        inputTokens: Int,
        outputTokens: Int,
        cacheReadTokens: Int,
        cacheWriteTokens: Int,
        reasoningTokens: Int) {
        self.source = source
        self.traceID = traceID
        self.spanID = spanID
        self.responseID = responseID
        self.streamID = streamID
        self.lineIndex = lineIndex
        self.model = model
        self.provider = provider
        self.sessionID = sessionID
        self.timestamp = timestamp
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.cacheReadTokens = cacheReadTokens
        self.cacheWriteTokens = cacheWriteTokens
        self.reasoningTokens = reasoningTokens
    }
}

private struct CopilotTraceContext {
    var model: String?
    var provider: String?
    var sessionID: String?
}

private func copilotTraceContexts(
    from records: [CopilotOTELRecord]) -> [String: CopilotTraceContext] {
    var contexts: [String: CopilotTraceContext] = [:]
    for record in records {
        guard let traceID = record.validTraceID else { continue }
        let attributes = record.attributes
        var context = contexts[traceID] ?? CopilotTraceContext()
        context.model = context.model
            ?? normalizedModelID(attributes.responseModel)
            ?? normalizedModelID(attributes.requestModel)
        context.provider = context.provider ?? attributes.provider?.trimmedNonEmpty
        context.sessionID = context.sessionID ?? [
            attributes.conversationID,
            attributes.copilotSessionID,
            attributes.copilotChatSessionID,
            attributes.sessionID,
            attributes.interactionID,
        ].compactMap { $0?.trimmedNonEmpty }.first
        contexts[traceID] = context
    }
    return contexts
}

private func selectPreferredCandidates(_ candidates: [CopilotUsageCandidate]) -> [CopilotUsageCandidate] {
    var highestPriorityByResponseID: [String: Int] = [:]
    var highestPriorityByTraceID: [String: Int] = [:]
    for candidate in candidates {
        if let responseID = candidate.responseID {
            highestPriorityByResponseID[responseID] = max(
                highestPriorityByResponseID[responseID] ?? Int.min,
                candidate.source.priority)
        } else if let traceID = candidate.traceID {
            highestPriorityByTraceID[traceID] = max(
                highestPriorityByTraceID[traceID] ?? Int.min,
                candidate.source.priority)
        }
    }

    return candidates.filter { candidate in
        if let responseID = candidate.responseID {
            return candidate.source.priority >= (highestPriorityByResponseID[responseID] ?? Int.min)
        }
        if let traceID = candidate.traceID {
            return candidate.source.priority >= (highestPriorityByTraceID[traceID] ?? Int.min)
        }
        return true
    }
}

private func reconcileTraceCandidates(
    _ candidates: [CopilotUsageCandidate]) -> [CopilotUsageCandidate] {
    var reconciled = candidates
    var removed = Set<Int>()

    for (index, candidate) in candidates.enumerated()
        where candidate.responseID == nil {
        guard let traceID = candidate.traceID else { continue }
        let matches = candidates.indices.filter { candidateIndex in
            candidateIndex != index
                && candidates[candidateIndex].responseID != nil
                && candidates[candidateIndex].traceID == traceID
        }
        if let match = matches.first, matches.count == 1 {
            reconciled[match] = reconciled[match].merged(with: candidate)
        }
        if !matches.isEmpty {
            removed.insert(index)
        }
    }

    return reconciled.indices.compactMap { index in
        removed.contains(index) ? nil : reconciled[index]
    }
}

private func mergeDuplicateCandidates(
    _ candidates: [CopilotUsageCandidate]) -> [CopilotUsageCandidate] {
    var merged: [String: CopilotUsageCandidate] = [:]
    var order: [String] = []
    for candidate in candidates {
        let key = candidate.uniqueIdentity
        if let existing = merged[key] {
            merged[key] = existing.merged(with: candidate)
        } else {
            order.append(key)
            merged[key] = candidate
        }
    }
    return order.compactMap { merged[$0] }
}
