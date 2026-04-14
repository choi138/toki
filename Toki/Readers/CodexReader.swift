import Foundation
import SQLite3

// Reads ~/.codex/state_5.sqlite to discover active rollouts,
// then reconstructs per-range usage from rollout JSONL token_count snapshots.
struct CodexReader: TokenReader {
    let name = "Codex"

    private var dbPath: String {
        homeDir().appendingPathComponent(".codex/state_5.sqlite").path
    }

    func readUsage(from startDate: Date, to endDate: Date) async throws -> RawTokenUsage {
        guard FileManager.default.fileExists(atPath: dbPath) else {
            return RawTokenUsage()
        }

        let sessions = overlappingSessions(from: startDate, to: endDate)
        guard !sessions.isEmpty else { return RawTokenUsage() }

        var result = RawTokenUsage()
        await CodexRolloutUsageCache.shared.beginBatch()
        for session in sessions {
            let url = URL(fileURLWithPath: session.rolloutPath)
            guard FileManager.default.fileExists(atPath: url.path) else { continue }
            result += await Self.cachedUsage(
                fromRolloutAt: url,
                model: session.model,
                from: startDate,
                to: endDate
            )
        }
        await CodexRolloutUsageCache.shared.endBatch()

        return result
    }

    static func usage(
        fromRolloutLines lines: [String],
        model: String?,
        from startDate: Date,
        to endDate: Date
    ) -> RawTokenUsage {
        usage(
            fromDailyUsage: dailyUsage(fromRolloutLines: lines),
            model: model,
            from: startDate,
            to: endDate
        )
    }

    private static func usage(
        fromDailyUsage dailyUsage: [String: CodexCachedDailyUsage],
        model: String?,
        from startDate: Date,
        to endDate: Date
    ) -> RawTokenUsage {
        guard !dailyUsage.isEmpty else { return RawTokenUsage() }

        let normalizedModel = model?.isEmpty == false ? model : nil
        let cal = Calendar.current
        var currentDay = cal.startOfDay(for: startDate)
        var result = RawTokenUsage()

        while currentDay < endDate {
            let dayKey = codexDayKey(for: currentDay)
            if let usage = dailyUsage[dayKey] {
                result.inputTokens += usage.inputTokens
                result.outputTokens += usage.outputTokens
                result.cacheReadTokens += usage.cacheReadTokens
                result.reasoningTokens += usage.reasoningTokens

                let entryCost: Double
                if let model = normalizedModel, let price = modelPrice(for: model) {
                    entryCost = price.cost(
                        input: usage.inputTokens,
                        output: usage.outputTokens + usage.reasoningTokens,
                        cacheRead: usage.cacheReadTokens,
                        cacheWrite: 0
                    )
                    result.cost += entryCost
                } else {
                    entryCost = 0
                }

                if let model = normalizedModel {
                    result.perModel[model, default: PerModelUsage()].totalTokens += usage.totalTokens
                    result.perModel[model, default: PerModelUsage()].cost += entryCost
                    result.perModel[model, default: PerModelUsage()].sources.insert("Codex")
                }
            }

            guard let nextDay = cal.date(byAdding: .day, value: 1, to: currentDay) else { break }
            currentDay = nextDay
        }

        return result
    }

    private static func dailyUsage(fromRolloutLines lines: [String]) -> [String: CodexCachedDailyUsage] {
        let decoder = JSONDecoder()
        var previousSnapshot: CodexUsageSnapshot?
        var result: [String: CodexCachedDailyUsage] = [:]

        for line in lines {
            guard let data = line.data(using: .utf8),
                  let entry = try? decoder.decode(CodexRolloutEntry.self, from: data),
                  let timestamp = entry.timestamp,
                  let date = DateParser.parse(timestamp),
                  let snapshot = entry.tokenSnapshot else { continue }

            let delta = snapshot.delta(since: previousSnapshot)
            previousSnapshot = snapshot

            let usage = delta.normalizedUsage
            guard usage.totalTokens > 0 else { continue }

            let dayKey = codexDayKey(for: date)
            result[dayKey, default: .zero].accumulate(usage)
        }

        return result
    }

    private func overlappingSessions(from startDate: Date, to endDate: Date) -> [CodexSession] {
        let dbSessions = overlappingSessionsFromDB(from: startDate, to: endDate)
        let jsonlSessions = overlappingSessionsFromJSONL(from: startDate, to: endDate)

        // Merge by rolloutPath. DB entry wins because it carries model info;
        // JSONL-only paths fill gaps when state_5.sqlite is partially stale.
        var byPath: [String: CodexSession] = [:]
        dbSessions.forEach { byPath[$0.rolloutPath] = $0 }
        jsonlSessions.forEach { session in
            if byPath[session.rolloutPath] == nil {
                byPath[session.rolloutPath] = session
            }
        }
        return Array(byPath.values)
    }

