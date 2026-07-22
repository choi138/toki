import Foundation
import TokiUsageCore

#if os(Linux)
    import CSQLite
#else
    import SQLite3
#endif

/// Reads ~/.codex/state_5.sqlite to discover active rollouts,
/// then reconstructs per-range usage from rollout JSONL token_count snapshots.
public struct CodexReader: TokenReader {
    public let name = "Codex"
    public let dbPath: String
    public let rolloutUsageCache: CodexRolloutUsageCache

    public init(
        dbPath: String = homeDir().appendingPathComponent(".codex/state_5.sqlite").path,
        rolloutUsageCache: CodexRolloutUsageCache = .shared) {
        self.dbPath = dbPath
        self.rolloutUsageCache = rolloutUsageCache
    }

    public func readUsage(from startDate: Date, to endDate: Date) async throws -> RawTokenUsage {
        guard !Task.isCancelled,
              FileManager.default.fileExists(atPath: dbPath) else {
            return RawTokenUsage()
        }

        let sessions = overlappingSessions(from: startDate, to: endDate)
        guard !Task.isCancelled, !sessions.isEmpty else { return RawTokenUsage() }

        var result = RawTokenUsage()
        var activityEvents: [ActivityTimeEvent<String>] = []
        let cacheBatch = await rolloutUsageCache.beginBatch(retaining: sessions.map(\.rolloutPath))
        for session in sessions {
            guard !Task.isCancelled else { break }

            let url = URL(fileURLWithPath: session.rolloutPath)
            guard FileManager.default.fileExists(atPath: url.path) else { continue }
            let cachedUsageForSession = await Self.cachedUsage(
                fromRolloutAt: url,
                model: session.model,
                agentKind: session.agentKind,
                attribution: session.attribution,
                from: startDate,
                to: endDate,
                cache: rolloutUsageCache)
            guard !Task.isCancelled else { break }

            let sessionEvents = await Self.activityEvents(
                fromRolloutAt: url,
                model: session.model,
                agentKind: session.agentKind,
                from: startDate,
                to: endDate,
                cache: rolloutUsageCache)
            guard !Task.isCancelled else { break }

            let sessionUsage = Self.strippingCachedActiveTime(
                from: cachedUsageForSession,
                whenActivityEventsExist: sessionEvents)
            result += sessionUsage
            activityEvents.append(contentsOf: sessionEvents)
        }
        await rolloutUsageCache.endBatch(cacheBatch)

        guard !Task.isCancelled else { return RawTokenUsage() }
        result.mergeActivityEvents(activityEvents, source: name, clippingEndDate: endDate)

        return result
    }

    public func readTotalTokens(from startDate: Date, to endDate: Date) async throws -> Int {
        try await readDailyTokenValue(
            from: startDate,
            to: endDate,
            dailyValue: \.totalTokens,
            fallbackValue: \.totalTokens)
    }

    public func readOutputTokens(from startDate: Date, to endDate: Date) async throws -> Int {
        try await readDailyTokenValue(
            from: startDate,
            to: endDate,
            dailyValue: \.outputTokens,
            fallbackValue: \.outputTokens)
    }

    private func readDailyTokenValue(
        from startDate: Date,
        to endDate: Date,
        dailyValue: (CodexCachedDailyUsage) -> Int,
        fallbackValue: (RawTokenUsage) -> Int) async throws -> Int {
        guard !Task.isCancelled,
              FileManager.default.fileExists(atPath: dbPath) else {
            return 0
        }

        guard codexIsWholeDayAlignedRange(from: startDate, to: endDate) else {
            return try await fallbackValue(readUsage(from: startDate, to: endDate))
        }

        let sessions = overlappingSessions(
            from: startDate,
            to: endDate,
            requiresProjectAttribution: false)
        guard !Task.isCancelled, !sessions.isEmpty else { return 0 }

        var outputTokens = 0
        let cacheBatch = await rolloutUsageCache.beginBatch(retaining: sessions.map(\.rolloutPath))
        for session in sessions {
            guard !Task.isCancelled else { break }

            let url = URL(fileURLWithPath: session.rolloutPath)
            guard FileManager.default.fileExists(atPath: url.path) else { continue }
            let summary = await Self.cachedDailySummary(
                fromRolloutAt: url,
                cache: rolloutUsageCache)
            outputTokens += Self.dailyTokenSum(
                fromDailyUsage: summary.dailyUsage,
                from: startDate,
                to: endDate,
                value: dailyValue)
        }
        await rolloutUsageCache.endBatch(cacheBatch)

        return Task.isCancelled ? 0 : outputTokens
    }
}

