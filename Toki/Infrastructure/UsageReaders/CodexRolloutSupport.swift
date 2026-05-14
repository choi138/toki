import Foundation

actor CodexRolloutUsageCache {
    static let shared = CodexRolloutUsageCache()

    private var isLoaded = false
    private var entries: [String: CodexRolloutUsageCacheEntry] = [:]
    private var batchDepth = 0
    private var hasPendingChanges = false

    func beginBatch() async {
        await loadIfNeeded()
        batchDepth += 1
    }

    func endBatch() async {
        await loadIfNeeded()
        batchDepth = max(0, batchDepth - 1)
        persistIfNeeded()
    }

    func dailyUsage(for url: URL) async -> [String: CodexCachedDailyUsage]? {
        await loadIfNeeded()

        guard let fileSignature = codexFileSignature(for: url),
              let cached = entries[url.path],
              cached.fileSize == fileSignature.fileSize,
              cached.modifiedAt == fileSignature.modifiedAt,
              cached.timeZoneIdentifier == codexCacheTimeZoneIdentifier() else {
            return nil
        }

        return cached.dailyUsage
    }

    func dailyActivityTimestamps(for url: URL) async -> [String: [TimeInterval]]? {
        await loadIfNeeded()

        guard let fileSignature = codexFileSignature(for: url),
              let cached = entries[url.path],
              cached.fileSize == fileSignature.fileSize,
              cached.modifiedAt == fileSignature.modifiedAt,
              cached.timeZoneIdentifier == codexCacheTimeZoneIdentifier() else {
            return nil
        }

        if cached.dailyActivityTimestamps.isEmpty,
           cached.dailyUsage.values.contains(where: { $0.totalTokens > 0 }) {
            return nil
        }

        return cached.dailyActivityTimestamps
    }

    func dailyTokenUsageEvents(for url: URL) async -> [String: [CodexCachedTokenUsageEvent]]? {
        await loadIfNeeded()

        guard let fileSignature = codexFileSignature(for: url),
              let cached = entries[url.path],
              cached.fileSize == fileSignature.fileSize,
              cached.modifiedAt == fileSignature.modifiedAt,
              cached.timeZoneIdentifier == codexCacheTimeZoneIdentifier() else {
            return nil
        }

        if cached.dailyTokenUsageEvents.isEmpty,
           cached.dailyUsage.values.contains(where: { $0.totalTokens > 0 }) {
            return nil
        }

        return cached.dailyTokenUsageEvents
    }

    func store(
        dailyUsage: [String: CodexCachedDailyUsage],
        dailyActivityTimestamps: [String: [TimeInterval]],
        dailyTokenUsageEvents: [String: [CodexCachedTokenUsageEvent]] = [:],
        for url: URL) async {
        await loadIfNeeded()

        guard let fileSignature = codexFileSignature(for: url) else { return }

        entries[url.path] = CodexRolloutUsageCacheEntry(
            fileSize: fileSignature.fileSize,
            modifiedAt: fileSignature.modifiedAt,
            timeZoneIdentifier: codexCacheTimeZoneIdentifier(),
            dailyUsage: dailyUsage,
            dailyActivityTimestamps: dailyActivityTimestamps,
            dailyTokenUsageEvents: dailyTokenUsageEvents)

        hasPendingChanges = true
        persistIfNeeded()
    }

    private func loadIfNeeded() async {
        guard !isLoaded else { return }
        isLoaded = true

        guard let data = try? Data(contentsOf: codexRolloutUsageCacheURL()),
              let decoded = try? JSONDecoder().decode(CodexRolloutUsageCacheFile.self, from: data) else {
            entries = [:]
            return
        }

        entries = decoded.entries
    }

    private func persistIfNeeded() {
        guard hasPendingChanges, batchDepth == 0 else { return }

        let cacheURL = codexRolloutUsageCacheURL()
        let directory = cacheURL.deletingLastPathComponent()
        try? FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: nil)

        let payload = CodexRolloutUsageCacheFile(entries: entries)
        guard let data = try? JSONEncoder().encode(payload) else { return }
        try? data.write(to: cacheURL, options: [.atomic])
        hasPendingChanges = false
    }
}

