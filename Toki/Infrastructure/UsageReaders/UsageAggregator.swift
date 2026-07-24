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
    let readerStatuses: [ReaderStatus]
}

final class UsageAggregator {
    static let defaultReaders: [any TokenReader] = LocalUsageReaderRegistry.readers() + [
        RemoteUsageReader(localAgentIdentityProvider: LocalAgentIdentityProvider()),
    ]

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
            readerStatuses: summary.readerStatuses)
    }

    func aggregateTotalTokens(for request: UsageAggregationRequest) async -> Int {
        await fetchTotalTokens(for: request)
    }

    func aggregateOutputTokens(for request: UsageAggregationRequest) async -> Int {
        await fetchOutputTokens(for: request)
    }
}

private struct ReaderFetchResult {
    let index: Int
    let usage: RawTokenUsage
    let status: ReaderStatus
    let sourceStats: [SourceStat]
}

private struct UsageFetchSummary {
    var usage = RawTokenUsage()
    var readerStatuses: [ReaderStatus] = []
    var sourceStats: [SourceStat] = []
}

private extension UsageAggregator {
    func fetchTotalTokens(for request: UsageAggregationRequest) async -> Int {
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

    func fetchOutputTokens(for request: UsageAggregationRequest) async -> Int {
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
                sourceStats: [])
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
        var combined = RawTokenUsage()
        var perModelBySource: [ModelSourceUsageKey: PerModelUsage] = [:]
        for result in sortedResults {
            mergePerModelUsage(
                result.usage.perModel,
                source: result.status.name,
                into: &perModelBySource)
            combined += result.usage
        }
        combined.perModelBySource = perModelBySource
        combined.recomputeMergedActiveEstimate(clippingEndDate: request.end)

        return UsageFetchSummary(
            usage: combined,
            readerStatuses: sortedResults.map(\.status),
            sourceStats: mergedSourceStats(sortedResults.flatMap(\.sourceStats))
                .sorted(by: sourceStatSort))
    }
}

private func readerTotalTokens(
    reader: any TokenReader,
    from startDate: Date,
    to endDate: Date) async -> Int {
    guard !Task.isCancelled else { return 0 }

    do {
        return try await reader.readTotalTokens(from: startDate, to: endDate)
    } catch {
        return 0
    }
}

private func readerOutputTokens(
    reader: any TokenReader,
    from startDate: Date,
    to endDate: Date) async -> Int {
    guard !Task.isCancelled else { return 0 }

    do {
        return try await reader.readOutputTokens(from: startDate, to: endDate)
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
            sourceStats: [])
    }

    do {
        let readerUsage = try await readUsageAndSourceStats(
            reader: reader,
            includeEmptySourceRows: includeEmptySourceRows,
            from: startDate,
            to: endDate)
        let usage = readerUsage.usage
        let statusState: ReaderStatusState = usage.hasReportableData ? .loaded : .empty
        return ReaderFetchResult(
            index: index,
            usage: usage,
            status: ReaderStatus(
                name: reader.name,
                state: statusState,
                message: nil,
                lastReadAt: Date(),
                totalTokens: usage.totalTokens),
            sourceStats: readerUsage.sourceStats)
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
            sourceStats: [])
    }
}

private func readUsageAndSourceStats(
    reader: any TokenReader,
    includeEmptySourceRows: Bool,
    from startDate: Date,
    to endDate: Date) async throws -> (usage: RawTokenUsage, sourceStats: [SourceStat]) {
    guard let partitionedReader = reader as? any OriginPartitionedTokenReader else {
        let usage = try await reader.readUsage(from: startDate, to: endDate)
        return (
            usage,
            sourceStat(from: usage, source: reader.name, includeEmpty: includeEmptySourceRows).map { [$0] } ?? [])
    }

    let slices = try await partitionedReader.readUsageByOrigin(from: startDate, to: endDate)
    var usage = RawTokenUsage()
    for slice in slices {
        usage += slice.usage
    }
    usage.recomputeMergedActiveEstimate(clippingEndDate: endDate)
    let sourceStats = mergedSourceStats(slices.flatMap(\.sourceStats))
    if sourceStats.isEmpty, includeEmptySourceRows,
       let emptyStat = sourceStat(from: usage, source: reader.name, includeEmpty: true) {
        return (usage, [emptyStat])
    }
    return (usage, sourceStats)
}

private func mergedSourceStats(_ sourceStats: [SourceStat]) -> [SourceStat] {
    var merged: [String: SourceStat] = [:]
    for stat in sourceStats {
        let current = merged[stat.source]
        merged[stat.source] = SourceStat(
            source: stat.source,
            inputTokens: (current?.inputTokens ?? 0) + stat.inputTokens,
            outputTokens: (current?.outputTokens ?? 0) + stat.outputTokens,
            cacheReadTokens: (current?.cacheReadTokens ?? 0) + stat.cacheReadTokens,
            cacheWriteTokens: (current?.cacheWriteTokens ?? 0) + stat.cacheWriteTokens,
            reasoningTokens: (current?.reasoningTokens ?? 0) + stat.reasoningTokens,
            cost: (current?.cost ?? 0) + stat.cost,
            activeSeconds: (current?.activeSeconds ?? 0) + stat.activeSeconds)
    }
    return Array(merged.values)
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