extension CodexReader {
    /// Cached daily usage may already contain an estimated activeSeconds total.
    /// Zero it when rollout events exist so mergeActivityEvents() recomputes from
    /// event timestamps without double-counting the cached estimate.
    static func strippingCachedActiveTime(
        from usage: RawTokenUsage,
        whenActivityEventsExist events: [ActivityTimeEvent<String>]) -> RawTokenUsage {
        guard !events.isEmpty else { return usage }

        var sanitizedUsage = usage
        sanitizedUsage.activeSeconds = 0
        sanitizedUsage.workTime = .zero
        sanitizedUsage.fallbackWorkTime = .zero
        sanitizedUsage.fallbackActiveSeconds = 0
        sanitizedUsage.fallbackActiveSecondsByModel = [:]
        sanitizedUsage.perModel = sanitizedUsage.perModel.mapValues { usage in
            var sanitizedPerModelUsage = usage
            sanitizedPerModelUsage.activeSeconds = 0
            return sanitizedPerModelUsage
        }
        return sanitizedUsage
    }

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
        agentKind: WorkTimeAgentKind = .main,
        attribution: UsageAttribution? = nil,
        includeActivity: Bool = true) -> RawTokenUsage {
        let normalizedModel = normalizedModelID(model)

        var previousSnapshot: CodexUsageSnapshot?
        var result = RawTokenUsage()
        var activityTimestamps: [Date] = []

        for entry in codexRolloutSnapshots(fromRolloutLines: lines) {
            guard !Task.isCancelled else { return RawTokenUsage() }

            let usage = entry.usage(since: previousSnapshot)
            previousSnapshot = entry.tokenCount.nextBaseline(after: previousSnapshot)

            guard entry.date >= startDate, entry.date < endDate else { continue }

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

            result.recordTokenEvent(
                timestamp: entry.date,
                source: "Codex",
                model: normalizedModel,
                inputTokens: usage.inputTokens,
                outputTokens: usage.outputTokens,
                cacheReadTokens: usage.cacheReadTokens,
                reasoningTokens: usage.reasoningTokens,
                cost: entryCost,
                attribution: attribution)
        }

        if includeActivity {
            result.mergeActivityEvents(
                activityTimestamps.map { timestamp in
                    ActivityTimeEvent(
                        streamID: streamID,
                        timestamp: timestamp,
                        key: normalizedModel,
                        agentKind: agentKind)
                },
                source: "Codex",
                clippingEndDate: endDate)
        }

        return result
    }

    private static func usage(
        fromDailyUsage dailyUsage: [String: CodexCachedDailyUsage],
        model: String?,
        agentKind: WorkTimeAgentKind,
        from startDate: Date,
        to endDate: Date) -> RawTokenUsage {
        guard !dailyUsage.isEmpty else { return RawTokenUsage() }

        let normalizedModel = normalizedModelID(model)
        let calendar = Calendar.current
        var currentDay = calendar.startOfDay(for: startDate)
        var result = RawTokenUsage()

        while currentDay < endDate {
            guard !Task.isCancelled else { return RawTokenUsage() }

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

        if result.activeSeconds > 0 {
            let streamCount = result.activeSeconds > 0 ? 1 : 0
            result.workTime = WorkTimeMetrics(
                agentSeconds: result.activeSeconds,
                wallClockSeconds: result.activeSeconds,
                activeStreamCount: streamCount,
                maxConcurrentStreams: streamCount,
                mainAgentSeconds: agentKind == .main ? result.activeSeconds : 0,
                subagentSeconds: agentKind == .subagent ? result.activeSeconds : 0)
        }

        return result
    }

    private static func dailyUsage(fromRolloutLines lines: [String]) -> [String: CodexCachedDailyUsage] {
        codexRolloutDailySummary(fromSnapshots: codexRolloutSnapshots(fromRolloutLines: lines)).dailyUsage
    }

    private static func dailyActivityTimestamps(fromRolloutLines lines: [String]) -> [String: [TimeInterval]] {
        codexRolloutDailySummary(fromSnapshots: codexRolloutSnapshots(fromRolloutLines: lines))
            .dailyActivityTimestamps
    }
}

