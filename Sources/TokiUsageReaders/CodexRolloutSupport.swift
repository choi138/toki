import Foundation
import TokiDurableStorage
import TokiUsageCore

public let maximumCodexRolloutUsageCacheBytes = 64 * 1024 * 1024

public actor CodexRolloutUsageCache {
    public static let shared = CodexRolloutUsageCache()

    private let cacheURL: URL
    private let maximumBytes: Int
    private let maximumEntryBytes: Int
    private var isLoaded = false
    private var entries: [String: CodexRolloutUsageCacheEntry] = [:]
    private var entryByteCounts: [String: Int] = [:]
    private var totalEntryBytes = 0
    private var accessOrder: [String: UInt64] = [:]
    private var accessCounter: UInt64 = 0
    private var activeBatches: [UUID: Set<String>] = [:]
    private var hasPendingChanges = false

    public init(
        cacheURL: URL = codexRolloutUsageCacheURL(),
        maximumBytes: Int = maximumCodexRolloutUsageCacheBytes) {
        precondition(maximumBytes >= 0)
        self.cacheURL = cacheURL
        self.maximumBytes = maximumBytes
        maximumEntryBytes = max(0, maximumBytes - min(1024, maximumBytes))
    }

    func beginBatch(retaining paths: [String]) async -> UUID {
        await loadIfNeeded()
        let token = UUID()
        activeBatches[token] = Set(paths)
        prune(retaining: activeBatches.values.reduce(into: Set<String>()) { $0.formUnion($1) })
        return token
    }

    func endBatch(_ token: UUID) async {
        await loadIfNeeded()
        guard let completedPaths = activeBatches.removeValue(forKey: token) else { return }
        let retainedPaths = activeBatches.values.reduce(into: completedPaths) { $0.formUnion($1) }
        prune(retaining: retainedPaths)
        persistIfNeeded()
    }

    func dailyUsage(for url: URL) async -> [String: CodexCachedDailyUsage]? {
        guard let cached = await cachedEntry(for: url) else {
            return nil
        }

        return cached.dailyUsage
    }

    func dailyActivityTimestamps(for url: URL) async -> [String: [TimeInterval]]? {
        guard let cached = await cachedEntry(for: url) else {
            return nil
        }

        if cached.dailyActivityTimestamps.isEmpty,
           cached.dailyUsage.values.contains(where: { $0.totalTokens > 0 }) {
            return nil
        }

        return cached.dailyActivityTimestamps
    }

    func dailyTokenUsageEvents(for url: URL) async -> [String: [CodexCachedTokenUsageEvent]]? {
        guard let cached = await cachedEntry(for: url) else {
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

        let entry = CodexRolloutUsageCacheEntry(
            fileSize: fileSignature.fileSize,
            modifiedAt: fileSignature.modifiedAt,
            timeZoneIdentifier: codexCacheTimeZoneIdentifier(),
            dailyUsage: dailyUsage,
            dailyActivityTimestamps: dailyActivityTimestamps,
            dailyTokenUsageEvents: dailyTokenUsageEvents)
        guard let entryByteCount = encodedByteCount(path: url.path, entry: entry),
              entryByteCount <= maximumEntryBytes else {
            removeEntry(path: url.path)
            persistIfNeeded()
            return
        }

        totalEntryBytes -= entryByteCounts[url.path] ?? 0
        entries[url.path] = entry
        entryByteCounts[url.path] = entryByteCount
        totalEntryBytes += entryByteCount
        touch(url.path)
        enforceMemoryLimit()
        hasPendingChanges = true
        persistIfNeeded()
    }

    private func loadIfNeeded() async {
        guard !isLoaded else { return }
        isLoaded = true

        guard FileManager.default.fileExists(atPath: cacheURL.path)
            || (try? FileManager.default.destinationOfSymbolicLink(atPath: cacheURL.path)) != nil else { return }
        guard let values = try? cacheURL.resourceValues(
            forKeys: [.fileSizeKey, .isRegularFileKey, .isSymbolicLinkKey]),
            values.isRegularFile == true,
            values.isSymbolicLink != true,
            let fileSize = values.fileSize,
            fileSize <= maximumBytes,
            let data = try? Data(contentsOf: cacheURL),
            data.count <= maximumBytes,
            let decoded = try? JSONDecoder().decode(CodexRolloutUsageCacheFile.self, from: data) else {
            entries = [:]
            hasPendingChanges = true
            persistIfNeeded()
            return
        }

        for path in decoded.entries.keys.sorted() {
            guard let entry = decoded.entries[path],
                  let byteCount = encodedByteCount(path: path, entry: entry),
                  byteCount <= maximumEntryBytes else {
                hasPendingChanges = true
                continue
            }
            entries[path] = entry
            entryByteCounts[path] = byteCount
            totalEntryBytes += byteCount
            touch(path)
            enforceMemoryLimit()
        }
    }

    private func cachedEntry(for url: URL) async -> CodexRolloutUsageCacheEntry? {
        await loadIfNeeded()

        guard let fileSignature = codexFileSignature(for: url),
              let cached = entries[url.path] else {
            return nil
        }
        guard cached.isCurrentSchema,
              cached.fileSize == fileSignature.fileSize,
              cached.modifiedAt == fileSignature.modifiedAt,
              cached.timeZoneIdentifier == codexCacheTimeZoneIdentifier() else {
            removeEntry(path: url.path)
            persistIfNeeded()
            return nil
        }

        touch(url.path)
        return cached
    }

    private func persistIfNeeded() {
        guard hasPendingChanges, activeBatches.isEmpty else { return }

        guard !entries.isEmpty else {
            do {
                try DurableFileIO.removeIfPresent(cacheURL)
                hasPendingChanges = false
            } catch {}
            return
        }
        guard let data = encodedCacheFile(), data.count <= maximumBytes else { return }
        do {
            try writeCodexRolloutUsageCache(data, to: cacheURL)
            hasPendingChanges = false
        } catch {}
    }

    private func prune(retaining paths: Set<String>) {
        let removedPaths = Set(entries.keys).subtracting(paths)
        guard !removedPaths.isEmpty else { return }
        for path in removedPaths {
            removeEntry(path: path)
        }
    }

    private func enforceMemoryLimit() {
        while totalEntryBytes > maximumEntryBytes,
              let path = accessOrder.min(by: { $0.value < $1.value })?.key {
            removeEntry(path: path)
        }
    }

    private func removeEntry(path: String) {
        guard entries.removeValue(forKey: path) != nil else { return }
        totalEntryBytes -= entryByteCounts.removeValue(forKey: path) ?? 0
        accessOrder.removeValue(forKey: path)
        hasPendingChanges = true
    }

    private func touch(_ path: String) {
        accessCounter &+= 1
        accessOrder[path] = accessCounter
    }

    private func encodedByteCount(path: String, entry: CodexRolloutUsageCacheEntry) -> Int? {
        try? JSONEncoder().encode(CodexRolloutUsageCacheFile(entries: [path: entry])).count
    }

    private func encodedCacheFile() -> Data? {
        try? JSONEncoder().encode(CodexRolloutUsageCacheFile(entries: entries))
    }
}

public extension CodexRolloutUsageCache {
    func reset() throws {
        isLoaded = true
        entries = [:]
        entryByteCounts = [:]
        totalEntryBytes = 0
        accessOrder = [:]
        accessCounter = 0
        activeBatches = [:]
        hasPendingChanges = false

        try DurableFileIO.removeIfPresent(cacheURL)
    }
}

struct CodexRolloutUsageCacheFile: Codable {
    let entries: [String: CodexRolloutUsageCacheEntry]
}

struct CodexRolloutUsageCacheEntry: Codable {
    static let currentSchemaVersion = 2

    let schemaVersion: Int
    let fileSize: Int
    let modifiedAt: TimeInterval
    let timeZoneIdentifier: String
    let dailyUsage: [String: CodexCachedDailyUsage]
    let dailyActivityTimestamps: [String: [TimeInterval]]
    let dailyTokenUsageEvents: [String: [CodexCachedTokenUsageEvent]]

    var isCurrentSchema: Bool {
        schemaVersion == Self.currentSchemaVersion
    }

    init(
        fileSize: Int,
        modifiedAt: TimeInterval,
        timeZoneIdentifier: String,
        dailyUsage: [String: CodexCachedDailyUsage],
        dailyActivityTimestamps: [String: [TimeInterval]] = [:],
        dailyTokenUsageEvents: [String: [CodexCachedTokenUsageEvent]] = [:]) {
        schemaVersion = Self.currentSchemaVersion
        self.fileSize = fileSize
        self.modifiedAt = modifiedAt
        self.timeZoneIdentifier = timeZoneIdentifier
        self.dailyUsage = dailyUsage
        self.dailyActivityTimestamps = dailyActivityTimestamps
        self.dailyTokenUsageEvents = dailyTokenUsageEvents
    }

    enum CodingKeys: String, CodingKey {
        case schemaVersion
        case fileSize
        case modifiedAt
        case timeZoneIdentifier
        case dailyUsage
        case dailyActivityTimestamps
        case dailyTokenUsageEvents
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try container.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 0
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

public func codexRolloutUsageCacheURL(
    paths: LocalUsageReaderPaths = LocalUsageReaderPaths(),
    scope: LocalUsageCacheScope = .application) -> URL {
    paths.cacheDirectory(for: scope).appendingPathComponent("codex-rollout-cache.json")
}

func writeCodexRolloutUsageCache(_ data: Data, to url: URL) throws {
    guard data.count <= maximumCodexRolloutUsageCacheBytes else {
        throw CodexRolloutUsageCacheError.tooLarge
    }
    let directory = url.deletingLastPathComponent()
    try DurableFileIO.preparePrivateDirectory(directory)
    try DurableFileIO.writePrivate(data, to: url)
}

enum CodexRolloutUsageCacheError: Error {
    case tooLarge
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

        let usage = entry.usage(since: previousSnapshot)
        previousSnapshot = entry.tokenCount.nextBaseline(after: previousSnapshot)

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
