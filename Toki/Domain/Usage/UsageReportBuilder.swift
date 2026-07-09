import Foundation

enum UsageReportBuilder {
    private static let maximumHourlyBucketCount = 48

    static func report(
        from usage: RawTokenUsage,
        date: Date,
        endDate: Date,
        sourceStats: [SourceStat]) -> UsageData {
        UsageData(
            date: date,
            endDate: endDate,
            inputTokens: usage.inputTokens,
            outputTokens: usage.outputTokens,
            cacheReadTokens: usage.cacheReadTokens,
            cacheWriteTokens: usage.cacheWriteTokens,
            reasoningTokens: usage.reasoningTokens,
            cost: usage.cost,
            activeSeconds: usage.activeSeconds,
            workTime: usage.resolvedWorkTime,
            perModel: buildModelStats(from: usage),
            sourceStats: sourceStats,
            timeBuckets: buildTimeBuckets(
                from: usage.tokenEvents,
                startDate: date,
                endDate: endDate),
            projectStats: buildProjectStats(from: usage.tokenEvents),
            sessionStats: buildSessionStats(
                from: usage.tokenEvents,
                calendar: .autoupdatingCurrent),
            supplementalStats: buildSupplementalStats(from: usage.supplemental),
            contextOnlyModels: buildContextOnlyModels(from: usage.supplemental))
    }
}

private struct ProjectAggregateKey: Hashable {
    let path: String?
    let name: String
}

private struct SessionAggregateKey: Hashable {
    let source: String
    let sessionKey: String
}

private struct UsageStatAggregate {
    var inputTokens = 0
    var outputTokens = 0
    var cacheReadTokens = 0
    var cacheWriteTokens = 0
    var reasoningTokens = 0
    var cost: Double = 0
    var firstActivityAt: Date?
    var lastActivityAt: Date?
    var quality = AttributionQuality.unknown
    var sources = Set<String>()
    var sessions = Set<String>()
    var models = Set<String>()

    mutating func accumulate(_ event: TokenUsageEvent, sessionKey: String) {
        inputTokens += event.inputTokens
        outputTokens += event.outputTokens
        cacheReadTokens += event.cacheReadTokens
        cacheWriteTokens += event.cacheWriteTokens
        reasoningTokens += event.reasoningTokens
        cost += event.cost
        firstActivityAt = minOptional(firstActivityAt, event.timestamp)
        lastActivityAt = maxOptional(lastActivityAt, event.timestamp)
        quality = bestQuality(quality, event.attribution?.quality ?? .unknown)
        sources.insert(event.source)
        sessions.insert(sessionKey)
        if let model = event.model?.trimmedNonEmpty {
            models.insert(model)
        }
    }

    var totalTokens: Int {
        inputTokens + outputTokens + cacheReadTokens + cacheWriteTokens + reasoningTokens
    }
}

private struct SessionStatAggregate {
    let source: String
    var projectName: String
    var projectPath: String?
    var sessionID: String?
    var sessionLabel: String
    var quality: AttributionQuality
    var inputTokens = 0
    var outputTokens = 0
    var cacheReadTokens = 0
    var cacheWriteTokens = 0
    var reasoningTokens = 0
    var cost: Double = 0
    var firstActivityAt: Date
    var lastActivityAt: Date
    var models = Set<String>()

    mutating func accumulate(_ event: TokenUsageEvent, calendar: Calendar) {
        refreshAttributionIfNeeded(from: event, calendar: calendar)
        inputTokens += event.inputTokens
        outputTokens += event.outputTokens
        cacheReadTokens += event.cacheReadTokens
        cacheWriteTokens += event.cacheWriteTokens
        reasoningTokens += event.reasoningTokens
        cost += event.cost
        firstActivityAt = min(firstActivityAt, event.timestamp)
        lastActivityAt = max(lastActivityAt, event.timestamp)
        quality = bestQuality(quality, event.attribution?.quality ?? .unknown)
        if let model = event.model?.trimmedNonEmpty {
            models.insert(model)
        }
    }

