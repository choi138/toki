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
    var previousSnapshot: CodexUsageSnapshot?
    var result: [String: [CodexCachedTokenUsageEvent]] = [:]

    for entry in codexRolloutSnapshots(fromRolloutLines: lines) {
        guard !Task.isCancelled else { return [:] }

        let delta = entry.snapshot.delta(since: previousSnapshot)
        previousSnapshot = entry.snapshot

        let usage = delta.normalizedUsage
        guard usage.totalTokens > 0 else { continue }

        let dayKey = codexDayKey(for: entry.date)
        result[dayKey, default: []].append(
            CodexCachedTokenUsageEvent(timestamp: entry.date, usage: usage))
    }

    return result
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

func codexIsWholeDayAlignedRange(from startDate: Date, to endDate: Date) -> Bool {
    let calendar = Calendar.current
    return startDate == calendar.startOfDay(for: startDate)
        && endDate == calendar.startOfDay(for: endDate)
        && startDate < endDate
}

struct CodexModelEntry: Decodable {
    let type: String?
    let payload: Payload?

    struct Payload: Decodable {
        let model: String?
    }
}

struct CodexSession {
    let rolloutPath: String
    let model: String?
    let agentKind: WorkTimeAgentKind

    init(
        rolloutPath: String,
        model: String?,
        agentKind: WorkTimeAgentKind = .main) {
        self.rolloutPath = rolloutPath
        self.model = model
        self.agentKind = agentKind
    }
}

func codexAgentKind(fromSource source: String?) -> WorkTimeAgentKind {
    guard let source = source?.trimmingCharacters(in: .whitespacesAndNewlines),
          !source.isEmpty else {
        return .main
    }

    if source == "subagent" {
        return .subagent
    }

    guard let data = source.data(using: .utf8),
          let marker = try? JSONDecoder().decode(CodexSourceMarker.self, from: data) else {
        return .main
    }
    return marker.isSubagent ? .subagent : .main
}

struct CodexSessionMetaEntry: Decodable {
    let type: String?
    let payload: Payload?

    struct Payload: Decodable {
        let source: CodexSourceMarker?
    }
}

struct CodexSourceMarker: Decodable {
    let isSubagent: Bool

    init(from decoder: Decoder) throws {
        if let container = try? decoder.singleValueContainer(),
           let value = try? container.decode(String.self) {
            isSubagent = value == "subagent"
            return
        }

        guard let container = try? decoder.container(keyedBy: DynamicCodingKey.self),
              let subagentKey = DynamicCodingKey(stringValue: "subagent") else {
            isSubagent = false
            return
        }

        isSubagent = container.contains(subagentKey)
    }
}

struct DynamicCodingKey: CodingKey {
    let stringValue: String
    let intValue: Int?

    init?(stringValue: String) {
        self.stringValue = stringValue
        intValue = nil
    }

    init?(intValue: Int) {
        nil
    }
}

struct CodexRolloutEntry: Decodable {
    let timestamp: String?
    let type: String?
    let payload: Payload?

    var tokenSnapshot: CodexUsageSnapshot? {
        guard type == "event_msg",
              payload?.type == "token_count",
              let totalUsage = payload?.info?.totalTokenUsage else {
            return nil
        }

        return CodexUsageSnapshot(
            inputTokens: totalUsage.inputTokens ?? 0,
            cachedInputTokens: totalUsage.cachedInputTokens ?? 0,
            outputTokens: totalUsage.outputTokens ?? 0,
            reasoningOutputTokens: totalUsage.reasoningOutputTokens ?? 0)
    }

    struct Payload: Decodable {
        let type: String?
        let info: Info?

        struct Info: Decodable {
            let totalTokenUsage: TotalTokenUsage?

            enum CodingKeys: String, CodingKey {
                case totalTokenUsage = "total_token_usage"
            }
        }
    }
}

struct TotalTokenUsage: Decodable {
    let inputTokens: Int?
    let cachedInputTokens: Int?
    let outputTokens: Int?
    let reasoningOutputTokens: Int?

    enum CodingKeys: String, CodingKey {
        case inputTokens = "input_tokens"
        case cachedInputTokens = "cached_input_tokens"
        case outputTokens = "output_tokens"
        case reasoningOutputTokens = "reasoning_output_tokens"
    }
}

struct CodexUsageSnapshot {
    let inputTokens: Int
    let cachedInputTokens: Int
    let outputTokens: Int
    let reasoningOutputTokens: Int

    func delta(since previous: CodexUsageSnapshot?) -> CodexUsageSnapshot {
        guard let previous else { return self }

        return CodexUsageSnapshot(
            inputTokens: max(0, inputTokens - previous.inputTokens),
            cachedInputTokens: max(0, cachedInputTokens - previous.cachedInputTokens),
            outputTokens: max(0, outputTokens - previous.outputTokens),
            reasoningOutputTokens: max(0, reasoningOutputTokens - previous.reasoningOutputTokens))
    }

    var normalizedUsage: RawTokenUsage {
        let uncachedInput = max(0, inputTokens - cachedInputTokens)
        let nonReasoningOutput = max(0, outputTokens - reasoningOutputTokens)

        return RawTokenUsage(
            inputTokens: uncachedInput,
            outputTokens: nonReasoningOutput,
            cacheReadTokens: cachedInputTokens,
            reasoningTokens: reasoningOutputTokens)
    }
}

struct CodexTimedSnapshot {
    let date: Date
    let snapshot: CodexUsageSnapshot
    let fileOrder: Int
}