    private func overlappingSessionsFromDB(from startDate: Date, to endDate: Date) -> [CodexSession] {
        var db: OpaquePointer?
        defer { sqlite3_close(db) }
        guard sqlite3_open_v2(dbPath, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
            return []
        }
        sqlite3_busy_timeout(db, 2000)

        let startEpoch = startDate.timeIntervalSince1970
        let endEpoch   = endDate.timeIntervalSince1970
        let query = """
            SELECT DISTINCT rollout_path, COALESCE(model, '')
            FROM threads
            WHERE updated_at >= ? AND created_at < ?
        """

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, query, -1, &stmt, nil) == SQLITE_OK else {
            return []
        }
        defer { sqlite3_finalize(stmt) }

        sqlite3_bind_int64(stmt, 1, Int64(startEpoch))
        sqlite3_bind_int64(stmt, 2, Int64(endEpoch))

        var sessions: [CodexSession] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            guard let rolloutPathPtr = sqlite3_column_text(stmt, 0) else { continue }
            let rolloutPath = String(cString: rolloutPathPtr)
            let model = sqlite3_column_text(stmt, 1).map { String(cString: $0) }
            sessions.append(CodexSession(rolloutPath: rolloutPath, model: model))
        }
        return sessions
    }

    /// Scans ~/.codex/sessions/YYYY/MM/DD/*.jsonl for files modified within the
    /// range. Used as a fallback when state_5.sqlite is stale (e.g. cross-midnight
    /// sessions not yet reflected in updated_at).
    private func overlappingSessionsFromJSONL(from startDate: Date, to endDate: Date) -> [CodexSession] {
        let cal = Calendar.autoupdatingCurrent
        let startDay = cal.startOfDay(for: startDate)
        let endDay = cal.startOfDay(for: endDate)
        let numberOfDays = cal.dateComponents([.day], from: startDay, to: endDay).day ?? 0
        // Look back 3 days before startDay to cover sessions that started before
        // the range but are still writing tokens into it (DB-stale edge cases).
        let lookback = [-3, -2, -1]
        let dirURLs = (lookback + (0...max(0, numberOfDays)).map { $0 }).compactMap { offset in
            cal.date(byAdding: .day, value: offset, to: startDay)
        }.map { day -> URL in
            let comps = cal.dateComponents([.year, .month, .day], from: day)
            return homeDir()
                .appendingPathComponent(".codex/sessions")
                .appendingPathComponent(String(format: "%04d", comps.year ?? 0))
                .appendingPathComponent(String(format: "%02d", comps.month ?? 0))
                .appendingPathComponent(String(format: "%02d", comps.day ?? 0))
        }

        return dirURLs.flatMap { dirURL -> [CodexSession] in
            guard FileManager.default.fileExists(atPath: dirURL.path),
                  let contents = try? FileManager.default.contentsOfDirectory(
                      at: dirURL,
                      includingPropertiesForKeys: [.contentModificationDateKey],
                      options: [.skipsHiddenFiles]
                  ) else { return [] }

            return contents.compactMap { fileURL -> CodexSession? in
                guard fileURL.pathExtension == "jsonl",
                      let mod = (try? fileURL.resourceValues(
                          forKeys: [.contentModificationDateKey]
                      ))?.contentModificationDate,
                      mod >= startDate else { return nil }
                return CodexSession(rolloutPath: fileURL.path, model: extractModel(from: fileURL))
            }
        }
    }

    /// Reads the first 64 KB of a rollout JSONL to find the model name from a
    /// `turn_context` entry (e.g. `{"type":"turn_context","payload":{"model":"gpt-5.4",...}}`).
    private func extractModel(from url: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }

        let data = handle.readData(ofLength: 65536)
        // Trim to the last complete newline to avoid mid-multibyte UTF-8 truncation
        let trimmedData: Data = data.lastIndex(of: UInt8(ascii: "\n"))
            .map { Data(data[...$0]) } ?? data
        let text = String(data: trimmedData, encoding: .utf8) ?? ""
        let decoder = JSONDecoder()

        return text.components(separatedBy: .newlines).compactMap { line -> String? in
            guard let lineData = line.data(using: .utf8),
                  let entry = try? decoder.decode(CodexModelEntry.self, from: lineData),
                  entry.type == "turn_context",
                  let model = entry.payload?.model,
                  !model.isEmpty else { return nil }
            return model
        }.first
    }

    private static func cachedUsage(
        fromRolloutAt url: URL,
        model: String?,
        from startDate: Date,
        to endDate: Date
    ) async -> RawTokenUsage {
        let rolloutDailyUsage: [String: CodexCachedDailyUsage]
        if let cached = await CodexRolloutUsageCache.shared.dailyUsage(for: url) {
            rolloutDailyUsage = cached
        } else {
            rolloutDailyUsage = dailyUsage(fromRolloutLines: readJSONLLines(at: url))
            await CodexRolloutUsageCache.shared.store(dailyUsage: rolloutDailyUsage, for: url)
        }

        return usage(fromDailyUsage: rolloutDailyUsage, model: model, from: startDate, to: endDate)
    }
}

