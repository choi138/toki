import Foundation
import TokiUsageCore

public struct CopilotCLIReader: TokenReader {
    public static let sourceName = "GitHub Copilot CLI"

    public let name = Self.sourceName
    private let otelDirectoryURLOverride: URL?
    private let exporterFileURLOverride: URL?
    private let readLimits: PiCompatibleReadLimits

    public init(
        otelDirectoryURLOverride: URL? = nil,
        exporterFileURLOverride: URL? = nil) {
        self.otelDirectoryURLOverride = otelDirectoryURLOverride
        self.exporterFileURLOverride = exporterFileURLOverride
        readLimits = .default
    }

    init(
        otelDirectoryURLOverride: URL?,
        exporterFileURLOverride: URL?,
        readLimits: PiCompatibleReadLimits) {
        self.otelDirectoryURLOverride = otelDirectoryURLOverride
        self.exporterFileURLOverride = exporterFileURLOverride
        self.readLimits = readLimits
    }

    private var otelDirectoryURL: URL {
        otelDirectoryURLOverride ?? homeDir().appendingPathComponent(".copilot/otel")
    }

    public func readUsage(from startDate: Date, to endDate: Date) async throws -> RawTokenUsage {
        let files = try sourceFiles()
        guard files.count <= readLimits.maximumFileCount else {
            throw PiCompatibleReaderError.tooManyFiles(files.count)
        }
        var decodedRecords: [DecodedCopilotRecord] = []
        for file in files {
            try forEachBoundedJSONLLine(at: file, limits: readLimits) { line, lineIndex in
                guard let record = Self.decodedRecord(
                    fromJSONLLine: line,
                    streamID: file.path,
                    lineIndex: lineIndex) else {
                    return
                }
                decodedRecords.append(record)
                guard decodedRecords.count <= readLimits.maximumEventCount else {
                    throw PiCompatibleReaderError.tooManyEvents(decodedRecords.count)
                }
            }
        }
        return Self.usage(
            fromDecodedRecords: decodedRecords,
            from: startDate,
            to: endDate)
    }

    static func usage(
        fromJSONLLines lines: [String],
        streamID: String,
        from startDate: Date,
        to endDate: Date) -> RawTokenUsage {
        let decodedRecords = lines.enumerated().compactMap { lineIndex, line in
            decodedRecord(
                fromJSONLLine: line,
                streamID: streamID,
                lineIndex: lineIndex)
        }
        return usage(
            fromDecodedRecords: decodedRecords,
            from: startDate,
            to: endDate)
    }

