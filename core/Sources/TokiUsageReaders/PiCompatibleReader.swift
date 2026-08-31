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
        let files = try discoveredFiles()
        guard files.count <= readLimits.maximumFileCount else {
            throw PiCompatibleReaderError.tooManyFiles(files.count)
        }

        var recordsByKey: [PiCompatibleDeduplicationKey: PiCompatibleUsageRecord] = [:]
        var aliasesByKey: [PiCompatibleDeduplicationKey: Set<PiCompatibleMergeAlias>] = [:]
        var examinedRecordCount = 0
        for file in files {
            var parser = PiCompatibleSessionParser(
                streamID: file.path,
                source: source,
                agentKind: agentKindForFile(file))
            try forEachBoundedJSONLLine(at: file, limits: readLimits) { line, lineIndex in
                guard let record = parser.record(fromJSONLLine: line, lineIndex: lineIndex) else {
                    return
                }
                let (nextCount, overflow) = examinedRecordCount.addingReportingOverflow(1)
                guard !overflow, nextCount <= readLimits.maximumEventCount else {
                    throw PiCompatibleReaderError.tooManyEvents(overflow ? Int.max : nextCount)
                }
                examinedRecordCount = nextCount
                aliasesByKey[record.deduplicationKey, default: []]
                    .formUnion(record.mergeAliases)
                recordsByKey[record.deduplicationKey] = recordsByKey[record.deduplicationKey]
                    .map { $0.merged(with: record, retainingAliases: false) } ?? record
            }
        }
        return Self.usage(
            from: recordsByKey.map { key, record in
                record.replacingMergeAliases(aliasesByKey[key] ?? [])
            },
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

    private func discoveredFiles() throws -> [URL] {
        var physicalPaths: Set<String> = []
        var files: [URL] = []
        var visitedEntryCount = 0
        let discoveryLimit = readLimits.maximumFileCount == .max
            ? Int.max
            : readLimits.maximumFileCount + 1
        for root in sessionRoots {
            try Task.checkCancellation()
            for file in try findUsageFiles(
                in: root,
                withExtension: "jsonl",
                maximumFileCount: discoveryLimit,
                maximumEntryCount: readLimits.maximumEntryCount,
                visitedEntryCount: &visitedEntryCount) {
                let resolved = file.resolvingSymlinksInPath().standardizedFileURL
                guard physicalPaths.insert(resolved.path).inserted else { continue }
                files.append(resolved)
                if files.count >= discoveryLimit {
                    return files.sorted { $0.path < $1.path }
                }
            }
        }
        try Task.checkCancellation()
        return files.sorted { $0.path < $1.path }
    }

    private static func usage(
        from records: some Sequence<PiCompatibleUsageRecord>,
        source: PiCompatibleSource,
        from startDate: Date,
        to endDate: Date) -> RawTokenUsage {
        var recordsByKey: [PiCompatibleDeduplicationKey: PiCompatibleUsageRecord] = [:]
        var aliasesByKey: [PiCompatibleDeduplicationKey: Set<PiCompatibleMergeAlias>] = [:]
        for record in records {
            aliasesByKey[record.deduplicationKey, default: []]
                .formUnion(record.mergeAliases)
            recordsByKey[record.deduplicationKey] = recordsByKey[record.deduplicationKey]
                .map { $0.merged(with: record, retainingAliases: false) } ?? record
        }

        let uniqueRecords = mergeAliasedRecords(recordsByKey.map { key, record in
            record.replacingMergeAliases(aliasesByKey[key] ?? [])
        })

        var result = RawTokenUsage()
        var activityEvents: [ActivityTimeEvent<String>] = []
        for record in uniqueRecords.sorted(by: recordSort)
            where record.timestamp >= startDate && record.timestamp < endDate {
            let outputModel = record.model == UsageModelGrouping.mixedOrUnattributedKey
                ? nil
                : record.model
            result.inputTokens += record.inputTokens
            result.outputTokens += record.outputTokens
            result.cacheReadTokens += record.cacheReadTokens
            result.cacheWriteTokens += record.cacheWriteTokens
            result.reasoningTokens += record.reasoningTokens
            result.cost += record.cost
            result.accumulatePerModelUsage(
                model: outputModel,
                source: source.sourceName,
                totalTokens: record.totalTokens,
                cost: record.cost)
            result.recordTokenEvent(
                timestamp: record.timestamp,
                source: source.sourceName,
                model: outputModel,
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
                streamID: record.attribution.sessionID ?? outputModel ?? source.sourceName,
                timestamp: record.timestamp,
                key: UsageModelGrouping.groupingKey(for: outputModel),
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

func mergeAliasedRecords(
    _ records: some Sequence<PiCompatibleUsageRecord>) -> [PiCompatibleUsageRecord] {
    let orderedRecords = records.sorted {
        $0.deduplicationKey.isOrdered(before: $1.deduplicationKey)
    }
    var disjointSet = PiCompatibleDisjointSet(count: orderedRecords.count)
    var ownerByAlias: [PiCompatibleMergeAlias: Int] = [:]
    for (index, record) in orderedRecords.enumerated() {
        for alias in record.mergeAliases {
            if let owner = ownerByAlias[alias] {
                disjointSet.connect(index, owner)
            } else {
                ownerByAlias[alias] = index
            }
        }
    }

    var recordsByRoot: [Int: PiCompatibleUsageRecord] = [:]
    for (index, record) in orderedRecords.enumerated() {
        let root = disjointSet.root(of: index)
        recordsByRoot[root] = recordsByRoot[root]
            .map { $0.merged(with: record, retainingAliases: false) } ?? record
    }
    return Array(recordsByRoot.values)
}

private struct PiCompatibleDisjointSet {
    private var parents: [Int]

    init(count: Int) {
        parents = Array(0..<count)
    }

    mutating func connect(_ lhs: Int, _ rhs: Int) {
        let lhsRoot = root(of: lhs)
        let rhsRoot = root(of: rhs)
        guard lhsRoot != rhsRoot else { return }
        parents[max(lhsRoot, rhsRoot)] = min(lhsRoot, rhsRoot)
    }

    mutating func root(of index: Int) -> Int {
        var root = index
        while parents[root] != root {
            root = parents[root]
        }
        var node = index
        while parents[node] != node {
            let parent = parents[node]
            parents[node] = root
            node = parent
        }
        return root
    }
}
