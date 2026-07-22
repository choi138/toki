import Foundation
import TokiUsageCore

/// Reads ~/.claude/projects/**/*.jsonl
/// Deduplicates by requestId, keeps max token counts per message
public struct ClaudeCodeReader: TokenReader {
    public let name = "Claude Code"
    private let projectsURLOverride: URL?
    private let usageCache: ClaudeUsageCache
    private let attributionHomeDirectory: URL

    public init(
        projectsURLOverride: URL? = nil,
        usageCache: ClaudeUsageCache = .shared) {
        self.projectsURLOverride = projectsURLOverride
        self.usageCache = usageCache
        attributionHomeDirectory = Self.resolveAttributionHomeDirectory(
            projectsURLOverride: projectsURLOverride)
    }

    private var projectsURL: URL {
        projectsURLOverride ?? homeDir().appendingPathComponent(".claude/projects")
    }

    public func readUsage(from startDate: Date, to endDate: Date) async throws -> RawTokenUsage {
        guard FileManager.default.fileExists(atPath: projectsURL.path) else {
            return RawTokenUsage()
        }

        let files = findFiles(in: projectsURL, withExtension: "jsonl", modifiedAfter: startDate)
        await usageCache.beginBatch()
        var sessions: [(streamID: String, records: [ClaudeCachedUsageRecord])] = []

        for file in files {
            await sessions.append(
                (streamID: file.path, records: cachedUsageRecords(at: file)))
        }

        await usageCache.endBatch()
        return Self.usage(
            fromSessions: sessions,
            from: startDate,
            to: endDate,
            source: name,
            attributionHomeDirectory: attributionHomeDirectory)
    }
}

extension ClaudeCodeReader {
    static func usage(
        fromJSONLLines lines: [String],
        streamID: String,
        from startDate: Date,
        to endDate: Date,
        attributionHomeDirectory: URL = homeDir()) -> RawTokenUsage {
        usage(
            fromJSONLSessions: [(streamID: streamID, lines: lines)],
            from: startDate,
            to: endDate,
            attributionHomeDirectory: attributionHomeDirectory)
    }

    static func usage(
        fromJSONLSessions sessions: [(streamID: String, lines: [String])],
        from startDate: Date,
        to endDate: Date,
        attributionHomeDirectory: URL = homeDir()) -> RawTokenUsage {
        usage(
            fromSessions: sessions.map { session in
                (streamID: session.streamID, records: parseUsageRecords(from: session.lines))
            },
            from: startDate,
            to: endDate,
            source: "Claude Code",
            attributionHomeDirectory: attributionHomeDirectory)
    }

    private func cachedUsageRecords(at url: URL) async -> [ClaudeCachedUsageRecord] {
        if let cached = await usageCache.records(for: url) {
            return cached
        }

        let parsed = Self.parseUsageRecords(at: url)
        await usageCache.store(records: parsed, for: url)
        return parsed
    }

    private static func accumulate(
        records: [ClaudeCachedUsageRecord],
        streamID: String,
        from startDate: Date,
        to endDate: Date,
        dedup: inout [String: Entry],
        activityByKey: inout [String: ActivitySeries],
        attributionHomeDirectory: URL) {
        for record in records {
            let date = Date(timeIntervalSince1970: record.timestamp)
            guard date >= startDate, date < endDate else { continue }

            let key = record.requestId
                ?? record.messageID
                ?? "\(streamID)#\(record.lineIndex)"

            let entry = Entry(
                timestamp: date,
                model: record.model,
                input: record.input,
                output: record.output,
                cacheRead: record.cacheRead,
                cacheWrite: record.cacheWrite,
                attribution: attribution(
                    for: record,
                    streamID: streamID,
                    homeDirectory: attributionHomeDirectory))

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
        source: String,
        attributionHomeDirectory: URL) -> RawTokenUsage {
        var dedup: [String: Entry] = [:]
        var activityByKey: [String: ActivitySeries] = [:]

        for session in sessions {
            accumulate(
                records: session.records,
                streamID: session.streamID,
                from: startDate,
                to: endDate,
                dedup: &dedup,
                activityByKey: &activityByKey,
                attributionHomeDirectory: attributionHomeDirectory)
        }

        return usage(
            fromDedupedEntries: dedup,
            activityEvents: activityByKey.values.flatMap(\.events),
            source: source,
            clippingEndDate: endDate)
    }

    private static func usage(
        fromDedupedEntries dedup: [String: Entry],
        activityEvents: [ActivityTimeEvent<String>],
        source: String,
        clippingEndDate: Date) -> RawTokenUsage {
        var result = RawTokenUsage()

        for entry in dedup.values {
            result.inputTokens += entry.input
            result.outputTokens += entry.output
            result.cacheReadTokens += entry.cacheRead
            result.cacheWriteTokens += entry.cacheWrite

            let modelKey = normalizedModelID(entry.model)
            let entryCost: Double
            if let priceLookupKey = modelKey ?? entry.model,
               let price = modelPrice(for: priceLookupKey) {
                entryCost = price.cost(
                    input: entry.input,
                    output: entry.output,
                    cacheRead: entry.cacheRead,
                    cacheWrite: entry.cacheWrite)
                result.cost += entryCost
            } else {
                entryCost = 0
            }

            if let modelKey {
                let entryTokens = entry.input + entry.output + entry.cacheRead + entry.cacheWrite
                result.perModel[modelKey, default: PerModelUsage()].totalTokens += entryTokens
                result.perModel[modelKey, default: PerModelUsage()].cost += entryCost
                result.perModel[modelKey, default: PerModelUsage()].sources.insert(source)
            }

            result.recordTokenEvent(
                timestamp: entry.timestamp,
                source: source,
                model: modelKey,
                inputTokens: entry.input,
                outputTokens: entry.output,
                cacheReadTokens: entry.cacheRead,
                cacheWriteTokens: entry.cacheWrite,
                cost: entryCost,
                attribution: entry.attribution)
        }

        result.mergeActivityEvents(
            activityEvents,
            source: source,
            clippingEndDate: clippingEndDate)

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
                sessionID: msg.sessionID,
                cwd: msg.cwd,
                messageID: msg.message?.id,
                model: msg.message?.model,
                input: usage.inputTokens ?? 0,
                output: usage.outputTokens ?? 0,
                cacheRead: usage.cacheReadInputTokens ?? 0,
                cacheWrite: usage.cacheCreationInputTokens ?? 0)
        }
    }

    private static func resolveAttributionHomeDirectory(projectsURLOverride: URL?) -> URL {
        guard let projectsURLOverride,
              projectsURLOverride.lastPathComponent == "projects" else {
            return homeDir()
        }
        let claudeDirectory = projectsURLOverride.deletingLastPathComponent()
        guard claudeDirectory.lastPathComponent == ".claude" else {
            return homeDir()
        }
        return claudeDirectory.deletingLastPathComponent()
    }
}