struct CodexRolloutUsageCacheFile: Codable {
    let entries: [String: CodexRolloutUsageCacheEntry]
}

struct CodexRolloutUsageCacheEntry: Codable {
    let fileSize: Int
    let modifiedAt: TimeInterval
    let timeZoneIdentifier: String
    let dailyUsage: [String: CodexCachedDailyUsage]
    let dailyActivityTimestamps: [String: [TimeInterval]]
    let dailyTokenUsageEvents: [String: [CodexCachedTokenUsageEvent]]

    init(
        fileSize: Int,
        modifiedAt: TimeInterval,
        timeZoneIdentifier: String,
        dailyUsage: [String: CodexCachedDailyUsage],
        dailyActivityTimestamps: [String: [TimeInterval]] = [:],
        dailyTokenUsageEvents: [String: [CodexCachedTokenUsageEvent]] = [:]) {
        self.fileSize = fileSize
        self.modifiedAt = modifiedAt
        self.timeZoneIdentifier = timeZoneIdentifier
        self.dailyUsage = dailyUsage
        self.dailyActivityTimestamps = dailyActivityTimestamps
        self.dailyTokenUsageEvents = dailyTokenUsageEvents
    }

    enum CodingKeys: String, CodingKey {
        case fileSize
        case modifiedAt
        case timeZoneIdentifier
        case dailyUsage
        case dailyActivityTimestamps
        case dailyTokenUsageEvents
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        fileSize = try container.decode(Int.self, forKey: .fileSize)
        modifiedAt = try container.decode(TimeInterval.self, forKey: .modifiedAt)
        timeZoneIdentifier = try container.decode(String.self, forKey: .timeZoneIdentifier)
        dailyUsage = try container.decode([String: CodexCachedDailyUsage].self, forKey: .dailyUsage)
        dailyActivityTimestamps = try container.decodeIfPresent(
            [String: [TimeInterval]].self,
            forKey: .dailyActivityTimestamps) ?? [:]
        dailyTokenUsageEvents = try container.decodeIfPresent(
            [String: [CodexCachedTokenUsageEvent]].self,
            forKey: .dailyTokenUsageEvents) ?? [:]
    }
}

struct CodexRolloutDailySummary {
    var dailyUsage: [String: CodexCachedDailyUsage] = [:]
    var dailyActivityTimestamps: [String: [TimeInterval]] = [:]
    var dailyTokenUsageEvents: [String: [CodexCachedTokenUsageEvent]] = [:]

    var isEmpty: Bool {
        dailyUsage.isEmpty
            && dailyActivityTimestamps.isEmpty
            && dailyTokenUsageEvents.isEmpty
    }
}

struct CodexCachedDailyUsage: Codable {
    var inputTokens = 0
    var outputTokens = 0
    var cacheReadTokens = 0
    var reasoningTokens = 0
    var activeSeconds: TimeInterval = 0

    static let zero = CodexCachedDailyUsage()

    var totalTokens: Int {
        inputTokens + outputTokens + cacheReadTokens + reasoningTokens
    }

    mutating func accumulate(_ usage: RawTokenUsage) {
        inputTokens += usage.inputTokens
        outputTokens += usage.outputTokens
        cacheReadTokens += usage.cacheReadTokens
        reasoningTokens += usage.reasoningTokens
    }
}

struct CodexCachedTokenUsageEvent: Codable {
    let timestamp: TimeInterval
    let inputTokens: Int
    let outputTokens: Int
    let cacheReadTokens: Int
    let reasoningTokens: Int

    var totalTokens: Int {
        inputTokens + outputTokens + cacheReadTokens + reasoningTokens
    }

    init(timestamp: Date, usage: RawTokenUsage) {
        self.timestamp = timestamp.timeIntervalSince1970
        inputTokens = usage.inputTokens
        outputTokens = usage.outputTokens
        cacheReadTokens = usage.cacheReadTokens
        reasoningTokens = usage.reasoningTokens
    }
}