    private mutating func refreshAttributionIfNeeded(
        from event: TokenUsageEvent,
        calendar: Calendar) {
        let candidateQuality = event.attribution?.quality ?? .unknown
        let candidateProjectName = event.attribution?.resolvedProjectName ?? "Unknown Project"
        let candidateProjectPath = event.attribution?.projectPath?.trimmedNonEmpty
        let candidateRank = sessionMetadataRank(
            projectName: candidateProjectName,
            projectPath: candidateProjectPath,
            quality: candidateQuality)
        let currentRank = sessionMetadataRank(
            projectName: projectName,
            projectPath: projectPath,
            quality: quality)

        if candidateRank > currentRank {
            projectName = candidateProjectName
            projectPath = candidateProjectPath
            sessionID = event.attribution?.sessionID?.trimmedNonEmpty
            sessionLabel = sessionLabelText(for: event, calendar: calendar)
        }

        quality = bestQuality(quality, candidateQuality)
    }

    var totalTokens: Int {
        inputTokens + outputTokens + cacheReadTokens + cacheWriteTokens + reasoningTokens
    }
}

private struct SupplementalStatAggregateKey: Hashable {
    let label: String
    let unit: SupplementalUnit
    let source: String
    let includedInTotals: Bool
    let quality: UsageQuality
}

private struct ContextOnlyModelAggregateKey: Hashable {
    let model: String
    let source: String
    let quality: UsageQuality
}

private extension UsageReportBuilder {
    static func buildTimeBuckets(
        from events: [TokenUsageEvent],
        startDate: Date,
        endDate: Date,
        calendar: Calendar = .autoupdatingCurrent) -> [UsageTimeBucket] {
        guard startDate < endDate else { return [] }

        let bucketStarts = hourlyBucketStarts(
            from: startDate,
            to: endDate,
            calendar: calendar)
        guard !bucketStarts.isEmpty else { return [] }

        var buckets = bucketStarts.reduce(into: [Date: UsageTimeBucket]()) { result, bucketStart in
            guard let nextHour = calendar.date(byAdding: .hour, value: 1, to: bucketStart) else { return }
            result[bucketStart] = .empty(
                startDate: bucketStart,
                endDate: min(nextHour, endDate))
        }

        for event in events where event.timestamp >= startDate && event.timestamp < endDate {
            guard let bucketStart = calendar.dateInterval(of: .hour, for: event.timestamp)?.start,
                  buckets[bucketStart] != nil else {
                continue
            }
            buckets[bucketStart]?.accumulate(event)
        }

        return bucketStarts.compactMap { buckets[$0] }
    }

    static func hourlyBucketStarts(
        from startDate: Date,
        to endDate: Date,
        calendar: Calendar) -> [Date] {
        guard var current = calendar.dateInterval(of: .hour, for: startDate)?.start else {
            return []
        }

        var result: [Date] = []
        while current < endDate {
            guard result.count < maximumHourlyBucketCount else {
                return []
            }

            result.append(current)
            guard let next = calendar.date(byAdding: .hour, value: 1, to: current),
                  next > current else {
                break
            }
            current = next
        }
        return result
    }

    static func buildProjectStats(from events: [TokenUsageEvent]) -> [ProjectUsageStat] {
        var aggregates: [ProjectAggregateKey: UsageStatAggregate] = [:]
        let calendar = Calendar.autoupdatingCurrent
        let attributionBySession = bestAttributionsBySession(from: events, calendar: calendar)

        for event in events where event.totalTokens > 0 {
            let eventSessionKey = sessionGroupingKey(for: event, calendar: calendar)
            let sessionKey = SessionAggregateKey(source: event.source, sessionKey: eventSessionKey)
            let attribution = attributionBySession[sessionKey] ?? event.attribution
            let key = ProjectAggregateKey(
                path: attribution?.projectPath?.trimmedNonEmpty,
                name: attribution?.resolvedProjectName ?? "Unknown Project")
            aggregates[key, default: UsageStatAggregate()].accumulate(
                event,
                sessionKey: projectSessionKey(source: event.source, sessionKey: eventSessionKey))
        }

        return aggregates.map { key, aggregate in
            ProjectUsageStat(
                id: projectStatID(for: key),
                name: key.name,
                path: key.path,
                quality: aggregate.quality,
                sources: aggregate.sources.sorted(),
                sessionCount: aggregate.sessions.count,
                inputTokens: aggregate.inputTokens,
                outputTokens: aggregate.outputTokens,
                cacheReadTokens: aggregate.cacheReadTokens,
                cacheWriteTokens: aggregate.cacheWriteTokens,
                reasoningTokens: aggregate.reasoningTokens,
                cost: aggregate.cost,
                firstActivityAt: aggregate.firstActivityAt,
                lastActivityAt: aggregate.lastActivityAt)
        }
        .sorted(by: projectStatSort)
    }

