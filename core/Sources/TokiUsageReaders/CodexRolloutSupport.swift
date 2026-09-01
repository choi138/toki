import Foundation
import TokiDurableStorage
import TokiUsageCore

public let maximumCodexRolloutUsageCacheBytes = 64 * 1024 * 1024

public actor CodexRolloutUsageCache {
    public static let shared = CodexRolloutUsageCache()

    let cacheURL: URL
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

    func beginBatch(retaining paths: [String]) -> UUID {
        loadIfNeeded()
        let token = UUID()
        activeBatches[token] = Set(paths)
        return token
    }

    func endBatch(_ token: UUID) {
        loadIfNeeded()
        guard activeBatches.removeValue(forKey: token) != nil else { return }
        persistIfNeeded(allowActiveBatches: true)
    }

    func dailyUsage(for url: URL) -> [String: CodexCachedDailyUsage]? {
        guard let cached = cachedEntry(for: url) else {
            return nil
        }

        return cached.dailyUsage
    }

    func dailyActivityTimestamps(for url: URL) -> [String: [TimeInterval]]? {
        guard let cached = cachedEntry(for: url) else {
            return nil
        }

        if cached.dailyActivityTimestamps.isEmpty,
           cached.dailyUsage.values.contains(where: { $0.totalTokens > 0 }) {
            return nil
        }

        return cached.dailyActivityTimestamps
    }

    func dailyTokenUsageEvents(for url: URL) -> [String: [CodexCachedTokenUsageEvent]]? {
        guard let cached = cachedEntry(for: url) else {
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
        processingState: CodexRolloutProcessingState? = nil,
        fileSignature: CodexFileSignature? = nil,
        for url: URL) {
        loadIfNeeded()

        guard let fileSignature = fileSignature ?? codexFileSignature(for: url) else { return }

        let entry = CodexRolloutUsageCacheEntry(
            fileSize: fileSignature.fileSize,
            modifiedAt: fileSignature.modifiedAt,
            timeZoneIdentifier: codexCacheTimeZoneIdentifier(),
            dailyUsage: dailyUsage,
            dailyActivityTimestamps: dailyActivityTimestamps,
            dailyTokenUsageEvents: dailyTokenUsageEvents,
            processingState: processingState)
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

    private func loadIfNeeded() {
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

    private func cachedEntry(for url: URL) -> CodexRolloutUsageCacheEntry? {
        loadIfNeeded()

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

    private func persistIfNeeded(allowActiveBatches: Bool = false) {
        guard hasPendingChanges, allowActiveBatches || activeBatches.isEmpty else { return }

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
        #if canImport(ObjectiveC)
            return autoreleasepool {
                try? JSONEncoder().encode(CodexRolloutUsageCacheFile(entries: [path: entry])).count
            }
        #else
            return try? JSONEncoder().encode(CodexRolloutUsageCacheFile(entries: [path: entry])).count
        #endif
    }

    private func encodedCacheFile() -> Data? {
        #if canImport(ObjectiveC)
            return autoreleasepool {
                try? JSONEncoder().encode(CodexRolloutUsageCacheFile(entries: entries))
            }
        #else
            return try? JSONEncoder().encode(CodexRolloutUsageCacheFile(entries: entries))
        #endif
    }
}

extension CodexRolloutUsageCache {
    func dailySummary(
        for url: URL,
        includingDerivedData: Bool = true) -> CodexRolloutDailySummary {
        loadIfNeeded()

        guard let signature = codexFileSignature(for: url) else {
            return CodexRolloutDailySummary()
        }

        if let cached = entries[url.path],
           cached.isCurrentSchema,
           !includingDerivedData || cached.hasCompleteDerivedData,
           cached.fileSize == signature.fileSize,
           cached.modifiedAt == signature.modifiedAt,
           cached.processingState?.processedByteCount == cached.fileSize,
           cached.processingState?.fileIdentifier == signature.fileIdentifier,
           cached.timeZoneIdentifier == codexCacheTimeZoneIdentifier() {
            touch(url.path)
            return cached.summary
        }

        if let cached = entries[url.path] {
            let preserveDerivedData = includingDerivedData || cached.hasCompleteDerivedData
            if let updated = codexRolloutDailySummaryByAppending(
                fromRolloutAt: url,
                signature: signature,
                cachedEntry: cached,
                includingDerivedData: preserveDerivedData) {
                guard !Task.isCancelled else { return cached.summary }
                store(
                    dailyUsage: updated.summary.dailyUsage,
                    dailyActivityTimestamps: updated.summary.dailyActivityTimestamps,
                    dailyTokenUsageEvents: updated.summary.dailyTokenUsageEvents,
                    processingState: updated.processingState,
                    fileSignature: signature,
                    for: url)
                return updated.summary
            }
        }

        let rebuilt = codexRolloutDailySummaryWithState(
            fromRolloutAt: url,
            signature: signature,
            includingDerivedData: true)
        guard !Task.isCancelled, rebuilt.didReadToEnd else {
            guard let cached = entries[url.path],
                  cached.isCurrentSchema,
                  cached.fileSize == signature.fileSize,
                  cached.modifiedAt == signature.modifiedAt,
                  cached.processingState?.processedByteCount == cached.fileSize,
                  cached.processingState?.fileIdentifier == signature.fileIdentifier,
                  cached.timeZoneIdentifier == codexCacheTimeZoneIdentifier() else {
                return CodexRolloutDailySummary()
            }
            return cached.summary
        }

        store(
            dailyUsage: rebuilt.summary.dailyUsage,
            dailyActivityTimestamps: rebuilt.summary.dailyActivityTimestamps,
            dailyTokenUsageEvents: rebuilt.summary.dailyTokenUsageEvents,
            processingState: rebuilt.processingState,
            fileSignature: signature,
            for: url)
        return rebuilt.summary
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
    static let currentSchemaVersion = 3

    let schemaVersion: Int
    let fileSize: Int
    let modifiedAt: TimeInterval
    let timeZoneIdentifier: String
    let dailyUsage: [String: CodexCachedDailyUsage]
    let dailyActivityTimestamps: [String: [TimeInterval]]
    let dailyTokenUsageEvents: [String: [CodexCachedTokenUsageEvent]]
    let processingState: CodexRolloutProcessingState?

    var isCurrentSchema: Bool {
        schemaVersion == Self.currentSchemaVersion
    }

    init(
        fileSize: Int,
        modifiedAt: TimeInterval,
        timeZoneIdentifier: String,
        dailyUsage: [String: CodexCachedDailyUsage],
        dailyActivityTimestamps: [String: [TimeInterval]] = [:],
        dailyTokenUsageEvents: [String: [CodexCachedTokenUsageEvent]] = [:],
        processingState: CodexRolloutProcessingState? = nil) {
        schemaVersion = Self.currentSchemaVersion
        self.fileSize = fileSize
        self.modifiedAt = modifiedAt
        self.timeZoneIdentifier = timeZoneIdentifier
        self.dailyUsage = dailyUsage
        self.dailyActivityTimestamps = dailyActivityTimestamps
        self.dailyTokenUsageEvents = dailyTokenUsageEvents
        self.processingState = processingState
    }

    enum CodingKeys: String, CodingKey {
        case schemaVersion
        case fileSize
        case modifiedAt
        case timeZoneIdentifier
        case dailyUsage
        case dailyActivityTimestamps
        case dailyTokenUsageEvents
        case processingState
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
        processingState = try container.decodeIfPresent(
            CodexRolloutProcessingState.self,
            forKey: .processingState)
    }

    var summary: CodexRolloutDailySummary {
        CodexRolloutDailySummary(
            dailyUsage: dailyUsage,
            dailyActivityTimestamps: dailyActivityTimestamps,
            dailyTokenUsageEvents: dailyTokenUsageEvents)
    }

    var hasCompleteDerivedData: Bool {
        let hasUsage = dailyUsage.values.contains { $0.totalTokens > 0 }
        return !hasUsage || (!dailyActivityTimestamps.isEmpty && !dailyTokenUsageEvents.isEmpty)
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
    let fileIdentifier: UInt64?
}

func codexFileSignature(for url: URL) -> CodexFileSignature? {
    guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
          let modifiedAt = attributes[.modificationDate] as? Date,
          let fileSize = (attributes[.size] as? NSNumber)?.intValue else {
        return nil
    }

    return CodexFileSignature(
        fileSize: fileSize,
        modifiedAt: modifiedAt.timeIntervalSince1970,
        fileIdentifier: (attributes[.systemFileNumber] as? NSNumber)?.uint64Value)
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
    guard let signature = codexFileSignature(for: url) else {
        return CodexRolloutDailySummary()
    }
    return codexRolloutDailySummaryWithState(fromRolloutAt: url, signature: signature).summary
}

func codexRolloutDailySummary(fromSnapshots snapshots: [CodexTimedSnapshot]) -> CodexRolloutDailySummary {
    var summary = CodexRolloutDailySummary()
    _ = accumulateCodexSnapshots(snapshots, into: &summary, previousSnapshot: nil)
    recomputeCodexActiveSeconds(in: &summary)
    return summary
}
