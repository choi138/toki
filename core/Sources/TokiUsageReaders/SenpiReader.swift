import Foundation
import TokiUsageCore

public struct SenpiReader: TokenReader {
    public static let sourceName = "Senpi"

    public let name = Self.sourceName
    private let sessionRootsOverride: [URL]?
    private let readLimits: PiCompatibleReadLimits
    private let usageFileCache: PiCompatibleUsageFileCache

    public init(sessionRootsOverride: [URL]? = nil) {
        self.sessionRootsOverride = sessionRootsOverride
        readLimits = .default
        usageFileCache = .shared
    }

    init(
        sessionRootsOverride: [URL]?,
        readLimits: PiCompatibleReadLimits) {
        self.sessionRootsOverride = sessionRootsOverride
        self.readLimits = readLimits
        usageFileCache = .shared
    }

    public func readUsage(from startDate: Date, to endDate: Date) async throws -> RawTokenUsage {
        let roots = sessionRootsOverride
            ?? LocalUsageReaderPaths().senpiSessionDirectories
        let files = try Set(roots.flatMap { root in
            try findFiles(
                in: root,
                withExtension: "jsonl",
                cancellationCheck: { try Task.checkCancellation() })
                .map { $0.resolvingSymlinksInPath().standardizedFileURL }
        })
        .sorted { $0.path < $1.path }
        guard files.count <= readLimits.maximumFileCount else {
            throw PiCompatibleReaderError.tooManyFiles(files.count)
        }

        var recordsByKey: [PiCompatibleDeduplicationKey: PiCompatibleUsageRecord] = [:]
        var examinedRecordCount = 0
        for file in files {
            let records = try usageFileCache.records(
                for: file,
                source: .senpi,
                agentKind: Self.agentKind(for: file),
                limits: readLimits)
            for record in records {
                let (nextCount, overflow) = examinedRecordCount.addingReportingOverflow(1)
                guard !overflow, nextCount <= readLimits.maximumEventCount else {
                    throw PiCompatibleReaderError.tooManyEvents(overflow ? Int.max : nextCount)
                }
                examinedRecordCount = nextCount
                recordsByKey[record.deduplicationKey] = recordsByKey[record.deduplicationKey]
                    .map { $0.merged(with: record) } ?? record
            }
        }
        return Self.usage(
            from: recordsByKey.values,
            from: startDate,
            to: endDate)
    }

    static func usage(
        fromJSONLLines lines: [String],
        streamID: String,
        from startDate: Date,
        to endDate: Date) -> RawTokenUsage {
        let records = PiCompatibleSessionParser.records(
            fromJSONLLines: lines,
            streamID: streamID,
            agentKind: .main)
        return usage(
            from: records,
            from: startDate,
            to: endDate)
    }

    private static func usage(
        from records: some Sequence<PiCompatibleUsageRecord>,
        from startDate: Date,
        to endDate: Date) -> RawTokenUsage {
        var recordsByKey: [PiCompatibleDeduplicationKey: PiCompatibleUsageRecord] = [:]
        for record in records {
            recordsByKey[record.deduplicationKey] = recordsByKey[record.deduplicationKey]
                .map { $0.merged(with: record) } ?? record
        }
        let uniqueRecords = mergeAliasedRecords(recordsByKey.values)

        var result = RawTokenUsage()
        var activityEvents: [ActivityTimeEvent<String>] = []
        for record in uniqueRecords.sorted(by: recordSort)
            where record.timestamp >= startDate && record.timestamp < endDate {
            result.inputTokens += record.inputTokens
            result.outputTokens += record.outputTokens
            result.cacheReadTokens += record.cacheReadTokens
            result.cacheWriteTokens += record.cacheWriteTokens
            result.reasoningTokens += record.reasoningTokens
            result.cost += record.cost
            result.accumulatePerModelUsage(
                model: record.model,
                source: sourceName,
                totalTokens: record.totalTokens,
                cost: record.cost)
            result.recordTokenEvent(
                timestamp: record.timestamp,
                source: sourceName,
                model: record.model,
                provider: record.provider,
                inputTokens: record.inputTokens,
                outputTokens: record.outputTokens,
                cacheReadTokens: record.cacheReadTokens,
                cacheWriteTokens: record.cacheWriteTokens,
                reasoningTokens: record.reasoningTokens,
                cost: record.cost,
                costIsKnown: record.costIsKnown,
                attribution: record.attribution)
            activityEvents.append(ActivityTimeEvent(
                streamID: record.attribution.sessionID ?? record.model,
                timestamp: record.timestamp,
                key: UsageModelGrouping.groupingKey(for: record.model),
                agentKind: record.agentKind))
        }
        result.mergeActivityEvents(
            activityEvents,
            source: sourceName,
            clippingEndDate: endDate)
        return result
    }

    private static func agentKind(for file: URL) -> WorkTimeAgentKind {
        let path = file.standardizedFileURL.path
        return path.contains("/.omo/senpi-task/children/")
            || path.contains("/.omo/senpi-task/sessions/") ? .subagent : .main
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
