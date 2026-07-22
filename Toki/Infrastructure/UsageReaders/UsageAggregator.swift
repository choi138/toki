import Foundation
import TokiUsageCore
import TokiUsageReaders

struct UsageAggregationRequest: Equatable {
    let dateInterval: DateInterval
    let enabledReaderNames: [String: Bool]
    let includesEmptySourceRows: Bool

    init(
        start: Date,
        end: Date,
        enabledReaderNames: [String: Bool],
        includesEmptySourceRows: Bool) {
        dateInterval = DateInterval(start: start, end: end)
        self.enabledReaderNames = enabledReaderNames
        self.includesEmptySourceRows = includesEmptySourceRows
    }

    var start: Date {
        dateInterval.start
    }

    var end: Date {
        dateInterval.end
    }
}

struct UsageAggregationResult: Equatable {
    let usageData: UsageData
    let originReports: [UsageOriginReport]
    let readerStatuses: [ReaderStatus]
}

final class UsageAggregator {
    static let defaultReaders: [any TokenReader] = LocalUsageReaderRegistry.readers() + [RemoteUsageReader()]

    private let readers: [any TokenReader]

    init(readers: [any TokenReader] = UsageAggregator.defaultReaders) {
        self.readers = readers
    }

    var readerNames: [String] {
        readers.map(\.name)
    }

    func aggregateUsage(for request: UsageAggregationRequest) async -> UsageAggregationResult {
        let summary = await fetchRange(for: request)
        return UsageAggregationResult(
            usageData: UsageReportBuilder.report(
                from: summary.usage,
                date: request.start,
                endDate: request.end,
                sourceStats: summary.sourceStats),
            originReports: summary.originSlices.map { slice in
                UsageOriginReport(
                    origin: slice.origin,
                    usageData: UsageReportBuilder.report(
                        from: slice.usage,
                        date: request.start,
                        endDate: request.end,
                        sourceStats: slice.sourceStats))
            },
            readerStatuses: summary.readerStatuses)
    }

    func aggregateTotalTokens(for request: UsageAggregationRequest, scope: UsageScope = .all) async -> Int {
        await fetchTotalTokens(for: request, scope: scope)
    }

    func aggregateOutputTokens(for request: UsageAggregationRequest, scope: UsageScope = .all) async -> Int {
        await fetchOutputTokens(for: request, scope: scope)
    }
}

private struct ReaderFetchResult {
    let index: Int
    let usage: RawTokenUsage
    let status: ReaderStatus
    let originSlices: [UsageOriginSlice]
}

private struct UsageFetchSummary {
    var usage = RawTokenUsage()
    var readerStatuses: [ReaderStatus] = []
    var sourceStats: [SourceStat] = []
    var originSlices: [UsageOriginSlice] = []
}

private extension UsageAggregator {
    func fetchTotalTokens(for request: UsageAggregationRequest, scope: UsageScope) async -> Int {
        guard !Task.isCancelled else { return 0 }

        var totalTokens = 0
        await withTaskGroup(of: Int.self) { group in
            for reader in readers {
                guard request.enabledReaderNames[reader.name] ?? true else { continue }
                guard !Task.isCancelled else {
                    group.cancelAll()
                    break
                }

                group.addTask {
                    await readerTotalTokens(
                        reader: reader,
                        scope: scope,
                        from: request.start,
                        to: request.end)
                }
            }

            for await partial in group {
                guard !Task.isCancelled else {
                    group.cancelAll()
                    return
                }
                totalTokens += partial
            }
        }

        guard !Task.isCancelled else { return 0 }
        return totalTokens
    }

    func fetchOutputTokens(for request: UsageAggregationRequest, scope: UsageScope) async -> Int {
        guard !Task.isCancelled else { return 0 }

        var outputTokens = 0
        await withTaskGroup(of: Int.self) { group in
            for reader in readers {
                guard request.enabledReaderNames[reader.name] ?? true else { continue }
                guard !Task.isCancelled else {
                    group.cancelAll()
                    break
                }

                group.addTask {
                    await readerOutputTokens(
                        reader: reader,
                        scope: scope,
                        from: request.start,
                        to: request.end)
                }
            }

            for await partial in group {
                guard !Task.isCancelled else {
                    group.cancelAll()
                    return
                }
                outputTokens += partial
            }
        }

        guard !Task.isCancelled else { return 0 }
        return outputTokens
    }

