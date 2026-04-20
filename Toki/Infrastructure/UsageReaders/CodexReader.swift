import Foundation
import SQLite3

/// Reads ~/.codex/state_5.sqlite to discover active rollouts,
/// then reconstructs per-range usage from rollout JSONL token_count snapshots.
struct CodexReader: TokenReader {
    let name = "Codex"

    var dbPath: String {
        homeDir().appendingPathComponent(".codex/state_5.sqlite").path
    }

    func readUsage(from startDate: Date, to endDate: Date) async throws -> RawTokenUsage {
        guard FileManager.default.fileExists(atPath: dbPath) else {
            return RawTokenUsage()
        }

        let sessions = overlappingSessions(from: startDate, to: endDate)
        guard !sessions.isEmpty else { return RawTokenUsage() }

        var result = RawTokenUsage()
        var activityEvents: [ActivityTimeEvent<String>] = []
        await CodexRolloutUsageCache.shared.beginBatch()
        for session in sessions {
            let url = URL(fileURLWithPath: session.rolloutPath)
            guard FileManager.default.fileExists(atPath: url.path) else { continue }
            result += await Self.cachedUsage(
                fromRolloutAt: url,
                model: session.model,
                from: startDate,
                to: endDate)
            await activityEvents.append(
                contentsOf: Self.activityEvents(
                    fromRolloutAt: url,
                    model: session.model,
                    from: startDate,
                    to: endDate))
        }
        await CodexRolloutUsageCache.shared.endBatch()

        result.mergeActivityEvents(activityEvents, source: name, clippingEndDate: endDate)

        return result
    }
}

extension CodexReader {
    /// Preserve prior totals when timestamp backfill fails. This helper only sees
    /// data rebuilt from a full-file read, so rebuiltDailyUsage is either
    /// complete for the rollout or empty due to a transient read/decode failure.
    static func dailyUsageForTimestampBackfill(
        rebuiltDailyUsage: [String: CodexCachedDailyUsage],
        existingDailyUsage: [String: CodexCachedDailyUsage]?) -> [String: CodexCachedDailyUsage] {
        if rebuiltDailyUsage.isEmpty, let existingDailyUsage {
            return existingDailyUsage
        }
        return rebuiltDailyUsage
    }

    static func usage(
        fromRolloutLines lines: [String],
        model: String?,
        from startDate: Date,
        to endDate: Date,
        streamID: String,
        includeActivity: Bool = true) -> RawTokenUsage {
        let normalizedModel = normalizedModelID(model)

        var previousSnapshot: CodexUsageSnapshot?
        var result = RawTokenUsage()
        var activityTimestamps: [Date] = []

        for entry in codexRolloutSnapshots(fromRolloutLines: lines) {
            let delta = entry.snapshot.delta(since: previousSnapshot)
            previousSnapshot = entry.snapshot

            guard entry.date >= startDate, entry.date < endDate else { continue }

            let usage = delta.normalizedUsage
            guard usage.totalTokens > 0 else { continue }
            activityTimestamps.append(entry.date)

            result.inputTokens += usage.inputTokens
            result.outputTokens += usage.outputTokens
            result.cacheReadTokens += usage.cacheReadTokens
            result.reasoningTokens += usage.reasoningTokens

            let entryCost: Double
            if let normalizedModel, let price = modelPrice(for: normalizedModel) {
                entryCost = price.cost(
                    input: usage.inputTokens,
                    output: usage.outputTokens + usage.reasoningTokens,
                    cacheRead: usage.cacheReadTokens,
                    cacheWrite: 0)
                result.cost += entryCost
            } else {
                entryCost = 0
            }

            if let normalizedModel {
                result.perModel[normalizedModel, default: PerModelUsage()].totalTokens += usage.totalTokens
                result.perModel[normalizedModel, default: PerModelUsage()].cost += entryCost
                result.perModel[normalizedModel, default: PerModelUsage()].sources.insert("Codex")
            }
        }

        if includeActivity {
            result.mergeActivityEvents(
                activityTimestamps.map { timestamp in
                    ActivityTimeEvent(
                        streamID: streamID,
                        timestamp: timestamp,
                        key: normalizedModel)
                },
                source: "Codex",
                clippingEndDate: endDate)
        }

        return result
    }