struct CodexFileSignature {
    let fileSize: Int
    let modifiedAt: TimeInterval
}

func codexFileSignature(for url: URL) -> CodexFileSignature? {
    guard let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey]),
          let modifiedAt = values.contentModificationDate,
          let fileSize = values.fileSize else {
        return nil
    }

    return CodexFileSignature(
        fileSize: fileSize,
        modifiedAt: modifiedAt.timeIntervalSince1970)
}

func codexRolloutUsageCacheURL() -> URL {
    homeDir()
        .appendingPathComponent("Library")
        .appendingPathComponent("Application Support")
        .appendingPathComponent("Toki")
        .appendingPathComponent("codex-rollout-cache.json")
}

func codexDayKey(for date: Date, timeZone: TimeZone) -> String {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = timeZone
    let components = calendar.dateComponents([.year, .month, .day], from: date)
    return String(
        format: "%04d-%02d-%02d",
        components.year ?? 0,
        components.month ?? 0,
        components.day ?? 0)
}

func codexDayKey(for date: Date) -> String {
    codexDayKey(for: date, timeZone: TimeZone.autoupdatingCurrent)
}

func codexCacheTimeZoneIdentifier() -> String {
    TimeZone.autoupdatingCurrent.identifier
}

func dailyActiveSeconds(from timestamps: [Date]) -> [String: TimeInterval] {
    let groupedEvents = timestamps.reduce(into: [String: [ActivityTimeEvent<String>]]()) { result, timestamp in
        let dayKey = codexDayKey(for: timestamp)
        result[dayKey, default: []].append(
            ActivityTimeEvent(streamID: dayKey, timestamp: timestamp, key: nil))
    }

    return groupedEvents.reduce(into: [String: TimeInterval]()) { result, item in
        let (dayKey, events) = item
        let dayEnd = events
            .first
            .map { Calendar.current.startOfDay(for: $0.timestamp).addingTimeInterval(86400) }
        result[dayKey] = ActivityTimeEstimator.estimate(
            events: events,
            clippingEndDate: dayEnd).totalSeconds
    }
}

func dailyActivityTimestampValues(from timestamps: [Date]) -> [String: [TimeInterval]] {
    timestamps.reduce(into: [String: [TimeInterval]]()) { result, timestamp in
        let dayKey = codexDayKey(for: timestamp)
        result[dayKey, default: []].append(timestamp.timeIntervalSince1970)
    }
}

func dailyTokenUsageEvents(fromRolloutLines lines: [String]) -> [String: [CodexCachedTokenUsageEvent]] {
    codexRolloutDailySummary(fromSnapshots: codexRolloutSnapshots(fromRolloutLines: lines)).dailyTokenUsageEvents
}

func codexRolloutDailySummary(fromRolloutAt url: URL) -> CodexRolloutDailySummary {
    codexRolloutDailySummary(fromSnapshots: codexRolloutSnapshots(fromRolloutAt: url))
}

func codexRolloutDailySummary(fromSnapshots snapshots: [CodexTimedSnapshot]) -> CodexRolloutDailySummary {
    var previousSnapshot: CodexUsageSnapshot?
    var summary = CodexRolloutDailySummary()
    var activityTimestamps: [Date] = []

    for entry in snapshots {
        guard !Task.isCancelled else { return CodexRolloutDailySummary() }

        let delta = entry.snapshot.delta(since: previousSnapshot)
        previousSnapshot = entry.snapshot

        let usage = delta.normalizedUsage
        guard usage.totalTokens > 0 else { continue }

        activityTimestamps.append(entry.date)
        let dayKey = codexDayKey(for: entry.date)
        summary.dailyUsage[dayKey, default: .zero].accumulate(usage)
        summary.dailyActivityTimestamps[dayKey, default: []].append(entry.date.timeIntervalSince1970)
        summary.dailyTokenUsageEvents[dayKey, default: []].append(
            CodexCachedTokenUsageEvent(timestamp: entry.date, usage: usage))
    }

    for (dayKey, seconds) in dailyActiveSeconds(from: activityTimestamps) {
        summary.dailyUsage[dayKey, default: .zero].activeSeconds += seconds
    }

    return summary
}