    func fetchRange(for request: UsageAggregationRequest) async -> UsageFetchSummary {
        guard !Task.isCancelled else { return UsageFetchSummary() }

        var results: [ReaderFetchResult] = readers.enumerated().compactMap { index, reader in
            guard request.enabledReaderNames[reader.name] == false else { return nil }
            return ReaderFetchResult(
                index: index,
                usage: RawTokenUsage(),
                status: ReaderStatus(
                    name: reader.name,
                    state: .disabled,
                    message: nil,
                    lastReadAt: nil,
                    totalTokens: 0),
                originSlices: [])
        }

        await withTaskGroup(of: ReaderFetchResult.self) { group in
            for (index, reader) in readers.enumerated() {
                guard request.enabledReaderNames[reader.name] ?? true else { continue }
                guard !Task.isCancelled else {
                    group.cancelAll()
                    break
                }

                group.addTask {
                    await readerFetchResult(
                        index: index,
                        reader: reader,
                        includeEmptySourceRows: request.includesEmptySourceRows,
                        from: request.start,
                        to: request.end)
                }
            }

            for await partial in group {
                guard !Task.isCancelled else {
                    group.cancelAll()
                    return
                }
                results.append(partial)
            }
        }

        guard !Task.isCancelled else { return UsageFetchSummary() }

        let sortedResults = results.sorted { $0.index < $1.index }
        let unmergedOriginSlices = sortedResults.flatMap(\.originSlices)
        let originSlices = mergedOriginSlices(
            unmergedOriginSlices,
            endDate: request.end)

        return UsageFetchSummary(
            usage: combinedUsage(
                from: unmergedOriginSlices,
                endDate: request.end),
            readerStatuses: sortedResults.map(\.status),
            sourceStats: mergedSourceStats(originSlices.flatMap(\.sourceStats)),
            originSlices: originSlices)
    }
}

private func readerTotalTokens(
    reader: any TokenReader,
    scope: UsageScope,
    from startDate: Date,
    to endDate: Date) async -> Int {
    guard !Task.isCancelled else { return 0 }

    do {
        switch scope {
        case .all:
            return try await reader.readTotalTokens(from: startDate, to: endDate)
        case let .origin(originID):
            if let partitionedReader = reader as? any OriginPartitionedTokenReader {
                return try await partitionedReader
                    .readUsageByOrigin(from: startDate, to: endDate)
                    .filter { $0.origin.id == originID }
                    .reduce(0) { $0 + $1.usage.totalTokens }
            }
            guard originID == .local else { return 0 }
            return try await reader.readTotalTokens(from: startDate, to: endDate)
        }
    } catch {
        return 0
    }
}

private func readerOutputTokens(
    reader: any TokenReader,
    scope: UsageScope,
    from startDate: Date,
    to endDate: Date) async -> Int {
    guard !Task.isCancelled else { return 0 }

    do {
        switch scope {
        case .all:
            return try await reader.readOutputTokens(from: startDate, to: endDate)
        case let .origin(originID):
            if let partitionedReader = reader as? any OriginPartitionedTokenReader {
                return try await partitionedReader
                    .readUsageByOrigin(from: startDate, to: endDate)
                    .filter { $0.origin.id == originID }
                    .reduce(0) { $0 + $1.usage.outputTokens }
            }
            guard originID == .local else { return 0 }
            return try await reader.readOutputTokens(from: startDate, to: endDate)
        }
    } catch {
        return 0
    }
}