    private static func usage(
        fromDecodedRecords decodedRecords: [DecodedCopilotRecord],
        from startDate: Date,
        to endDate: Date) -> RawTokenUsage {
        let traceContexts = copilotTraceContexts(from: decodedRecords.map(\.record))
        let candidates = decodedRecords.compactMap { item in
            CopilotUsageCandidate(
                record: item.record,
                bodyUsageSource: item.bodyUsageSource,
                traceContext: item.record.validTraceID.flatMap { traceContexts[$0] },
                streamID: item.streamID,
                lineIndex: item.lineIndex)
        }
        let merged = mergeDuplicateCandidates(candidates)
        let selected = selectPreferredCandidates(merged)

        var result = RawTokenUsage()
        var activityEvents: [ActivityTimeEvent<String>] = []
        for candidate in selected where candidate.timestamp >= startDate && candidate.timestamp < endDate {
            result.inputTokens += candidate.inputTokens
            result.outputTokens += candidate.outputTokens
            result.cacheReadTokens += candidate.cacheReadTokens
            result.cacheWriteTokens += candidate.cacheWriteTokens
            result.reasoningTokens += candidate.reasoningTokens

            result.accumulatePerModelUsage(
                model: candidate.model,
                source: sourceName,
                totalTokens: candidate.totalTokens)
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

    private static func decodedRecord(
        fromJSONLLine line: String,
        streamID: String,
        lineIndex: Int) -> DecodedCopilotRecord? {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let data = trimmed.data(using: .utf8),
              let record = try? JSONDecoder().decode(CopilotOTELRecord.self, from: data) else {
            return nil
        }
        return DecodedCopilotRecord(
            record: record,
            bodyUsageSource: copilotBodyUsageSource(in: data),
            streamID: streamID,
            lineIndex: lineIndex)
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

private extension CopilotCLIReader {
    func sourceFiles() throws -> [URL] {
        var files: Set<URL> = []
        if FileManager.default.fileExists(atPath: otelDirectoryURL.path) {
            let defaultFiles: [URL]
            do {
                defaultFiles = try FileManager.default.contentsOfDirectory(
                    at: otelDirectoryURL,
                    includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey],
                    options: [.skipsHiddenFiles])
            } catch {
                throw PiCompatibleReaderError.unreadableFile(otelDirectoryURL)
            }
            for file in defaultFiles where try isReadableJSONLFile(file) {
                files.insert(canonicalFileURL(file))
            }
        }
        if let exporterFileURLOverride,
           FileManager.default.fileExists(atPath: exporterFileURLOverride.path),
           try isReadableJSONLFile(exporterFileURLOverride) {
            files.insert(canonicalFileURL(exporterFileURLOverride))
        }
        return files.sorted { $0.path < $1.path }
    }

    func isReadableJSONLFile(_ url: URL) throws -> Bool {
        guard url.pathExtension.lowercased() == "jsonl" else {
            return false
        }
        let values: URLResourceValues
        do {
            values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
        } catch {
            throw PiCompatibleReaderError.unreadableFile(url)
        }
        return values.isRegularFile == true && values.isSymbolicLink != true
    }

    func canonicalFileURL(_ url: URL) -> URL {
        url.standardizedFileURL.resolvingSymlinksInPath()
    }
}

private struct DecodedCopilotRecord {
    let record: CopilotOTELRecord
    let bodyUsageSource: CopilotUsageSource?
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
    let reportedBuckets: CopilotReportedBuckets

    init?(
        record: CopilotOTELRecord,
        bodyUsageSource: CopilotUsageSource?,
        traceContext: CopilotTraceContext?,
        streamID: String,
        lineIndex: Int) {
        guard let source = record.usageSource ?? bodyUsageSource,
              let timestamp = record.timestamp else {
            return nil
        }
        let attributes = record.attributes
        let inclusiveInput = boundedUsageTokenCount(attributes.inputTokens)
        let cacheRead = boundedUsageTokenCount(attributes.cacheReadTokens)
        let cacheWrite = boundedUsageTokenCount(attributes.cacheWriteTokens)
        let inclusiveOutput = boundedUsageTokenCount(attributes.outputTokens)
        let reasoning = boundedUsageTokenCount(attributes.reasoningTokens)
        let input = max(0, inclusiveInput - min(inclusiveInput, cacheRead))
        let output = max(0, inclusiveOutput - min(inclusiveOutput, reasoning))
        guard input + output + cacheRead + cacheWrite + reasoning > 0 else {
            return nil
        }
        var reportedBuckets: CopilotReportedBuckets = []
        if attributes.inputTokens != nil { reportedBuckets.insert(.input) }
        if attributes.outputTokens != nil { reportedBuckets.insert(.output) }
        if attributes.cacheReadTokens != nil { reportedBuckets.insert(.cacheRead) }
        if attributes.cacheWriteTokens != nil { reportedBuckets.insert(.cacheWrite) }
        if attributes.reasoningTokens != nil { reportedBuckets.insert(.reasoning) }

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
        self.reportedBuckets = reportedBuckets
    }

    var totalTokens: Int {
        inputTokens + outputTokens + cacheReadTokens + cacheWriteTokens + reasoningTokens
    }

    var spanIdentity: String? {
        if let traceID, let spanID {
            return "span:\(traceID):\(spanID)"
        }
        if let spanID {
            return "span:\(spanID)"
        }
        return nil
    }

    var responseIdentity: String? {
        responseID.map { "response:\($0)" }
    }

    var uniqueIdentity: String {
        spanIdentity ?? responseIdentity ?? "line:\(streamID):\(lineIndex)"
    }

    func merged(with other: Self) -> Self {
        let preferred: Self
        let supplemental: Self
        if source.priority != other.source.priority {
            (preferred, supplemental) = source.priority > other.source.priority
                ? (self, other) : (other, self)
        } else if totalTokens != other.totalTokens {
            (preferred, supplemental) = totalTokens > other.totalTokens
                ? (self, other) : (other, self)
        } else {
            (preferred, supplemental) = lineIndex >= other.lineIndex
                ? (self, other) : (other, self)
        }
        return Self(
            source: preferred.source,
            traceID: preferred.traceID ?? supplemental.traceID,
            spanID: preferred.spanID ?? supplemental.spanID,
            responseID: preferred.responseID ?? supplemental.responseID,
            streamID: preferred.streamID,
            lineIndex: preferred.lineIndex,
            model: preferred.model ?? supplemental.model,
            provider: preferred.provider ?? supplemental.provider,
            sessionID: preferred.sessionID ?? supplemental.sessionID,
            timestamp: preferred.timestamp,
            inputTokens: preferred.reportedBuckets.contains(.input)
                ? preferred.inputTokens : supplemental.inputTokens,
            outputTokens: preferred.reportedBuckets.contains(.output)
                ? preferred.outputTokens : supplemental.outputTokens,
            cacheReadTokens: preferred.reportedBuckets.contains(.cacheRead)
                ? preferred.cacheReadTokens : supplemental.cacheReadTokens,
            cacheWriteTokens: preferred.reportedBuckets.contains(.cacheWrite)
                ? preferred.cacheWriteTokens : supplemental.cacheWriteTokens,
            reasoningTokens: preferred.reportedBuckets.contains(.reasoning)
                ? preferred.reasoningTokens : supplemental.reasoningTokens,
            reportedBuckets: preferred.reportedBuckets.union(supplemental.reportedBuckets))
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
        reasoningTokens: Int,
        reportedBuckets: CopilotReportedBuckets) {
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
        self.reportedBuckets = reportedBuckets
    }
}

private struct CopilotReportedBuckets: OptionSet {
    let rawValue: Int

    static let input = Self(rawValue: 1 << 0)
    static let output = Self(rawValue: 1 << 1)
    static let cacheRead = Self(rawValue: 1 << 2)
    static let cacheWrite = Self(rawValue: 1 << 3)
    static let reasoning = Self(rawValue: 1 << 4)
}

private func selectPreferredCandidates(_ candidates: [CopilotUsageCandidate]) -> [CopilotUsageCandidate] {
    var highestPriorityByResponse: [String: Int] = [:]
    var highestPriorityByTrace: [String: Int] = [:]
    for candidate in candidates {
        if let responseID = candidate.responseID {
            highestPriorityByResponse[responseID] = max(
                highestPriorityByResponse[responseID] ?? Int.min,
                candidate.source.priority)
        }
        if let traceID = candidate.traceID {
            highestPriorityByTrace[traceID] = max(
                highestPriorityByTrace[traceID] ?? Int.min,
                candidate.source.priority)
        }
    }

    return candidates.filter { candidate in
        if let responseID = candidate.responseID {
            return candidate.source.priority >= (highestPriorityByResponse[responseID] ?? Int.min)
        }
        if candidate.source == .agentSummarySpan, let traceID = candidate.traceID {
            return candidate.source.priority >= (highestPriorityByTrace[traceID] ?? Int.min)
        }
        return true
    }
}

private func mergeDuplicateCandidates(
    _ candidates: [CopilotUsageCandidate]) -> [CopilotUsageCandidate] {
    let spanMerged = mergeCandidates(candidates) {
        $0.spanIdentity ?? "line:\($0.streamID):\($0.lineIndex)"
    }
    return mergeCandidates(spanMerged) {
        $0.responseIdentity ?? $0.uniqueIdentity
    }
}

private func mergeCandidates(
    _ candidates: [CopilotUsageCandidate],
    identity: (CopilotUsageCandidate) -> String) -> [CopilotUsageCandidate] {
    var merged: [String: CopilotUsageCandidate] = [:]
    var order: [String] = []
    for candidate in candidates {
        let key = identity(candidate)
        if let existing = merged[key] {
            merged[key] = existing.merged(with: candidate)
        } else {
            order.append(key)
            merged[key] = candidate
        }
    }
    return order.compactMap { merged[$0] }
}
