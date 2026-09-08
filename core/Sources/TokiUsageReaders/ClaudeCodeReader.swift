import Foundation
import TokiUsageCore

/// Reads selected Claude projects and transcripts JSONL roots.
/// Deduplicates by requestId, keeps max token counts per message
public struct ClaudeCodeReader: TokenReader {
    public let name = "Claude Code"
    private let projectsURLOverride: URL?
    private let transcriptsURLOverride: URL?
    private let usageCache: ClaudeUsageCache
    private let attributionHomeDirectory: URL

    public init(
        projectsURLOverride: URL? = nil,
        usageCache: ClaudeUsageCache = .shared,
        transcriptsURLOverride: URL? = nil,
        attributionHomeDirectory: URL? = nil) {
        self.projectsURLOverride = projectsURLOverride
        self.transcriptsURLOverride = transcriptsURLOverride
            ?? (projectsURLOverride == nil ? homeDir().appendingPathComponent(".claude/transcripts") : nil)
        self.usageCache = usageCache
        self.attributionHomeDirectory = attributionHomeDirectory
            ?? Self.resolveAttributionHomeDirectory(projectsURLOverride: projectsURLOverride)
    }

    private var projectsURL: URL {
        projectsURLOverride ?? homeDir().appendingPathComponent(".claude/projects")
    }

    public func readUsage(from startDate: Date, to endDate: Date) async throws -> RawTokenUsage {
        let limits = PiCompatibleReadLimits.default
        var visitedEntryCount = 0
        var files = Set<URL>()
        var seenRoots = Set<URL>()
        var transcriptStreamIDs = Set<String>()
        let transcriptRoot = transcriptsURLOverride?.resolvingSymlinksInPath().standardizedFileURL
        for root in [projectsURL] + [transcriptsURLOverride].compactMap({ $0 }) {
            let canonical = root.resolvingSymlinksInPath().standardizedFileURL
            guard seenRoots.insert(canonical).inserted else { continue }
            do {
                let discovered = try findUsageFiles(
                    in: canonical,
                    withExtension: "jsonl",
                    maximumFileCount: limits.maximumFileCount + 1,
                    maximumEntryCount: limits.maximumEntryCount,
                    visitedEntryCount: &visitedEntryCount)
                files.formUnion(discovered)
                if canonical == transcriptRoot {
                    transcriptStreamIDs.formUnion(discovered.map(\.path))
                }
            } catch {
                throw ClaudeReadDiagnostic.redactingPaths(in: error)
            }
            guard files.count <= limits.maximumFileCount else {
                throw PiCompatibleReaderError.tooManyFiles(files.count)
            }
        }
        await usageCache.beginBatch()
        var sessions: [(streamID: String, records: [ClaudeCachedUsageRecord])] = []
        var recordCount = 0
        do {
            for file in files.sorted(by: { $0.path < $1.path }) {
                try Task.checkCancellation()
                let records = try await cachedUsageRecords(at: file)
                try recordUsageEvents(
                    records.count, total: &recordCount, maximum: limits.maximumUnreconciledEventCount)
                sessions.append((streamID: file.path, records: records))
            }
            try Task.checkCancellation()
        } catch {
            await usageCache.endBatch()
            throw ClaudeReadDiagnostic.redactingPaths(in: error)
        }

        await usageCache.endBatch()
        let result = Self.usage(
            fromSessions: sessions,
            from: startDate,
            to: endDate,
            source: name,
            attributionHomeDirectory: attributionHomeDirectory,
            transcriptStreamIDs: transcriptStreamIDs)
        try Task.checkCancellation()
        guard result.tokenEvents.count <= limits.maximumEventCount else {
            throw PiCompatibleReaderError.tooManyEvents(result.tokenEvents.count)
        }
        return result
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

    private func cachedUsageRecords(at url: URL) async throws -> [ClaudeCachedUsageRecord] {
        if let cached = await usageCache.records(for: url) {
            return cached
        }

        let parsed = try Self.parseUsageRecords(at: url)
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
        attributionHomeDirectory: URL,
        inferProjectFromStream: Bool) {
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
                cacheWriteOneHour: record.cacheWriteOneHour,
                attribution: attribution(
                    for: record,
                    streamID: streamID,
                    homeDirectory: attributionHomeDirectory,
                    inferProjectFromStream: inferProjectFromStream))

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
        attributionHomeDirectory: URL,
        transcriptStreamIDs: Set<String> = []) -> RawTokenUsage {
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
                attributionHomeDirectory: attributionHomeDirectory,
                inferProjectFromStream: !transcriptStreamIDs.contains(session.streamID))
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
               let price = modelPrice(for: priceLookupKey, at: entry.timestamp) {
                entryCost = price.cost(
                    input: entry.input,
                    output: entry.output,
                    cacheRead: entry.cacheRead,
                    cacheWrite: entry.cacheWrite - entry.cacheWriteOneHour,
                    cacheWriteOneHour: entry.cacheWriteOneHour)
                result.cost += entryCost
            } else {
                entryCost = 0
            }

            result.accumulatePerModelUsage(
                model: modelKey,
                source: source,
                totalTokens: entry.input + entry.output + entry.cacheRead + entry.cacheWrite,
                cost: entryCost)

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