    private static func usage(
        fromDailyUsage dailyUsage: [String: CodexCachedDailyUsage],
        model: String?,
        from startDate: Date,
        to endDate: Date) -> RawTokenUsage {
        guard !dailyUsage.isEmpty else { return RawTokenUsage() }

        let normalizedModel = normalizedModelID(model)
        let calendar = Calendar.current
        var currentDay = calendar.startOfDay(for: startDate)
        var result = RawTokenUsage()

        while currentDay < endDate {
            let dayKey = codexDayKey(for: currentDay)
            if let usage = dailyUsage[dayKey] {
                result.inputTokens += usage.inputTokens
                result.outputTokens += usage.outputTokens
                result.cacheReadTokens += usage.cacheReadTokens
                result.reasoningTokens += usage.reasoningTokens
                // Fallback aggregate retained only when activity events are absent.
                // mergeActivityEvents/recomputeMergedActiveEstimate will reset and
                // recompute activeSeconds when range-bounded events exist.
                result.activeSeconds += usage.activeSeconds

                let entryCost: Double
                if let normalizedModel, let price = modelPrice(for: normalizedModel) {
                    entryCost = price.cost(
                        input: usage.inputTokens,
                        output: usage.outputTokens + usage.reasoningTokens,
                        cacheRead: usage.cacheReadTokens,
                        cacheWrite: 0)
                    result.cost += entryCost
                } else {
                    entryCost = 0
                }

                if let normalizedModel {
                    result.perModel[normalizedModel, default: PerModelUsage()].totalTokens += usage.totalTokens
                    result.perModel[normalizedModel, default: PerModelUsage()].cost += entryCost
                    // Fallback aggregate retained only when activity events are absent.
                    // mergeActivityEvents/recomputeMergedActiveEstimate will reset and
                    // recompute per-model activeSeconds when events exist.
                    result.perModel[normalizedModel, default: PerModelUsage()].activeSeconds += usage.activeSeconds
                    result.perModel[normalizedModel, default: PerModelUsage()].sources.insert("Codex")
                }
            }

            guard let nextDay = calendar.date(byAdding: .day, value: 1, to: currentDay) else { break }
            currentDay = nextDay
        }

        return result
    }

    private static func dailyUsage(fromRolloutLines lines: [String]) -> [String: CodexCachedDailyUsage] {
        var previousSnapshot: CodexUsageSnapshot?
        var result: [String: CodexCachedDailyUsage] = [:]
        var activityTimestamps: [Date] = []

        for entry in codexRolloutSnapshots(fromRolloutLines: lines) {
            let delta = entry.snapshot.delta(since: previousSnapshot)
            previousSnapshot = entry.snapshot

            let usage = delta.normalizedUsage
            guard usage.totalTokens > 0 else { continue }
            activityTimestamps.append(entry.date)

            let dayKey = codexDayKey(for: entry.date)
            result[dayKey, default: .zero].accumulate(usage)
        }

        for (dayKey, seconds) in dailyActiveSeconds(from: activityTimestamps) {
            result[dayKey, default: .zero].activeSeconds += seconds
        }

        return result
    }

    private static func dailyActivityTimestamps(fromRolloutLines lines: [String]) -> [String: [TimeInterval]] {
        var previousSnapshot: CodexUsageSnapshot?
        var activityTimestamps: [Date] = []

        for entry in codexRolloutSnapshots(fromRolloutLines: lines) {
            let delta = entry.snapshot.delta(since: previousSnapshot)
            previousSnapshot = entry.snapshot

            guard delta.normalizedUsage.totalTokens > 0 else { continue }
            activityTimestamps.append(entry.date)
        }

        return dailyActivityTimestampValues(from: activityTimestamps)
    }
}

