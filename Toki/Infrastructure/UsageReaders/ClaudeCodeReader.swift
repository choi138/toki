import Foundation

/// Reads ~/.claude/projects/**/*.jsonl
/// Deduplicates by requestId, keeps max token counts per message
struct ClaudeCodeReader: TokenReader {
    let name = "Claude Code"

    func readUsage(from startDate: Date, to endDate: Date) async throws -> RawTokenUsage {
        let projectsURL = homeDir().appendingPathComponent(".claude/projects")
        guard FileManager.default.fileExists(atPath: projectsURL.path) else {
            return RawTokenUsage()
        }

        let files = findFiles(in: projectsURL, withExtension: "jsonl", modifiedAfter: startDate)
        await ClaudeUsageCache.shared.beginBatch()
        var sessions: [(streamID: String, records: [ClaudeCachedUsageRecord])] = []

        for file in files {
            await sessions.append(
                (streamID: file.path, records: Self.cachedUsageRecords(at: file)))
        }

        await ClaudeUsageCache.shared.endBatch()
        return Self.usage(
            fromSessions: sessions,
            from: startDate,
            to: endDate,
            source: name)
    }

    static func usage(
        fromJSONLLines lines: [String],
        streamID: String,
        from startDate: Date,
        to endDate: Date) -> RawTokenUsage {
        usage(
            fromJSONLSessions: [(streamID: streamID, lines: lines)],
            from: startDate,
            to: endDate)
    }

    static func usage(
        fromJSONLSessions sessions: [(streamID: String, lines: [String])],
        from startDate: Date,
        to endDate: Date) -> RawTokenUsage {
        usage(
            fromSessions: sessions.map { session in
                (streamID: session.streamID, records: parseUsageRecords(from: session.lines))
            },
            from: startDate,
            to: endDate,
            source: "Claude Code")
    }

    private static func cachedUsageRecords(at url: URL) async -> [ClaudeCachedUsageRecord] {
        if let cached = await ClaudeUsageCache.shared.records(for: url) {
            return cached
        }

        let parsed = parseUsageRecords(at: url)
        await ClaudeUsageCache.shared.store(records: parsed, for: url)
        return parsed
    }

    private static func accumulate(
        records: [ClaudeCachedUsageRecord],
        streamID: String,
        from startDate: Date,
        to endDate: Date,
        dedup: inout [String: Entry],
        activityByKey: inout [String: ActivitySeries]) {
        for record in records {
            let date = Date(timeIntervalSince1970: record.timestamp)
            guard date >= startDate, date < endDate else { continue }

            let key = record.requestId
                ?? record.messageID
                ?? "\(streamID)#\(record.lineIndex)"

            let entry = Entry(
                model: record.model,
                input: record.input,
                output: record.output,
                cacheRead: record.cacheRead,
                cacheWrite: record.cacheWrite)

            if let existing = dedup[key] {
                dedup[key] = existing.mergedMax(with: entry)
            } else {
                dedup[key] = entry
            }

            let activityStreamID = record.requestId ?? record.messageID ?? streamID
            let modelKey = normalizedModelID(record.model)
            if var existing = activityByKey[key] {
                existing.record(timestamp: date, sourceStreamID: streamID, modelKey: modelKey)
                activityByKey[key] = existing
            } else {
                activityByKey[key] = ActivitySeries(
                    activityStreamID: activityStreamID,
                    modelKey: modelKey,
                    timestampsBySource: [streamID: [date]])
            }
        }
    }

    private static func usage(
        fromSessions sessions: [(streamID: String, records: [ClaudeCachedUsageRecord])],
        from startDate: Date,
        to endDate: Date,
        source: String) -> RawTokenUsage {
        var dedup: [String: Entry] = [:]
        var activityByKey: [String: ActivitySeries] = [:]

        for session in sessions {
            accumulate(
                records: session.records,
                streamID: session.streamID,
                from: startDate,
                to: endDate,
                dedup: &dedup,
                activityByKey: &activityByKey)
        }

        return usage(
            fromDedupedEntries: dedup,
            activityEvents: activityByKey.values.flatMap(\.events),
            source: source)
    }

