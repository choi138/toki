import Foundation
import TokiSyncProtocol
import TokiUsageCore

/// Reads Factory Droid cumulative session summaries from ~/.factory/sessions.
public struct FactoryDroidReader: TokenReader {
    public static let sourceName = "Factory Droid"

    public let name = Self.sourceName
    private let sessionsURLOverride: URL?
    private let readLimits: PiCompatibleReadLimits

    public init(sessionsURLOverride: URL? = nil) {
        self.sessionsURLOverride = sessionsURLOverride
        readLimits = .default
    }

    init(sessionsURLOverride: URL?, readLimits: PiCompatibleReadLimits) {
        self.sessionsURLOverride = sessionsURLOverride
        self.readLimits = readLimits
    }

    private var sessionsURL: URL {
        sessionsURLOverride ?? homeDir().appendingPathComponent(".factory/sessions")
    }

    public func readUsage(from startDate: Date, to endDate: Date) async throws -> RawTokenUsage {
        let files = try findFilesThrowing(
            in: sessionsURL,
            withExtension: "json",
            maximumFileCount: readLimits.maximumFileCount,
            maximumEntryCount: readLimits.maximumEntryCount)
            .filter { $0.lastPathComponent.hasSuffix(".settings.json") }
        var canonicalPaths = Set<String>()
        var summariesBySession: [String: FactoryDroidSummary] = [:]
        var activityKeys = Set<String>()
        var result = RawTokenUsage()
        var activityEvents: [ActivityTimeEvent<String>] = []
        var decodedSettingsCount = 0
        var hadSettingsDecodeFailure = false
        var examinedEventCount = 0

        for file in files.sorted(by: { $0.path < $1.path }) {
            try Task.checkCancellation()
            let canonicalPath = file
                .resolvingSymlinksInPath()
                .standardizedFileURL
                .path
            guard canonicalPaths.insert(canonicalPath).inserted,
                  let modifiedDate = (try? file.resourceValues(
                      forKeys: [.contentModificationDateKey]))?
                  .contentModificationDate else {
                continue
            }
            let data = try boundedUsageFileData(at: file, maximumBytes: readLimits.maximumFileBytes)
            guard let settings = try? JSONDecoder().decode(FactoryDroidSettings.self, from: data) else {
                hadSettingsDecodeFailure = true
                continue
            }
            decodedSettingsCount += 1
            let model = normalizedModelID(settings.model)
            let sessionID = factoryDroidSessionID(from: file)
            let transcript = try factoryDroidTranscript(
                settingsURL: file,
                sessionID: sessionID,
                from: startDate,
                to: endDate,
                readLimits: readLimits,
                examinedEventCount: &examinedEventCount)
            appendFactoryDroidActivities(
                transcript,
                model: model,
                activityKeys: &activityKeys,
                activityEvents: &activityEvents)

            let summary = FactoryDroidSummary(
                modifiedDate: modifiedDate,
                model: model,
                provider: settings.providerLock?.trimmedNonEmpty
                    ?? inferredUsageProvider(from: model),
                tokenUsage: settings.tokenUsage,
                transcript: transcript)
            if let existing = summariesBySession[transcript.sessionID] {
                let prefersIncomingMetadata = existing.modifiedDate < modifiedDate
                let metadata = prefersIncomingMetadata ? summary : existing
                summariesBySession[transcript.sessionID] = FactoryDroidSummary(
                    modifiedDate: metadata.modifiedDate,
                    model: metadata.model,
                    provider: metadata.provider,
                    tokenUsage: metadata.tokenUsage,
                    transcript: mergingFactoryDroidTranscripts(
                        existing.transcript,
                        transcript,
                        prefersIncomingMetadata: prefersIncomingMetadata))
            } else {
                summariesBySession[transcript.sessionID] = summary
            }
        }

        try appendFactoryDroidSummaries(
            summariesBySession,
            from: startDate,
            to: endDate,
            usage: &result)

        return try finalizedFactoryDroidUsage(
            result,
            activityEvents: activityEvents,
            clippingEndDate: endDate,
            decodedSettingsCount: decodedSettingsCount,
            hadSettingsDecodeFailure: hadSettingsDecodeFailure)
    }
}

private struct FactoryDroidSummary {
    let modifiedDate: Date
    let model: String?
    let provider: String?
    let tokenUsage: FactoryDroidTokenUsage?
    let transcript: FactoryDroidTranscript
}