private extension CodexReader {
    private static func cachedUsage(
        fromRolloutAt url: URL,
        model: String?,
        from startDate: Date,
        to endDate: Date) async -> RawTokenUsage {
        guard codexIsWholeDayAlignedRange(from: startDate, to: endDate) else {
            return usage(
                fromRolloutLines: readJSONLLines(at: url),
                model: model,
                from: startDate,
                to: endDate,
                streamID: url.path,
                includeActivity: false)
        }

        let rolloutDailyUsage: [String: CodexCachedDailyUsage]
        if let cached = await CodexRolloutUsageCache.shared.dailyUsage(for: url) {
            rolloutDailyUsage = cached
        } else {
            let lines = readJSONLLines(at: url)
            rolloutDailyUsage = dailyUsage(fromRolloutLines: lines)
            await CodexRolloutUsageCache.shared.store(
                dailyUsage: rolloutDailyUsage,
                dailyActivityTimestamps: dailyActivityTimestamps(fromRolloutLines: lines),
                for: url)
        }

        return usage(fromDailyUsage: rolloutDailyUsage, model: model, from: startDate, to: endDate)
    }

    private static func activityEvents(
        fromRolloutAt url: URL,
        model: String?,
        from startDate: Date,
        to endDate: Date) async -> [ActivityTimeEvent<String>] {
        let normalizedModel = normalizedModelID(model)

        if codexIsWholeDayAlignedRange(from: startDate, to: endDate),
           let cached = await CodexRolloutUsageCache.shared.dailyActivityTimestamps(for: url) {
            let calendar = Calendar.current
            var currentDay = calendar.startOfDay(for: startDate)
            var result: [ActivityTimeEvent<String>] = []

            while currentDay < endDate {
                let dayKey = codexDayKey(for: currentDay)
                if let timestamps = cached[dayKey] {
                    result.append(
                        contentsOf: timestamps.map { timestamp in
                            ActivityTimeEvent(
                                streamID: url.path,
                                timestamp: Date(timeIntervalSince1970: timestamp),
                                key: normalizedModel)
                        })
                }

                guard let nextDay = calendar.date(byAdding: .day, value: 1, to: currentDay) else { break }
                currentDay = nextDay
            }

            return result
        }

        if codexIsWholeDayAlignedRange(from: startDate, to: endDate) {
            let existingDailyUsage = await CodexRolloutUsageCache.shared.dailyUsage(for: url)
            let lines = readJSONLLines(at: url)
            let rebuiltDailyUsage = dailyUsage(fromRolloutLines: lines)
            let dailyActivityTimestamps = dailyActivityTimestamps(fromRolloutLines: lines)
            let dailyUsageToStore = dailyUsageForTimestampBackfill(
                rebuiltDailyUsage: rebuiltDailyUsage,
                existingDailyUsage: existingDailyUsage)

            if !dailyUsageToStore.isEmpty || !dailyActivityTimestamps.isEmpty {
                await CodexRolloutUsageCache.shared.store(
                    dailyUsage: dailyUsageToStore,
                    dailyActivityTimestamps: dailyActivityTimestamps,
                    for: url)
            }

            return activityEvents(
                fromCachedTimestamps: dailyActivityTimestamps,
                streamID: url.path,
                model: normalizedModel,
                from: startDate,
                to: endDate)
        }

        var previousSnapshot: CodexUsageSnapshot?
        return codexRolloutSnapshots(fromRolloutLines: readJSONLLines(at: url)).compactMap { entry in
            let delta = entry.snapshot.delta(since: previousSnapshot)
            previousSnapshot = entry.snapshot

            guard entry.date >= startDate, entry.date < endDate else { return nil }
            guard delta.normalizedUsage.totalTokens > 0 else { return nil }

            return ActivityTimeEvent(
                streamID: url.path,
                timestamp: entry.date,
                key: normalizedModel)
        }
    }

    private static func activityEvents(
        fromCachedTimestamps cached: [String: [TimeInterval]],
        streamID: String,
        model: String?,
        from startDate: Date,
        to endDate: Date) -> [ActivityTimeEvent<String>] {
        let calendar = Calendar.current
        var currentDay = calendar.startOfDay(for: startDate)
        var result: [ActivityTimeEvent<String>] = []

        while currentDay < endDate {
            let dayKey = codexDayKey(for: currentDay)
            if let timestamps = cached[dayKey] {
                result.append(
                    contentsOf: timestamps.map { timestamp in
                        ActivityTimeEvent(
                            streamID: streamID,
                            timestamp: Date(timeIntervalSince1970: timestamp),
                            key: model)
                    })
            }

            guard let nextDay = calendar.date(byAdding: .day, value: 1, to: currentDay) else { break }
            currentDay = nextDay
        }

        return result
    }
}