extension CodexReader {
    private static func cachedDailySummary(
        fromRolloutAt url: URL,
        cache: CodexRolloutUsageCache) async -> CodexRolloutDailySummary {
        let cachedDailyUsage = await cache.dailyUsage(for: url)
        let cachedActivityTimestamps = await cache.dailyActivityTimestamps(for: url)
        let cachedTokenUsageEvents = await cache.dailyTokenUsageEvents(for: url)

        if let cachedDailyUsage,
           let cachedActivityTimestamps,
           let cachedTokenUsageEvents {
            return CodexRolloutDailySummary(
                dailyUsage: cachedDailyUsage,
                dailyActivityTimestamps: cachedActivityTimestamps,
                dailyTokenUsageEvents: cachedTokenUsageEvents)
        }

        let rebuiltSummary = codexRolloutDailySummary(fromRolloutAt: url)
        guard !Task.isCancelled else { return CodexRolloutDailySummary() }

        let summaryToStore = CodexRolloutDailySummary(
            dailyUsage: dailyUsageForTimestampBackfill(
                rebuiltDailyUsage: rebuiltSummary.dailyUsage,
                existingDailyUsage: cachedDailyUsage),
            dailyActivityTimestamps: rebuiltSummary.dailyActivityTimestamps,
            dailyTokenUsageEvents: rebuiltSummary.dailyTokenUsageEvents)

        if !summaryToStore.isEmpty {
            await cache.store(
                dailyUsage: summaryToStore.dailyUsage,
                dailyActivityTimestamps: summaryToStore.dailyActivityTimestamps,
                dailyTokenUsageEvents: summaryToStore.dailyTokenUsageEvents,
                for: url)
        }

        return summaryToStore
    }

    private static func cachedUsage(
        fromRolloutAt url: URL,
        model: String?,
        agentKind: WorkTimeAgentKind,
        attribution: UsageAttribution,
        from startDate: Date,
        to endDate: Date,
        cache: CodexRolloutUsageCache) async -> RawTokenUsage {
        guard !Task.isCancelled else { return RawTokenUsage() }

        guard codexIsWholeDayAlignedRange(from: startDate, to: endDate) else {
            return usage(
                fromRolloutLines: readJSONLLines(at: url),
                model: model,
                from: startDate,
                to: endDate,
                streamID: url.path,
                attribution: attribution,
                includeActivity: false)
        }

        let summary = await cachedDailySummary(fromRolloutAt: url, cache: cache)

        var result = usage(
            fromDailyUsage: summary.dailyUsage,
            model: model,
            agentKind: agentKind,
            from: startDate,
            to: endDate)
        result.tokenEvents = tokenEvents(
            fromCachedDailyTokenUsageEvents: summary.dailyTokenUsageEvents,
            model: model,
            attribution: attribution,
            from: startDate,
            to: endDate)
        return result
    }