    private static func parseUsageRecords(at url: URL) throws -> [ClaudeCachedUsageRecord] {
        var records: [ClaudeCachedUsageRecord] = []
        let decoder = JSONDecoder()
        try forEachBoundedJSONLLine(at: url, limits: .default) { line, index in
            guard let data = line.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  object["type"] is String else {
                throw LocalUsageReaderDiagnosticError.decodeFailed(source: "Claude Code", stage: "session")
            }
            // The cache's line indices must remain file-relative for id-less records.
            if let record = parseUsageRecord(line: line, index: index, decoder: decoder) {
                guard records.count < PiCompatibleReadLimits.default.maximumEventCount else {
                    throw PiCompatibleReaderError.tooManyEvents(records.count + 1)
                }
                records.append(record)
            } else if object["type"] as? String == "assistant",
                      let message = object["message"] as? [String: Any],
                      let usage = message["usage"], !(usage is NSNull) {
                throw LocalUsageReaderDiagnosticError.decodeFailed(source: "Claude Code", stage: "session usage")
            }
        }
        return records
    }

    private static func parseUsageRecords(from lines: [String]) -> [ClaudeCachedUsageRecord] {
        let decoder = JSONDecoder()
        return lines.enumerated().compactMap { item -> ClaudeCachedUsageRecord? in
            parseUsageRecord(line: item.element, index: item.offset, decoder: decoder)
        }
    }

    private static func parseUsageRecord(line: String, index: Int, decoder: JSONDecoder) -> ClaudeCachedUsageRecord? {
        guard let data = line.data(using: .utf8),
              let msg = try? decoder.decode(RawMessage.self, from: data),
              msg.type == "assistant",
              let tsStr = msg.timestamp,
              let date = DateParser.parse(tsStr),
              let usage = msg.message?.usage else { return nil }

        let cacheWrite = cacheWriteTokens(for: usage)

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
            cacheWrite: cacheWrite.total,
            cacheWriteOneHour: cacheWrite.oneHour)
    }

    private static func cacheWriteTokens(for usage: RawMessage.Message.Usage) -> (total: Int, oneHour: Int) {
        let oneHour = max(usage.cacheCreation?.ephemeral1HourInputTokens ?? 0, 0)
        if let aggregate = usage.cacheCreationInputTokens, aggregate >= 0 {
            return (aggregate, min(aggregate, oneHour))
        }

        let fiveMinutes = max(usage.cacheCreation?.ephemeral5MinuteInputTokens ?? 0, 0)
        let sum = fiveMinutes.addingReportingOverflow(oneHour)
        guard !sum.overflow else {
            return (0, 0)
        }
        return (sum.partialValue, oneHour)
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

private struct ClaudeReadDiagnostic: LocalizedError {
    let errorDescription: String?

    static func redactingPaths(in error: Error) -> Error {
        guard let sourceError = error as? PiCompatibleReaderError else { return error }
        let description: String
        switch sourceError {
        case .unreadableFile:
            description = "Claude Code source could not be read."
        case .fileTooLarge:
            description = "Claude Code source exceeds the supported size."
        case .lineTooLong:
            description = "Claude Code source contains an oversized record."
        case let .invalidUTF8(_, line):
            description = "Claude Code source contains invalid UTF-8 at line \(line + 1)."
        case .tooManyFiles, .tooManyEvents, .tooManyEntries:
            return error
        }
        return Self(errorDescription: description)
    }
}

private struct Entry {
    let timestamp: Date
    let model: String?
    let input, output, cacheRead, cacheWrite, cacheWriteOneHour: Int
    let attribution: UsageAttribution?

    func mergedMax(with other: Entry) -> Entry {
        Entry(
            timestamp: max(timestamp, other.timestamp),
            model: model ?? other.model,
            input: max(input, other.input),
            output: max(output, other.output),
            cacheRead: max(cacheRead, other.cacheRead),
            cacheWrite: max(cacheWrite, other.cacheWrite),
            cacheWriteOneHour: max(cacheWriteOneHour, other.cacheWriteOneHour),
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
                key: UsageModelGrouping.groupingKey(for: modelKey))
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
    homeDirectory: URL,
    inferProjectFromStream: Bool) -> UsageAttribution {
    let sessionID = record.sessionID
        ?? usageSessionID(fromPath: streamID).trimmedNonEmpty
        ?? record.requestId

    if let cwd = record.cwd?.trimmedNonEmpty {
        return UsageAttribution(
            projectPath: cwd,
            sessionID: sessionID,
            quality: .exact)
    }

    if inferProjectFromStream, let attribution = inferredAttributionFromClaudeStreamID(
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
            let cacheCreation: CacheCreation?

            enum CodingKeys: String, CodingKey {
                case inputTokens = "input_tokens"
                case outputTokens = "output_tokens"
                case cacheReadInputTokens = "cache_read_input_tokens"
                case cacheCreationInputTokens = "cache_creation_input_tokens"
                case cacheCreation = "cache_creation"
            }

            init(from decoder: Decoder) throws {
                let container = try decoder.container(keyedBy: CodingKeys.self)
                inputTokens = try container.decodeIfPresent(Int.self, forKey: .inputTokens)
                outputTokens = try container.decodeIfPresent(Int.self, forKey: .outputTokens)
                cacheReadInputTokens = try container.decodeIfPresent(Int.self, forKey: .cacheReadInputTokens)
                cacheCreationInputTokens = try container.decodeIfPresent(
                    Int.self,
                    forKey: .cacheCreationInputTokens)
                cacheCreation = try? container.decode(CacheCreation.self, forKey: .cacheCreation)
            }

            struct CacheCreation: Decodable {
                let ephemeral5MinuteInputTokens: Int?
                let ephemeral1HourInputTokens: Int?

                enum CodingKeys: String, CodingKey {
                    case ephemeral5MinuteInputTokens = "ephemeral_5m_input_tokens"
                    case ephemeral1HourInputTokens = "ephemeral_1h_input_tokens"
                }
            }
        }
    }
}

private extension String {
    var trimmingLeadingHyphens: String {
        String(drop { $0 == "-" })
    }
}