    private static func usage(
        fromDedupedEntries dedup: [String: Entry],
        activityEvents: [ActivityTimeEvent<String>],
        source: String) -> RawTokenUsage {
        var result = RawTokenUsage()

        for entry in dedup.values {
            result.inputTokens += entry.input
            result.outputTokens += entry.output
            result.cacheReadTokens += entry.cacheRead
            result.cacheWriteTokens += entry.cacheWrite

            let entryCost: Double
            if let price = modelPrice(for: entry.model ?? "") {
                entryCost = price.cost(
                    input: entry.input,
                    output: entry.output,
                    cacheRead: entry.cacheRead,
                    cacheWrite: entry.cacheWrite)
                result.cost += entryCost
            } else {
                entryCost = 0
            }

            if let modelKey = normalizedModelID(entry.model) {
                let entryTokens = entry.input + entry.output + entry.cacheRead + entry.cacheWrite
                result.perModel[modelKey, default: PerModelUsage()].totalTokens += entryTokens
                result.perModel[modelKey, default: PerModelUsage()].cost += entryCost
                result.perModel[modelKey, default: PerModelUsage()].sources.insert(source)
            }
        }

        result.mergeActivityEvents(activityEvents, source: source)

        return result
    }

    private static func parseUsageRecords(at url: URL) -> [ClaudeCachedUsageRecord] {
        parseUsageRecords(from: readJSONLLines(at: url))
    }

    private static func parseUsageRecords(from lines: [String]) -> [ClaudeCachedUsageRecord] {
        let decoder = JSONDecoder()
        return lines.enumerated().compactMap { item -> ClaudeCachedUsageRecord? in
            let (index, line) = item
            guard let data = line.data(using: .utf8),
                  let msg = try? decoder.decode(RawMessage.self, from: data),
                  msg.type == "assistant",
                  let tsStr = msg.timestamp,
                  let date = DateParser.parse(tsStr),
                  let usage = msg.message?.usage else { return nil }

            return ClaudeCachedUsageRecord(
                lineIndex: index,
                timestamp: date.timeIntervalSince1970,
                requestId: msg.requestId,
                messageID: msg.message?.id,
                model: msg.message?.model,
                input: usage.inputTokens ?? 0,
                output: usage.outputTokens ?? 0,
                cacheRead: usage.cacheReadInputTokens ?? 0,
                cacheWrite: usage.cacheCreationInputTokens ?? 0)
        }
    }
}

// MARK: - Private Types

private struct Entry {
    let model: String?
    let input, output, cacheRead, cacheWrite: Int

    func mergedMax(with other: Entry) -> Entry {
        Entry(
            model: model ?? other.model,
            input: max(input, other.input),
            output: max(output, other.output),
            cacheRead: max(cacheRead, other.cacheRead),
            cacheWrite: max(cacheWrite, other.cacheWrite))
    }
}

private struct ActivitySeries {
    let activityStreamID: String
    var modelKey: String?
    var timestampsBySource: [String: [Date]]

    mutating func record(timestamp: Date, sourceStreamID: String, modelKey: String?) {
        timestampsBySource[sourceStreamID, default: []].append(timestamp)
        self.modelKey = self.modelKey ?? modelKey
    }

    var events: [ActivityTimeEvent<String>] {
        bestTimestamps.map { timestamp in
            ActivityTimeEvent(
                streamID: activityStreamID,
                timestamp: timestamp,
                key: modelKey)
        }
    }

    private var bestTimestamps: [Date] {
        timestampsBySource.values
            .map { timestamps in
                Array(Set(timestamps)).sorted()
            }
            .max { lhs, rhs in
                if lhs.count != rhs.count {
                    return lhs.count < rhs.count
                }

                let lhsDuration = duration(of: lhs)
                let rhsDuration = duration(of: rhs)
                if lhsDuration != rhsDuration {
                    return lhsDuration < rhsDuration
                }

                return (lhs.first ?? .distantFuture) > (rhs.first ?? .distantFuture)
            } ?? []
    }