    private static func activityEvents(
        fromRolloutAt url: URL,
        model: String?,
        agentKind: WorkTimeAgentKind,
        from startDate: Date,
        to endDate: Date,
        cache: CodexRolloutUsageCache) async -> [ActivityTimeEvent<String>] {
        guard !Task.isCancelled else { return [] }

        let normalizedModel = normalizedModelID(model)

        if codexIsWholeDayAlignedRange(from: startDate, to: endDate),
           let cached = await cache.dailyActivityTimestamps(for: url) {
            let calendar = Calendar.current
            var currentDay = calendar.startOfDay(for: startDate)
            var result: [ActivityTimeEvent<String>] = []

            while currentDay < endDate {
                guard !Task.isCancelled else { return [] }

                let dayKey = codexDayKey(for: currentDay)
                if let timestamps = cached[dayKey] {
                    result.append(
                        contentsOf: timestamps.map { timestamp in
                            ActivityTimeEvent(
                                streamID: url.path,
                                timestamp: Date(timeIntervalSince1970: timestamp),
                                key: normalizedModel,
                                agentKind: agentKind)
                        })
                }

                guard let nextDay = calendar.date(byAdding: .day, value: 1, to: currentDay) else { break }
                currentDay = nextDay
            }

            return result
        }

        if codexIsWholeDayAlignedRange(from: startDate, to: endDate) {
            let summary = await cachedDailySummary(fromRolloutAt: url, cache: cache)

            return activityEvents(
                fromCachedTimestamps: summary.dailyActivityTimestamps,
                streamID: url.path,
                model: normalizedModel,
                agentKind: agentKind,
                from: startDate,
                to: endDate)
        }

        var previousSnapshot: CodexUsageSnapshot?
        return codexRolloutSnapshots(fromRolloutLines: readJSONLLines(at: url)).compactMap { entry in
            guard !Task.isCancelled else { return nil }

            let usage = entry.usage(since: previousSnapshot)
            previousSnapshot = entry.tokenCount.nextBaseline(after: previousSnapshot)

            guard entry.date >= startDate, entry.date < endDate else { return nil }
            guard usage.totalTokens > 0 else { return nil }

            return ActivityTimeEvent(
                streamID: url.path,
                timestamp: entry.date,
                key: normalizedModel,
                agentKind: agentKind)
        }
    }

    private static func activityEvents(
        fromCachedTimestamps cached: [String: [TimeInterval]],
        streamID: String,
        model: String?,
        agentKind: WorkTimeAgentKind,
        from startDate: Date,
        to endDate: Date) -> [ActivityTimeEvent<String>] {
        let calendar = Calendar.current
        var currentDay = calendar.startOfDay(for: startDate)
        var result: [ActivityTimeEvent<String>] = []

        while currentDay < endDate {
            guard !Task.isCancelled else { return [] }

            let dayKey = codexDayKey(for: currentDay)
            if let timestamps = cached[dayKey] {
                result.append(
                    contentsOf: timestamps.map { timestamp in
                        ActivityTimeEvent(
                            streamID: streamID,
                            timestamp: Date(timeIntervalSince1970: timestamp),
                            key: model,
                            agentKind: agentKind)
                    })
            }

            guard let nextDay = calendar.date(byAdding: .day, value: 1, to: currentDay) else { break }
            currentDay = nextDay
        }

        return result
    }

    private static func tokenEvents(
        fromCachedDailyTokenUsageEvents cached: [String: [CodexCachedTokenUsageEvent]],
        model: String?,
        attribution: UsageAttribution,
        from startDate: Date,
        to endDate: Date) -> [TokenUsageEvent] {
        let normalizedModel = normalizedModelID(model)
        let calendar = Calendar.current
        var currentDay = calendar.startOfDay(for: startDate)
        var result: [TokenUsageEvent] = []

        while currentDay < endDate {
            guard !Task.isCancelled else { return [] }

            let dayKey = codexDayKey(for: currentDay)
            if let events = cached[dayKey] {
                result.append(
                    contentsOf: events.compactMap { event in
                        let timestamp = Date(timeIntervalSince1970: event.timestamp)
                        guard timestamp >= startDate, timestamp < endDate else { return nil }

                        let eventCost: Double = if let normalizedModel, let price = modelPrice(for: normalizedModel) {
                            price.cost(
                                input: event.inputTokens,
                                output: event.outputTokens + event.reasoningTokens,
                                cacheRead: event.cacheReadTokens,
                                cacheWrite: 0)
                        } else {
                            0
                        }

                        return TokenUsageEvent(
                            timestamp: timestamp,
                            source: "Codex",
                            model: normalizedModel,
                            inputTokens: event.inputTokens,
                            outputTokens: event.outputTokens,
                            cacheReadTokens: event.cacheReadTokens,
                            cacheWriteTokens: 0,
                            reasoningTokens: event.reasoningTokens,
                            cost: eventCost,
                            attribution: attribution)
                    })
            }

            guard let nextDay = calendar.date(byAdding: .day, value: 1, to: currentDay) else { break }
            currentDay = nextDay
        }

        return result
    }
}