private func appendFactoryDroidSummaries(
    _ summariesBySession: [String: FactoryDroidSummary],
    from startDate: Date,
    to endDate: Date,
    usage: inout RawTokenUsage) throws {
    for sessionID in summariesBySession.keys.sorted() {
        try Task.checkCancellation()
        guard let summary = summariesBySession[sessionID] else { continue }
        let attribution = UsageAttribution(
            projectPath: summary.transcript.projectPath,
            sessionID: summary.transcript.sessionID,
            quality: summary.transcript.projectPath == nil ? .unknown : .exact)

        if summary.transcript.hasTokenUsageRecords {
            for record in summary.transcript.tokenUsageRecords {
                try Task.checkCancellation()
                appendFactoryDroidTokenUsage(
                    record.tokenUsage,
                    timestamp: record.timestamp,
                    summary: summary,
                    attribution: attribution,
                    usage: &usage)
            }
        } else if summary.modifiedDate >= startDate,
                  summary.modifiedDate < endDate,
                  let tokenUsage = summary.tokenUsage {
            appendFactoryDroidTokenUsage(
                tokenUsage,
                timestamp: summary.modifiedDate,
                summary: summary,
                attribution: attribution,
                usage: &usage)
        }
    }
}

private func appendFactoryDroidTokenUsage(
    _ tokenUsage: FactoryDroidTokenUsage,
    timestamp: Date,
    summary: FactoryDroidSummary,
    attribution: UsageAttribution,
    usage: inout RawTokenUsage) {
    let counts = FactoryDroidTokenCounts(tokenUsage)
    guard counts.totalTokens > 0,
          let totalTokens = usage.accumulateTokenCounts(
              input: counts.input,
              output: counts.output,
              cacheRead: counts.cacheRead,
              cacheWrite: counts.cacheWrite,
              reasoning: counts.reasoning) else {
        return
    }
    usage.accumulatePerModelUsage(
        model: summary.model,
        source: FactoryDroidReader.sourceName,
        totalTokens: totalTokens)
    usage.recordTokenEvent(
        timestamp: timestamp,
        source: FactoryDroidReader.sourceName,
        model: summary.model,
        provider: summary.provider,
        inputTokens: counts.input,
        outputTokens: counts.output,
        cacheReadTokens: counts.cacheRead,
        cacheWriteTokens: counts.cacheWrite,
        reasoningTokens: counts.reasoning,
        costIsKnown: false,
        attribution: attribution)
}

private func appendFactoryDroidActivities(
    _ transcript: FactoryDroidTranscript,
    model: String?,
    activityKeys: inout Set<String>,
    activityEvents: inout [ActivityTimeEvent<String>]) {
    for activity in transcript.activities {
        let activityKey = "\(transcript.sessionID)\u{0}\(activity.id)"
        guard activityKeys.insert(activityKey).inserted else { continue }
        activityEvents.append(ActivityTimeEvent(
            streamID: transcript.sessionID,
            timestamp: activity.timestamp,
            key: UsageModelGrouping.groupingKey(for: model)))
    }
}

private func finalizedFactoryDroidUsage(
    _ usage: RawTokenUsage,
    activityEvents: [ActivityTimeEvent<String>],
    clippingEndDate: Date,
    decodedSettingsCount: Int,
    hadSettingsDecodeFailure: Bool) throws -> RawTokenUsage {
    var usage = usage
    usage.mergeActivityEvents(
        activityEvents,
        source: FactoryDroidReader.sourceName,
        clippingEndDate: clippingEndDate)
    if decodedSettingsCount == 0, hadSettingsDecodeFailure {
        throw LocalUsageReaderDiagnosticError.decodeFailed(
            source: FactoryDroidReader.sourceName,
            stage: "settings")
    }
    return usage
}

private struct FactoryDroidSettings: Decodable {
    let model: String?
    let providerLock: String?
    let tokenUsage: FactoryDroidTokenUsage?

    enum CodingKeys: String, CodingKey {
        case model, providerLock, tokenUsage
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        model = try? container.decodeIfPresent(String.self, forKey: .model)
        providerLock = try? container.decodeIfPresent(String.self, forKey: .providerLock)
        tokenUsage = try? container.decodeIfPresent(
            FactoryDroidTokenUsage.self,
            forKey: .tokenUsage)
    }
}

private struct FactoryDroidTokenUsage: Decodable {
    let inputTokens: Int?
    let outputTokens: Int?
    let cacheCreationTokens: Int?
    let cacheReadTokens: Int?
    let thinkingTokens: Int?