private func readerFetchResult(
    index: Int,
    reader: any TokenReader,
    includeEmptySourceRows: Bool,
    from startDate: Date,
    to endDate: Date) async -> ReaderFetchResult {
    guard !Task.isCancelled else {
        return ReaderFetchResult(
            index: index,
            usage: RawTokenUsage(),
            status: ReaderStatus(
                name: reader.name,
                state: .empty,
                message: nil,
                lastReadAt: nil,
                totalTokens: 0),
            originSlices: [])
    }

    do {
        let readAt = Date()
        let originSlices: [UsageOriginSlice]
        let usage: RawTokenUsage
        if let partitionedReader = reader as? any OriginPartitionedTokenReader {
            originSlices = try await partitionedReader.readUsageByOrigin(
                from: startDate,
                to: endDate)
            usage = combinedUsage(from: originSlices, endDate: endDate)
        } else {
            usage = try await reader.readUsage(from: startDate, to: endDate)
            let sourceStats = [sourceStat(
                from: usage,
                source: reader.name,
                includeEmpty: includeEmptySourceRows)].compactMap { $0 }
            originSlices = [UsageOriginSlice(
                origin: .local(lastUpdatedAt: readAt),
                usage: usage,
                sourceStats: sourceStats)]
        }
        let statusState: ReaderStatusState = usage.hasReportableData ? .loaded : .empty
        return ReaderFetchResult(
            index: index,
            usage: usage,
            status: ReaderStatus(
                name: reader.name,
                state: statusState,
                message: nil,
                lastReadAt: readAt,
                totalTokens: usage.totalTokens),
            originSlices: originSlices)
    } catch {
        return ReaderFetchResult(
            index: index,
            usage: RawTokenUsage(),
            status: ReaderStatus(
                name: reader.name,
                state: .failed,
                message: error.localizedDescription,
                lastReadAt: Date(),
                totalTokens: 0),
            originSlices: [])
    }
}

private struct OriginSliceAggregate {
    var origin: UsageOrigin
    var usage = RawTokenUsage()
    var sourceStats: [SourceStat] = []
    var perModelBySource: [ModelSourceUsageKey: PerModelUsage] = [:]
}

private struct SourceStatAggregate {
    let source: String
    var inputTokens = 0
    var outputTokens = 0
    var cacheReadTokens = 0
    var cacheWriteTokens = 0
    var reasoningTokens = 0
    var cost: Double = 0
    var activeSeconds: TimeInterval = 0

    mutating func merge(_ stat: SourceStat) {
        inputTokens += stat.inputTokens
        outputTokens += stat.outputTokens
        cacheReadTokens += stat.cacheReadTokens
        cacheWriteTokens += stat.cacheWriteTokens
        reasoningTokens += stat.reasoningTokens
        cost += stat.cost
        activeSeconds += stat.activeSeconds
    }

    var sourceStat: SourceStat {
        SourceStat(
            source: source,
            inputTokens: inputTokens,
            outputTokens: outputTokens,
            cacheReadTokens: cacheReadTokens,
            cacheWriteTokens: cacheWriteTokens,
            reasoningTokens: reasoningTokens,
            cost: cost,
            activeSeconds: activeSeconds)
    }
}

private func combinedUsage(
    from slices: [UsageOriginSlice],
    endDate: Date) -> RawTokenUsage {
    var combined = RawTokenUsage()
    var perModelBySource: [ModelSourceUsageKey: PerModelUsage] = [:]

    for slice in slices {
        mergePerModelUsage(
            slice.usage.perModel,
            source: fallbackSource(for: slice),
            into: &perModelBySource)
        combined += slice.usage
    }

    combined.perModelBySource = perModelBySource
    combined.recomputeMergedActiveEstimate(clippingEndDate: endDate)
    return combined
}

private func mergedOriginSlices(
    _ slices: [UsageOriginSlice],
    endDate: Date) -> [UsageOriginSlice] {
    var aggregates: [UsageOriginID: OriginSliceAggregate] = [:]

    for slice in slices {
        var aggregate = aggregates[slice.origin.id] ?? OriginSliceAggregate(origin: slice.origin)
        aggregate.origin = preferredOriginMetadata(aggregate.origin, slice.origin)
        aggregate.usage += slice.usage
        aggregate.sourceStats.append(contentsOf: slice.sourceStats)
        mergePerModelUsage(
            slice.usage.perModel,
            source: fallbackSource(for: slice),
            into: &aggregate.perModelBySource)
        aggregates[slice.origin.id] = aggregate
    }

    return aggregates.values.map { aggregate in
        var usage = aggregate.usage
        usage.perModelBySource = aggregate.perModelBySource
        usage.recomputeMergedActiveEstimate(clippingEndDate: endDate)
        return UsageOriginSlice(
            origin: aggregate.origin,
            usage: usage,
            sourceStats: mergedSourceStats(aggregate.sourceStats))
    }
    .sorted(by: originSliceSort)
}