func codexRolloutSnapshots(fromRolloutLines lines: [String]) -> [CodexTimedSnapshot] {
    let decoder = JSONDecoder()

    return lines.enumerated().compactMap { index, line in
        guard let data = line.data(using: .utf8),
              let entry = try? decoder.decode(CodexRolloutEntry.self, from: data),
              let timestamp = entry.timestamp,
              let date = DateParser.parse(timestamp),
              let snapshot = entry.tokenSnapshot else {
            return nil
        }

        return CodexTimedSnapshot(
            date: date,
            snapshot: snapshot,
            fileOrder: index)
    }.sorted { lhs, rhs in
        if lhs.date == rhs.date {
            return lhs.fileOrder < rhs.fileOrder
        }
        return lhs.date < rhs.date
    }
}

func codexRolloutSnapshots(fromRolloutAt url: URL) -> [CodexTimedSnapshot] {
    let decoder = JSONDecoder()
    var snapshots: [CodexTimedSnapshot] = []

    forEachJSONLLine(at: url) { line, index in
        guard let data = line.data(using: .utf8),
              let entry = try? decoder.decode(CodexRolloutEntry.self, from: data),
              let timestamp = entry.timestamp,
              let date = DateParser.parse(timestamp),
              let snapshot = entry.tokenSnapshot else {
            return
        }

        snapshots.append(
            CodexTimedSnapshot(
                date: date,
                snapshot: snapshot,
                fileOrder: index))
    }

    return snapshots.sorted { lhs, rhs in
        if lhs.date == rhs.date {
            return lhs.fileOrder < rhs.fileOrder
        }
        return lhs.date < rhs.date
    }
}

func forEachJSONLLine(at url: URL, _ body: (String, Int) -> Void) {
    forEachJSONLLineUntil(at: url) { line, index in
        body(line, index)
        return true
    }
}

func forEachJSONLLineUntil(at url: URL, _ body: (String, Int) -> Bool) {
    guard let handle = try? FileHandle(forReadingFrom: url) else { return }
    defer { try? handle.close() }

    var lineIndex = 0
    var pending = Data()

    while true {
        guard !Task.isCancelled else { return }

        let chunk: Data
        do {
            guard let data = try handle.read(upToCount: 64 * 1024),
                  !data.isEmpty else {
                break
            }
            chunk = data
        } catch {
            break
        }

        pending.append(chunk)
        while let newlineIndex = pending.firstIndex(of: 0x0A) {
            guard !Task.isCancelled else { return }

            let lineData = pending.subdata(in: pending.startIndex..<newlineIndex)
            pending.removeSubrange(pending.startIndex...newlineIndex)
            if let line = jsonlLineString(from: lineData) {
                guard body(line, lineIndex) else { return }
                lineIndex += 1
            }
        }
    }

    if let line = jsonlLineString(from: pending) {
        _ = body(line, lineIndex)
    }
}

private func jsonlLineString(from data: Data) -> String? {
    let trimmedData = data.trimmingCarriageReturn()
    guard !trimmedData.isEmpty,
          let line = String(data: trimmedData, encoding: .utf8) else {
        return nil
    }

    let trimmedLine = line.trimmingCharacters(in: .whitespaces)
    return trimmedLine.isEmpty ? nil : trimmedLine
}

private extension Data {
    func trimmingCarriageReturn() -> Data {
        guard last == 0x0D else { return self }
        return Data(dropLast())
    }
}

func codexIsWholeDayAlignedRange(from startDate: Date, to endDate: Date) -> Bool {
    let calendar = Calendar.current
    return startDate == calendar.startOfDay(for: startDate)
        && endDate == calendar.startOfDay(for: endDate)
        && startDate < endDate
}