    enum CodingKeys: String, CodingKey {
        case inputTokens, outputTokens, cacheCreationTokens, cacheReadTokens, thinkingTokens
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        inputTokens = try? container.decodeIfPresent(Int.self, forKey: .inputTokens)
        outputTokens = try? container.decodeIfPresent(Int.self, forKey: .outputTokens)
        cacheCreationTokens = try? container.decodeIfPresent(
            Int.self,
            forKey: .cacheCreationTokens)
        cacheReadTokens = try? container.decodeIfPresent(Int.self, forKey: .cacheReadTokens)
        thinkingTokens = try? container.decodeIfPresent(Int.self, forKey: .thinkingTokens)
    }

    func fillingMissingValues(from fallback: Self) -> Self {
        Self(
            inputTokens: inputTokens ?? validFactoryDroidTokenCount(fallback.inputTokens),
            outputTokens: outputTokens ?? validFactoryDroidTokenCount(fallback.outputTokens),
            cacheCreationTokens: cacheCreationTokens
                ?? validFactoryDroidTokenCount(fallback.cacheCreationTokens),
            cacheReadTokens: cacheReadTokens
                ?? validFactoryDroidTokenCount(fallback.cacheReadTokens),
            thinkingTokens: thinkingTokens
                ?? validFactoryDroidTokenCount(fallback.thinkingTokens))
    }

    private init(
        inputTokens: Int?,
        outputTokens: Int?,
        cacheCreationTokens: Int?,
        cacheReadTokens: Int?,
        thinkingTokens: Int?) {
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.cacheCreationTokens = cacheCreationTokens
        self.cacheReadTokens = cacheReadTokens
        self.thinkingTokens = thinkingTokens
    }
}

private func validFactoryDroidTokenCount(_ value: Int?) -> Int? {
    guard let value,
          (0...RemoteUsageSnapshotValidator.maximumTokenCountPerBucket).contains(value) else {
        return nil
    }
    return value
}

private struct FactoryDroidTokenCounts {
    let input: Int
    let output: Int
    let cacheRead: Int
    let cacheWrite: Int
    let reasoning: Int

    init(_ usage: FactoryDroidTokenUsage) {
        input = max(0, usage.inputTokens ?? 0)
        output = max(0, usage.outputTokens ?? 0)
        cacheRead = max(0, usage.cacheReadTokens ?? 0)
        cacheWrite = max(0, usage.cacheCreationTokens ?? 0)
        reasoning = max(0, usage.thinkingTokens ?? 0)
    }

    var totalTokens: Int {
        checkedTokenTotal(input, output, cacheRead, cacheWrite, reasoning) ?? 0
    }
}

private struct FactoryDroidTranscriptEntry: Decodable {
    let type: String?
    let id: String?
    let timestamp: String?
    let cwd: String?
    let message: Message?

    enum CodingKeys: String, CodingKey {
        case type, id, timestamp, cwd, message
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        type = try? container.decodeIfPresent(String.self, forKey: .type)
        id = try? container.decodeIfPresent(String.self, forKey: .id)
        timestamp = try? container.decodeIfPresent(String.self, forKey: .timestamp)
        cwd = try? container.decodeIfPresent(String.self, forKey: .cwd)
        message = try? container.decodeIfPresent(Message.self, forKey: .message)
    }

    struct Message: Decodable {
        let role: String?
        let id: String?
        let usage: FactoryDroidTokenUsage?

        enum CodingKeys: String, CodingKey {
            case role, id, usage
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            role = try? container.decodeIfPresent(String.self, forKey: .role)
            id = try? container.decodeIfPresent(String.self, forKey: .id)
            usage = try? container.decodeIfPresent(FactoryDroidTokenUsage.self, forKey: .usage)
        }
    }
}

private struct FactoryDroidTranscript {
    let sessionID: String
    let projectPath: String?
    let activities: [FactoryDroidActivity]
    let tokenUsageRecords: [FactoryDroidTokenUsageRecord]
    let hasTokenUsageRecords: Bool
}

private struct FactoryDroidActivity {
    let id: String
    let timestamp: Date
}

private struct FactoryDroidTokenUsageRecord {
    let id: String
    let timestamp: Date
    let tokenUsage: FactoryDroidTokenUsage
}