    private func duration(of timestamps: [Date]) -> TimeInterval {
        guard let first = timestamps.first, let last = timestamps.last else { return 0 }
        return last.timeIntervalSince(first)
    }
}

private struct RawMessage: Decodable {
    let type: String?
    let timestamp: String?
    let requestId: String?
    let message: Message?

    struct Message: Decodable {
        let id: String?
        let model: String?
        let usage: Usage?

        struct Usage: Decodable {
            let inputTokens: Int?
            let outputTokens: Int?
            let cacheReadInputTokens: Int?
            let cacheCreationInputTokens: Int?

            enum CodingKeys: String, CodingKey {
                case inputTokens = "input_tokens"
                case outputTokens = "output_tokens"
                case cacheReadInputTokens = "cache_read_input_tokens"
                case cacheCreationInputTokens = "cache_creation_input_tokens"
            }
        }
    }
}

private actor ClaudeUsageCache {
    static let shared = ClaudeUsageCache()

    private var isLoaded = false
    private var entries: [String: ClaudeUsageCacheEntry] = [:]
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

    func records(for url: URL) async -> [ClaudeCachedUsageRecord]? {
        await loadIfNeeded()

        guard let fileSignature = claudeFileSignature(for: url),
              let cached = entries[url.path],
              cached.fileSize == fileSignature.fileSize,
              cached.modifiedAt == fileSignature.modifiedAt else {
            return nil
        }

        return cached.records
    }

    func store(records: [ClaudeCachedUsageRecord], for url: URL) async {
        await loadIfNeeded()

        guard let fileSignature = claudeFileSignature(for: url) else { return }

        entries[url.path] = ClaudeUsageCacheEntry(
            fileSize: fileSignature.fileSize,
            modifiedAt: fileSignature.modifiedAt,
            records: records)

        hasPendingChanges = true
        persistIfNeeded()
    }

    private func loadIfNeeded() async {
        guard !isLoaded else { return }
        isLoaded = true

        guard let data = try? Data(contentsOf: claudeUsageCacheURL()),
              let decoded = try? JSONDecoder().decode(ClaudeUsageCacheFile.self, from: data) else {
            entries = [:]
            return
        }

        entries = decoded.entries
    }

    private func persistIfNeeded() {
        guard hasPendingChanges, batchDepth == 0 else { return }

        let cacheURL = claudeUsageCacheURL()
        let directory = cacheURL.deletingLastPathComponent()
        try? FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: nil)

        let payload = ClaudeUsageCacheFile(entries: entries)
        guard let data = try? JSONEncoder().encode(payload) else { return }
        try? data.write(to: cacheURL, options: [.atomic])
        hasPendingChanges = false
    }
}

private struct ClaudeUsageCacheFile: Codable {
    let entries: [String: ClaudeUsageCacheEntry]
}

private struct ClaudeUsageCacheEntry: Codable {
    let fileSize: Int
    let modifiedAt: TimeInterval
    let records: [ClaudeCachedUsageRecord]
}

private struct ClaudeCachedUsageRecord: Codable {
    let lineIndex: Int
    let timestamp: TimeInterval
    let requestId: String?
    let messageID: String?
    let model: String?
    let input: Int
    let output: Int
    let cacheRead: Int
    let cacheWrite: Int
}

private struct ClaudeFileSignature {
    let fileSize: Int
    let modifiedAt: TimeInterval
}

private func claudeFileSignature(for url: URL) -> ClaudeFileSignature? {
    guard let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey]),
          let modifiedAt = values.contentModificationDate,
          let fileSize = values.fileSize else {
        return nil
    }

    return ClaudeFileSignature(
        fileSize: fileSize,
        modifiedAt: modifiedAt.timeIntervalSince1970)
}

private func claudeUsageCacheURL() -> URL {
    homeDir()
        .appendingPathComponent("Library")
        .appendingPathComponent("Application Support")
        .appendingPathComponent("Toki")
        .appendingPathComponent("claude-usage-cache.json")
}