// MARK: - Private Types

private struct Entry {
    let timestamp: Date
    let model: String?
    let input, output, cacheRead, cacheWrite: Int
    let attribution: UsageAttribution?

    func mergedMax(with other: Entry) -> Entry {
        Entry(
            timestamp: max(timestamp, other.timestamp),
            model: model ?? other.model,
            input: max(input, other.input),
            output: max(output, other.output),
            cacheRead: max(cacheRead, other.cacheRead),
            cacheWrite: max(cacheWrite, other.cacheWrite),
            attribution: bestUsageAttribution(attribution, other.attribution))
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

private func attribution(
    for record: ClaudeCachedUsageRecord,
    streamID: String,
    homeDirectory: URL) -> UsageAttribution {
    let sessionID = record.sessionID
        ?? usageSessionID(fromPath: streamID).trimmedNonEmpty
        ?? record.requestId

    if let cwd = record.cwd?.trimmedNonEmpty {
        return UsageAttribution(
            projectPath: cwd,
            sessionID: sessionID,
            quality: .exact)
    }

    if let attribution = inferredAttributionFromClaudeStreamID(
        streamID,
        sessionID: sessionID,
        homeDirectory: homeDirectory) {
        return attribution
    }

    return UsageAttribution(
        sessionID: sessionID,
        quality: .unknown)
}

private func inferredAttributionFromClaudeStreamID(
    _ streamID: String,
    sessionID: String?,
    homeDirectory: URL) -> UsageAttribution? {
    guard streamID.contains("/") else {
        guard let projectName = streamID.trimmedNonEmpty else { return nil }
        return UsageAttribution(
            projectName: projectName,
            sessionID: sessionID,
            quality: .inferred)
    }

    let url = URL(fileURLWithPath: streamID)
    let parentName = url.deletingLastPathComponent().lastPathComponent.trimmedNonEmpty
    guard let parentName, parentName != "." else {
        return nil
    }

    if parentName.hasPrefix("-") {
        guard let projectName = projectNameFromClaudeEncodedFolder(
            parentName,
            homeDirectory: homeDirectory) else {
            return nil
        }
        return UsageAttribution(
            projectName: projectName,
            sessionID: sessionID,
            quality: .inferred)
    }

    guard let projectPath = url.deletingLastPathComponent().path.trimmedNonEmpty else { return nil }
    return UsageAttribution(
        projectPath: projectPath,
        sessionID: sessionID,
        quality: .inferred)
}

private func projectNameFromClaudeEncodedFolder(
    _ parentName: String,
    homeDirectory: URL) -> String? {
    let encodedHomePath = homeDirectory.path.replacingOccurrences(of: "/", with: "-")
    if parentName.hasPrefix(encodedHomePath) {
        let suffix = parentName.dropFirst(encodedHomePath.count)
        if let projectName = String(suffix).trimmingLeadingHyphens.trimmedNonEmpty {
            return projectName
        }
    }

    return parentName.trimmingLeadingHyphens.trimmedNonEmpty
}

private struct RawMessage: Decodable {
    let type: String?
    let timestamp: String?
    let requestId: String?
    let sessionId: String?
    let sessionIdSnake: String?
    let cwd: String?
    let message: Message?

    var sessionID: String? {
        sessionId ?? sessionIdSnake
    }

    enum CodingKeys: String, CodingKey {
        case type
        case timestamp
        case requestId
        case sessionId
        case sessionIdSnake = "session_id"
        case cwd
        case message
    }

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

private extension String {
    var trimmingLeadingHyphens: String {
        String(drop { $0 == "-" })
    }
}
