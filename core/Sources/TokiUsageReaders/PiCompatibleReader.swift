import Foundation
import TokiUsageCore

struct PiCompatibleReader {
    let source: PiCompatibleSource
    let sessionRoots: [URL]
    let readLimits: PiCompatibleReadLimits
    let agentKindForFile: (URL) -> WorkTimeAgentKind
    let replicaScopeForFile: (URL) -> String?
    let usageFileCache: PiCompatibleUsageFileCache

    init(
        source: PiCompatibleSource,
        sessionRoots: [URL],
        readLimits: PiCompatibleReadLimits = .default,
        agentKindForFile: @escaping (URL) -> WorkTimeAgentKind = { _ in .main },
        replicaScopeForFile: @escaping (URL) -> String? = { _ in nil },
        usageFileCache: PiCompatibleUsageFileCache = .shared) {
        self.source = source
        self.sessionRoots = sessionRoots
        self.readLimits = readLimits
        self.agentKindForFile = agentKindForFile
        self.replicaScopeForFile = replicaScopeForFile
        self.usageFileCache = usageFileCache
    }

    func readUsage(from startDate: Date, to endDate: Date) throws -> RawTokenUsage {
        let files = try discoveredFiles()
        usageFileCache.retainFiles(files, source: source)
        guard files.count <= readLimits.maximumFileCount else {
            throw PiCompatibleReaderError.tooManyFiles(files.count)
        }

        var records: [PiCompatibleUsageRecord] = []
        var unreconciledRecordCount = 0
        for file in files {
            let fileRecords = try usageFileCache.records(
                for: file,
                source: source,
                agentKind: agentKindForFile(file),
                replicaScope: replicaScopeForFile(file),
                limits: readLimits)
            guard fileRecords.count <= readLimits.maximumEventCount else {
                throw PiCompatibleReaderError.tooManyEvents(fileRecords.count)
            }
            for record in fileRecords {
                let (nextCount, overflow) = unreconciledRecordCount.addingReportingOverflow(1)
                guard !overflow, nextCount <= readLimits.maximumUnreconciledEventCount else {
                    throw PiCompatibleReaderError.tooManyEvents(overflow ? Int.max : nextCount)
                }
                unreconciledRecordCount = nextCount
                records.append(record)
            }
        }
        let uniqueRecords = Self.uniqueRecords(from: records, source: source)
        guard uniqueRecords.count <= readLimits.maximumEventCount else {
            throw PiCompatibleReaderError.tooManyEvents(uniqueRecords.count)
        }
        return Self.usage(
            fromUniqueRecords: uniqueRecords,
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
        usage(
            fromUniqueRecords: uniqueRecords(from: records, source: source),
            source: source,
            from: startDate,
            to: endDate)
    }

    private static func uniqueRecords(
        from records: some Sequence<PiCompatibleUsageRecord>,
        source: PiCompatibleSource) -> [PiCompatibleUsageRecord] {
        var recordsByKey: [PiCompatibleDeduplicationKey: PiCompatibleUsageRecord] = [:]
        var aliasesByKey: [PiCompatibleDeduplicationKey: Set<PiCompatibleMergeAlias>] = [:]
        for record in records {
            aliasesByKey[record.deduplicationKey, default: []]
                .formUnion(record.mergeAliases)
            recordsByKey[record.deduplicationKey] = recordsByKey[record.deduplicationKey]
                .map { $0.merged(with: record, retainingAliases: false) } ?? record
        }

        enrichUniqueResponseProviders(recordsByKey: &recordsByKey, aliasesByKey: &aliasesByKey)
        let aliasedRecords = mergeAliasedRecords(recordsByKey.map { key, record in
            record.replacingMergeAliases(aliasesByKey[key] ?? [])
        })
        return source == .ohMyPi
            ? reconcileDelegatedReplicas(aliasedRecords)
            : aliasedRecords
    }

    private static func usage(
        fromUniqueRecords uniqueRecords: some Sequence<PiCompatibleUsageRecord>,
        source: PiCompatibleSource,
        from startDate: Date,
        to endDate: Date) -> RawTokenUsage {
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

private enum PiCompatibleReplicaIdentity: Hashable {
    case message(scope: String, id: String)
    case response(scope: String, id: String)
}

private func enrichUniqueResponseProviders(
    recordsByKey: inout [PiCompatibleDeduplicationKey: PiCompatibleUsageRecord],
    aliasesByKey: inout [PiCompatibleDeduplicationKey: Set<PiCompatibleMergeAlias>]) {
    var providersByScope: [PiCompatibleResponseScope: Set<String>] = [:]
    for key in recordsByKey.keys {
        guard case let .sessionResponse(sessionID, provider?, responseID) = key else {
            continue
        }
        providersByScope[
            PiCompatibleResponseScope(sessionID: sessionID, responseID: responseID),
            default: []
        ].insert(provider)
    }

    for key in Array(recordsByKey.keys) {
        guard case let .sessionResponse(sessionID, nil, responseID) = key,
              let record = recordsByKey[key] else {
            continue
        }
        let scope = PiCompatibleResponseScope(sessionID: sessionID, responseID: responseID)
        guard let providers = providersByScope[scope], providers.count == 1,
              let provider = providers.first else {
            continue
        }
        let enrichedKey = PiCompatibleDeduplicationKey.sessionResponse(
            sessionID: sessionID,
            provider: provider,
            responseID: responseID)
        let unknownAliases = aliasesByKey[key] ?? []
        recordsByKey[enrichedKey] = recordsByKey[enrichedKey]
            .map { $0.merged(with: record, retainingAliases: false) } ?? record
        aliasesByKey[enrichedKey, default: []].formUnion(unknownAliases)
        recordsByKey.removeValue(forKey: key)
        aliasesByKey.removeValue(forKey: key)
    }
}

private func reconcileDelegatedReplicas(
    _ records: [PiCompatibleUsageRecord]) -> [PiCompatibleUsageRecord] {
    var reconciled = records.sorted {
        $0.deduplicationKey.isOrdered(before: $1.deduplicationKey)
    }
    var indicesByIdentity: [PiCompatibleReplicaIdentity: [Int]] = [:]
    for (index, record) in reconciled.enumerated() {
        guard let identity = replicaIdentity(for: record) else { continue }
        indicesByIdentity[identity, default: []].append(index)
    }

    var removedIndices: Set<Int> = []
    for indices in indicesByIdentity.values {
        let mainIndices = indices.filter { reconciled[$0].agentKind == .main }
        let subagentIndices = indices.filter { reconciled[$0].agentKind == .subagent }
        for subagentIndex in subagentIndices {
            guard !removedIndices.contains(subagentIndex) else { continue }
            let matchingMainIndices = mainIndices.filter {
                !removedIndices.contains($0)
                    && copiedRecordsMatch(reconciled[$0], reconciled[subagentIndex])
            }
            guard matchingMainIndices.count == 1, let mainIndex = matchingMainIndices.first else {
                continue
            }
            reconciled[mainIndex] = reconciled[mainIndex].merged(
                with: reconciled[subagentIndex],
                retainingAliases: false)
            removedIndices.insert(subagentIndex)
        }
    }
    return reconciled.indices.compactMap {
        removedIndices.contains($0) ? nil : reconciled[$0]
    }
}

private func replicaIdentity(
    for record: PiCompatibleUsageRecord) -> PiCompatibleReplicaIdentity? {
    guard let scope = record.replicaScope else { return nil }
    switch record.deduplicationKey {
    case let .message(messageID), let .sessionMessage(_, messageID):
        return .message(scope: scope, id: messageID)
    case let .sessionResponse(_, _, responseID), let .legacySessionResponse(_, responseID):
        return .response(scope: scope, id: responseID)
    case .legacyRecord, .record:
        return nil
    }
}

private func copiedRecordsMatch(
    _ mainRecord: PiCompatibleUsageRecord,
    _ subagentRecord: PiCompatibleUsageRecord) -> Bool {
    guard mainRecord.timestamp == subagentRecord.timestamp,
          mainRecord.model == subagentRecord.model,
          mainRecord.inputTokens == subagentRecord.inputTokens,
          mainRecord.outputTokens == subagentRecord.outputTokens,
          mainRecord.cacheReadTokens == subagentRecord.cacheReadTokens,
          mainRecord.cacheWriteTokens == subagentRecord.cacheWriteTokens,
          mainRecord.reasoningTokens == subagentRecord.reasoningTokens else {
        return false
    }
    if let mainProjectPath = mainRecord.attribution.projectPath,
       let subagentProjectPath = subagentRecord.attribution.projectPath,
       mainProjectPath != subagentProjectPath {
        return false
    }
    return mainRecord.provider == subagentRecord.provider
        || !mainRecord.providerIsExplicit
        || !subagentRecord.providerIsExplicit
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