private func mergingFactoryDroidTranscripts(
    _ existing: FactoryDroidTranscript,
    _ incoming: FactoryDroidTranscript,
    prefersIncomingMetadata: Bool) -> FactoryDroidTranscript {
    let preferred = prefersIncomingMetadata ? incoming : existing
    let fallback = prefersIncomingMetadata ? existing : incoming
    var activitiesByID = Dictionary(
        uniqueKeysWithValues: fallback.activities.map { ($0.id, $0) })
    for activity in preferred.activities {
        activitiesByID[activity.id] = activity
    }
    var tokenUsageRecordsByID = Dictionary(
        uniqueKeysWithValues: fallback.tokenUsageRecords.map { ($0.id, $0) })
    for record in preferred.tokenUsageRecords {
        if let existing = tokenUsageRecordsByID[record.id] {
            tokenUsageRecordsByID[record.id] = FactoryDroidTokenUsageRecord(
                id: record.id,
                timestamp: record.timestamp,
                tokenUsage: record.tokenUsage.fillingMissingValues(
                    from: existing.tokenUsage))
        } else {
            tokenUsageRecordsByID[record.id] = record
        }
    }

    return FactoryDroidTranscript(
        sessionID: preferred.sessionID,
        projectPath: preferred.projectPath ?? fallback.projectPath,
        activities: activitiesByID.values.sorted {
            $0.timestamp == $1.timestamp ? $0.id < $1.id : $0.timestamp < $1.timestamp
        },
        tokenUsageRecords: tokenUsageRecordsByID.values.sorted {
            $0.timestamp == $1.timestamp ? $0.id < $1.id : $0.timestamp < $1.timestamp
        },
        hasTokenUsageRecords: existing.hasTokenUsageRecords || incoming.hasTokenUsageRecords)
}

private func factoryDroidTranscript(
    settingsURL: URL,
    sessionID: String,
    from startDate: Date,
    to endDate: Date,
    readLimits: PiCompatibleReadLimits,
    examinedEventCount: inout Int) throws -> FactoryDroidTranscript {
    let transcriptURL = settingsURL
        .deletingPathExtension()
        .deletingPathExtension()
        .appendingPathExtension("jsonl")
    let decoder = JSONDecoder()
    var resolvedSessionID = sessionID
    var projectPath: String?
    var activities: [FactoryDroidActivity] = []
    var activityIDs = Set<String>()
    var tokenUsageRecords: [FactoryDroidTokenUsageRecord] = []
    var tokenUsageIDs = Set<String>()
    var hasTokenUsageRecords = false

    if FileManager.default.fileExists(atPath: transcriptURL.path) {
        try forEachJSONLLineThrowing(at: transcriptURL, limits: readLimits) { line, _ in
            try Task.checkCancellation()
            guard let data = line.data(using: .utf8),
                  let entry = try? decoder.decode(FactoryDroidTranscriptEntry.self, from: data) else {
                return
            }

            if entry.type == "session_start" {
                resolvedSessionID = entry.id?.trimmedNonEmpty ?? resolvedSessionID
                projectPath = entry.cwd?.trimmedNonEmpty ?? projectPath
                return
            }

            guard entry.type == "message",
                  entry.message?.role == "assistant",
                  let timestamp = entry.timestamp.flatMap(DateParser.parse) else {
                return
            }
            try recordUsageEvents(
                1,
                total: &examinedEventCount,
                maximum: readLimits.maximumEventCount)
            let activityID = entry.id?.trimmedNonEmpty
                ?? entry.message?.id?.trimmedNonEmpty
                ?? line
            if timestamp >= startDate,
               timestamp < endDate,
               activityIDs.insert(activityID).inserted {
                activities.append(FactoryDroidActivity(
                    id: activityID,
                    timestamp: timestamp))
            }
            if let tokenUsage = entry.message?.usage,
               FactoryDroidTokenCounts(tokenUsage).totalTokens > 0 {
                hasTokenUsageRecords = true
                if timestamp >= startDate,
                   timestamp < endDate,
                   tokenUsageIDs.insert(activityID).inserted {
                    tokenUsageRecords.append(FactoryDroidTokenUsageRecord(
                        id: activityID,
                        timestamp: timestamp,
                        tokenUsage: tokenUsage))
                }
            }
        }
    }

    return FactoryDroidTranscript(
        sessionID: resolvedSessionID,
        projectPath: projectPath,
        activities: activities.sorted { $0.timestamp < $1.timestamp },
        tokenUsageRecords: tokenUsageRecords.sorted { $0.timestamp < $1.timestamp },
        hasTokenUsageRecords: hasTokenUsageRecords)
}

private func factoryDroidSessionID(from url: URL) -> String {
    let fileName = url.lastPathComponent
    return String(fileName.dropLast(".settings.json".count))
}