private func mergedSourceStats(_ sourceStats: [SourceStat]) -> [SourceStat] {
    var aggregates: [String: SourceStatAggregate] = [:]
    for sourceStat in sourceStats {
        var aggregate = aggregates[sourceStat.source]
            ?? SourceStatAggregate(source: sourceStat.source)
        aggregate.merge(sourceStat)
        aggregates[sourceStat.source] = aggregate
    }
    return aggregates.values.map(\.sourceStat).sorted(by: sourceStatSort)
}

private func fallbackSource(for slice: UsageOriginSlice) -> String {
    let sources = Set(slice.sourceStats.compactMap(\.source.trimmedNonEmpty))
    if sources.count == 1, let source = sources.first {
        return source
    }
    return slice.origin.name
}

private func preferredOriginMetadata(_ lhs: UsageOrigin, _ rhs: UsageOrigin) -> UsageOrigin {
    switch (lhs.lastUpdatedAt, rhs.lastUpdatedAt) {
    case let (lhsDate?, rhsDate?):
        rhsDate >= lhsDate ? rhs : lhs
    case (nil, _?):
        rhs
    default:
        lhs
    }
}

private func originSliceSort(_ lhs: UsageOriginSlice, _ rhs: UsageOriginSlice) -> Bool {
    if lhs.origin.kind != rhs.origin.kind {
        return lhs.origin.kind == .local
    }
    let nameComparison = lhs.origin.name.localizedCaseInsensitiveCompare(rhs.origin.name)
    if nameComparison != .orderedSame {
        return nameComparison == .orderedAscending
    }
    return lhs.origin.id.rawValue < rhs.origin.id.rawValue
}

private func sourceStat(from usage: RawTokenUsage, source: String, includeEmpty: Bool) -> SourceStat? {
    guard usage.hasReportableData || includeEmpty else { return nil }

    return SourceStat(
        source: source,
        inputTokens: usage.inputTokens,
        outputTokens: usage.outputTokens,
        cacheReadTokens: usage.cacheReadTokens,
        cacheWriteTokens: usage.cacheWriteTokens,
        reasoningTokens: usage.reasoningTokens,
        cost: usage.cost,
        activeSeconds: usage.activeSeconds)
}

private func mergePerModelUsage(
    _ modelUsage: [String: PerModelUsage],
    source fallbackSource: String,
    into result: inout [ModelSourceUsageKey: PerModelUsage]) {
    guard let fallbackSource = fallbackSource.trimmedNonEmpty else { return }

    for (modelID, usage) in modelUsage {
        guard let modelID = modelID.trimmedNonEmpty else { continue }
        let usageSources = Set(usage.sources.compactMap(\.trimmedNonEmpty))
        let source = usageSources.count == 1
            ? usageSources.first ?? fallbackSource
            : fallbackSource
        let key = ModelSourceUsageKey(modelID: modelID, source: source)
        var entry = result[key] ?? PerModelUsage()
        entry.totalTokens += usage.totalTokens
        entry.cost += usage.cost
        entry.activeSeconds += usage.activeSeconds
        if usageSources.isEmpty {
            entry.sources.insert(source)
        } else {
            entry.sources.formUnion(usageSources)
        }
        result[key] = entry
    }
}

private func sourceStatSort(_ lhs: SourceStat, _ rhs: SourceStat) -> Bool {
    if lhs.activeSeconds != rhs.activeSeconds {
        return lhs.activeSeconds > rhs.activeSeconds
    }
    if lhs.totalTokens != rhs.totalTokens {
        return lhs.totalTokens > rhs.totalTokens
    }
    if lhs.cost != rhs.cost {
        return lhs.cost > rhs.cost
    }
    return lhs.source < rhs.source
}