private actor CodexRolloutUsageCache {
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

    func store(dailyUsage: [String: CodexCachedDailyUsage], for url: URL) async {
        await loadIfNeeded()

        guard let fileSignature = codexFileSignature(for: url) else { return }

        entries[url.path] = CodexRolloutUsageCacheEntry(
            fileSize: fileSignature.fileSize,
            modifiedAt: fileSignature.modifiedAt,
            timeZoneIdentifier: codexCacheTimeZoneIdentifier(),
            dailyUsage: dailyUsage
        )

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
            attributes: nil
        )

        let payload = CodexRolloutUsageCacheFile(entries: entries)
        guard let data = try? JSONEncoder().encode(payload) else { return }
        try? data.write(to: cacheURL, options: [.atomic])
        hasPendingChanges = false
    }
}

private struct CodexRolloutUsageCacheFile: Codable {
    let entries: [String: CodexRolloutUsageCacheEntry]
}

private struct CodexRolloutUsageCacheEntry: Codable {
    let fileSize: Int
    let modifiedAt: TimeInterval
    let timeZoneIdentifier: String
    let dailyUsage: [String: CodexCachedDailyUsage]
}

private struct CodexCachedDailyUsage: Codable {
    var inputTokens: Int = 0
    var outputTokens: Int = 0
    var cacheReadTokens: Int = 0
    var reasoningTokens: Int = 0

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

private struct CodexFileSignature {
    let fileSize: Int
    let modifiedAt: TimeInterval
}

private func codexFileSignature(for url: URL) -> CodexFileSignature? {
    guard let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey]),
          let modifiedAt = values.contentModificationDate,
          let fileSize = values.fileSize else {
        return nil
    }

    return CodexFileSignature(
        fileSize: fileSize,
        modifiedAt: modifiedAt.timeIntervalSince1970
    )
}

private func codexRolloutUsageCacheURL() -> URL {
    homeDir()
        .appendingPathComponent("Library")
        .appendingPathComponent("Application Support")
        .appendingPathComponent("Toki")
        .appendingPathComponent("codex-rollout-cache.json")
}

func codexDayKey(for date: Date, timeZone: TimeZone) -> String {
    var cal = Calendar(identifier: .gregorian)
    cal.timeZone = timeZone
    let comps = cal.dateComponents([.year, .month, .day], from: date)
    return String(
        format: "%04d-%02d-%02d",
        comps.year ?? 0,
        comps.month ?? 0,
        comps.day ?? 0
    )
}

private func codexDayKey(for date: Date) -> String {
    codexDayKey(for: date, timeZone: TimeZone.autoupdatingCurrent)
}

private func codexCacheTimeZoneIdentifier() -> String {
    TimeZone.autoupdatingCurrent.identifier
}

private struct CodexModelEntry: Decodable {
    let type: String?
    let payload: Payload?

    struct Payload: Decodable {
        let model: String?
    }
}

private struct CodexSession {
    let rolloutPath: String
    let model: String?
}

private struct CodexRolloutEntry: Decodable {
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
            reasoningOutputTokens: totalUsage.reasoningOutputTokens ?? 0
        )
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

private struct TotalTokenUsage: Decodable {
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

private struct CodexUsageSnapshot {
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
            reasoningOutputTokens: max(0, reasoningOutputTokens - previous.reasoningOutputTokens)
        )
    }

    var normalizedUsage: RawTokenUsage {
        let uncachedInput = max(0, inputTokens - cachedInputTokens)
        let nonReasoningOutput = max(0, outputTokens - reasoningOutputTokens)

        return RawTokenUsage(
            inputTokens: uncachedInput,
            outputTokens: nonReasoningOutput,
            cacheReadTokens: cachedInputTokens,
            reasoningTokens: reasoningOutputTokens
        )
    }
}
