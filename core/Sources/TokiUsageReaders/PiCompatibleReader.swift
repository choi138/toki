import Foundation
import TokiUsageCore

struct PiCompatibleReader {
    let source: PiCompatibleSource
    let sessionRoots: [URL]
    let readLimits: PiCompatibleReadLimits
    let agentKindForFile: (URL) -> WorkTimeAgentKind

    init(
        source: PiCompatibleSource,
        sessionRoots: [URL],
        readLimits: PiCompatibleReadLimits = .default,
        agentKindForFile: @escaping (URL) -> WorkTimeAgentKind = { _ in .main }) {
        self.source = source
        self.sessionRoots = sessionRoots
        self.readLimits = readLimits
        self.agentKindForFile = agentKindForFile
    }

    func readUsage(from startDate: Date, to endDate: Date) throws -> RawTokenUsage {
        let files = discoveredFiles()
        guard files.count <= readLimits.maximumFileCount else {
            throw PiCompatibleReaderError.tooManyFiles(files.count)
        }

        var recordsByKey: [PiCompatibleDeduplicationKey: PiCompatibleUsageRecord] = [:]
        for file in files {
            var parser = PiCompatibleSessionParser(
                streamID: file.path,
                source: source,
                agentKind: agentKindForFile(file))
            try forEachBoundedJSONLLine(at: file, limits: readLimits) { line, lineIndex in
                guard let record = parser.record(fromJSONLLine: line, lineIndex: lineIndex) else {
                    return
                }
                guard record.timestamp >= startDate, record.timestamp < endDate else {
                    return
                }
                recordsByKey[record.deduplicationKey] = recordsByKey[record.deduplicationKey]
                    .map { $0.merged(with: record) } ?? record
                guard recordsByKey.count <= readLimits.maximumEventCount else {
                    throw PiCompatibleReaderError.tooManyEvents(recordsByKey.count)
                }
            }
        }
        return Self.usage(
            from: recordsByKey.values,
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
        let records = PiCompatibleSessionParser.records(
            fromJSONLLines: lines,
            streamID: streamID,
            source: source,
            agentKind: .main)
        return usage(
            from: records,
            source: source,
            from: startDate,
            to: endDate)
    }

    private func discoveredFiles() -> [URL] {
        var physicalPaths: Set<String> = []
        var files: [URL] = []
        for root in sessionRoots {
            for file in findFiles(in: root, withExtension: "jsonl") {
                let resolved = file.resolvingSymlinksInPath().standardizedFileURL
                guard physicalPaths.insert(resolved.path).inserted else { continue }
                files.append(resolved)
            }
        }
        return files.sorted { $0.path < $1.path }
    }

    private static func usage(
        from records: some Sequence<PiCompatibleUsageRecord>,
        source: PiCompatibleSource,
        from startDate: Date,
        to endDate: Date) -> RawTokenUsage {
        var recordsByKey: [PiCompatibleDeduplicationKey: PiCompatibleUsageRecord] = [:]
        for record in records {
            recordsByKey[record.deduplicationKey] = recordsByKey[record.deduplicationKey]
                .map { $0.merged(with: record) } ?? record
        }

        var result = RawTokenUsage()
        var activityEvents: [ActivityTimeEvent<String>] = []
        for record in recordsByKey.values.sorted(by: recordSort)
            where record.timestamp >= startDate && record.timestamp < endDate {
            result.inputTokens += record.inputTokens
            result.outputTokens += record.outputTokens
            result.cacheReadTokens += record.cacheReadTokens
            result.cacheWriteTokens += record.cacheWriteTokens
            result.reasoningTokens += record.reasoningTokens
            result.cost += record.cost
            result.accumulatePerModelUsage(
                model: record.model,
                source: source.sourceName,
                totalTokens: record.totalTokens,
                cost: record.cost)
            result.recordTokenEvent(
                timestamp: record.timestamp,
                source: source.sourceName,
                model: record.model,
                provider: record.provider,
                inputTokens: record.inputTokens,
                outputTokens: record.outputTokens,
                cacheReadTokens: record.cacheReadTokens,
                cacheWriteTokens: record.cacheWriteTokens,
                reasoningTokens: record.reasoningTokens,
                cost: record.cost,
                attribution: record.attribution)
            activityEvents.append(ActivityTimeEvent(
                streamID: record.attribution.sessionID ?? record.model,
                timestamp: record.timestamp,
                key: UsageModelGrouping.groupingKey(for: record.model),
                agentKind: record.agentKind))
        }
        result.mergeActivityEvents(
            activityEvents,
            source: source.sourceName,
            clippingEndDate: endDate)
        return result
    }

    private static func recordSort(
        _ lhs: PiCompatibleUsageRecord,
        _ rhs: PiCompatibleUsageRecord) -> Bool {
        if lhs.timestamp != rhs.timestamp { return lhs.timestamp < rhs.timestamp }
        if lhs.model != rhs.model { return lhs.model < rhs.model }
        if lhs.provider != rhs.provider { return (lhs.provider ?? "") < (rhs.provider ?? "") }
        if lhs.inputTokens != rhs.inputTokens { return lhs.inputTokens < rhs.inputTokens }
        return lhs.outputTokens < rhs.outputTokens
    }
}