    static func buildSessionStats(
        from events: [TokenUsageEvent],
        calendar: Calendar) -> [SessionUsageStat] {
        var aggregates: [SessionAggregateKey: SessionStatAggregate] = [:]

        for event in events where event.totalTokens > 0 {
            let attribution = event.attribution
            let sessionKey = sessionGroupingKey(for: event, calendar: calendar)
            let key = SessionAggregateKey(source: event.source, sessionKey: sessionKey)

            if aggregates[key] == nil {
                aggregates[key] = SessionStatAggregate(
                    source: event.source,
                    projectName: attribution?.resolvedProjectName ?? "Unknown Project",
                    projectPath: attribution?.projectPath?.trimmedNonEmpty,
                    sessionID: attribution?.sessionID?.trimmedNonEmpty,
                    sessionLabel: sessionLabelText(for: event, calendar: calendar),
                    quality: attribution?.quality ?? .unknown,
                    firstActivityAt: event.timestamp,
                    lastActivityAt: event.timestamp)
            }

            aggregates[key]?.accumulate(event, calendar: calendar)
        }

        return aggregates.map { key, aggregate in
            SessionUsageStat(
                id: "\(key.source)|\(key.sessionKey)",
                source: aggregate.source,
                projectName: aggregate.projectName,
                projectPath: aggregate.projectPath,
                sessionID: aggregate.sessionID,
                sessionLabel: aggregate.sessionLabel,
                quality: aggregate.quality,
                models: aggregate.models.sorted(),
                inputTokens: aggregate.inputTokens,
                outputTokens: aggregate.outputTokens,
                cacheReadTokens: aggregate.cacheReadTokens,
                cacheWriteTokens: aggregate.cacheWriteTokens,
                reasoningTokens: aggregate.reasoningTokens,
                cost: aggregate.cost,
                firstActivityAt: aggregate.firstActivityAt,
                lastActivityAt: aggregate.lastActivityAt)
        }
        .sorted(by: sessionStatSort)
    }

    static func buildSupplementalStats(from supplemental: [SupplementalUsage]) -> [SupplementalStat] {
        var grouped: [SupplementalStatAggregateKey: Int] = [:]

        supplemental
            .filter { $0.value > 0 }
            .forEach { item in
                let key = SupplementalStatAggregateKey(
                    label: item.label,
                    unit: item.unit,
                    source: item.source,
                    includedInTotals: item.includedInTotals,
                    quality: item.quality)
                grouped[key, default: 0] += item.value
            }

        return grouped.map { key, value in
            SupplementalStat(
                id: "\(key.source)|\(key.label)|\(key.unit.rawValue)|\(key.includedInTotals)|\(key.quality.rawValue)",
                label: key.label,
                value: value,
                unit: key.unit,
                source: key.source,
                includedInTotals: key.includedInTotals,
                quality: key.quality)
        }
        .sorted { lhs, rhs in
            let lhsPriority = supplementalSortPriority(for: lhs)
            let rhsPriority = supplementalSortPriority(for: rhs)
            if lhsPriority != rhsPriority { return lhsPriority < rhsPriority }
            if lhs.source != rhs.source { return lhs.source < rhs.source }
            return lhs.value > rhs.value
        }
    }

    static func buildContextOnlyModels(from supplemental: [SupplementalUsage]) -> [ContextOnlyModelStat] {
        var grouped: [ContextOnlyModelAggregateKey: Int] = [:]

        supplemental
            .filter {
                $0.value > 0
                    && $0.unit == .tokens
                    && $0.quality == .contextOnly
                    && $0.model != nil
            }
            .forEach { item in
                let key = ContextOnlyModelAggregateKey(
                    model: item.model ?? "",
                    source: item.source,
                    quality: item.quality)
                grouped[key, default: 0] += item.value
            }

        return grouped.map { key, value in
            ContextOnlyModelStat(
                id: "\(key.model)|\(key.source)|\(key.quality.rawValue)",
                model: key.model,
                source: key.source,
                contextTokens: value,
                quality: key.quality)
        }
        .sorted { lhs, rhs in
            if lhs.contextTokens != rhs.contextTokens { return lhs.contextTokens > rhs.contextTokens }
            if lhs.model != rhs.model { return lhs.model < rhs.model }
            return lhs.source < rhs.source
        }
    }

    static func supplementalSortPriority(for stat: SupplementalStat) -> Int {
        if stat.label.contains("Context") { return 0 }
        if stat.label.contains("Sessions") { return 1 }
        if stat.label.contains("Reported Cost") { return 2 }

        switch stat.unit {
        case .tokens:
            return 3
        case .count:
            return 4
        case .cents:
            return 5
        }
    }
}

private func sessionGroupingKey(
    for event: TokenUsageEvent,
    calendar: Calendar) -> String {
    if let sessionID = event.attribution?.sessionID?.trimmedNonEmpty {
        return sessionID
    }

    let projectKey = event.attribution?.projectPath?.trimmedNonEmpty
        ?? event.attribution?.projectName?.trimmedNonEmpty
        ?? "unknown"
    let hourStart = calendar.dateInterval(of: .hour, for: event.timestamp)?.start
        ?? event.timestamp
    return "\(projectKey)|\(Int(hourStart.timeIntervalSince1970))"
}

private func projectSessionKey(source: String, sessionKey: String) -> String {
    "\(source)|\(sessionKey)"
}

private func bestAttributionsBySession(
    from events: [TokenUsageEvent],
    calendar: Calendar) -> [SessionAggregateKey: UsageAttribution] {
    events.reduce(into: [:]) { result, event in
        let sessionKey = sessionGroupingKey(for: event, calendar: calendar)
        let key = SessionAggregateKey(source: event.source, sessionKey: sessionKey)
        result[key] = bestUsageAttribution(result[key], event.attribution)
    }
}

private func sessionLabelText(
    for event: TokenUsageEvent,
    calendar: Calendar) -> String {
    if let label = event.attribution?.sessionLabel?.trimmedNonEmpty {
        return label
    }

    if let sessionID = event.attribution?.sessionID?.trimmedNonEmpty {
        return shortSessionLabel(sessionID)
    }

    let hourStart = calendar.dateInterval(of: .hour, for: event.timestamp)?.start
        ?? event.timestamp
    return "\(sessionHourFormatter.string(from: hourStart)) session"
}

private func shortSessionLabel(_ sessionID: String) -> String {
    let fileName = usageSessionID(fromPath: sessionID)
    guard fileName.count > 10 else { return fileName }
    return String(fileName.prefix(10))
}

private func bestQuality(_ lhs: AttributionQuality, _ rhs: AttributionQuality) -> AttributionQuality {
    qualityRank(rhs) > qualityRank(lhs) ? rhs : lhs
}

private func qualityRank(_ quality: AttributionQuality) -> Int {
    switch quality {
    case .exact:
        3
    case .inferred:
        2
    case .unknown:
        1
    }
}

private func sessionMetadataRank(
    projectName: String,
    projectPath: String?,
    quality: AttributionQuality) -> Int {
    let pathScore = projectPath == nil ? 0 : 10
    let nameScore = projectName == "Unknown Project" ? 0 : 1
    return qualityRank(quality) * 100 + pathScore + nameScore
}

private func minOptional(_ lhs: Date?, _ rhs: Date) -> Date {
    guard let lhs else { return rhs }
    return min(lhs, rhs)
}

private func maxOptional(_ lhs: Date?, _ rhs: Date) -> Date {
    guard let lhs else { return rhs }
    return max(lhs, rhs)
}

private func projectStatSort(_ lhs: ProjectUsageStat, _ rhs: ProjectUsageStat) -> Bool {
    if lhs.cost != rhs.cost {
        return lhs.cost > rhs.cost
    }
    if lhs.totalTokens != rhs.totalTokens {
        return lhs.totalTokens > rhs.totalTokens
    }
    return lhs.name < rhs.name
}

private func projectStatID(for key: ProjectAggregateKey) -> String {
    key.path ?? "project-name|\(key.name)"
}

private func sessionStatSort(_ lhs: SessionUsageStat, _ rhs: SessionUsageStat) -> Bool {
    if lhs.cost != rhs.cost {
        return lhs.cost > rhs.cost
    }
    if lhs.totalTokens != rhs.totalTokens {
        return lhs.totalTokens > rhs.totalTokens
    }
    if lhs.lastActivityAt != rhs.lastActivityAt {
        return lhs.lastActivityAt > rhs.lastActivityAt
    }
    return lhs.sessionLabel < rhs.sessionLabel
}

private let sessionHourFormatter: DateFormatter = {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.dateFormat = "HH:mm"
    return formatter
}()
