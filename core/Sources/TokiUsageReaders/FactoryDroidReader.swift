import Foundation
import TokiUsageCore

/// Reads Factory Droid cumulative session summaries from ~/.factory/sessions.
public struct FactoryDroidReader: TokenReader {
    public static let sourceName = "Factory Droid"

    public let name = Self.sourceName
    private let sessionsURLOverride: URL?

    public init(sessionsURLOverride: URL? = nil) {
        self.sessionsURLOverride = sessionsURLOverride
    }

    private var sessionsURL: URL {
        sessionsURLOverride ?? homeDir().appendingPathComponent(".factory/sessions")
    }

    public func readUsage(from startDate: Date, to endDate: Date) async throws -> RawTokenUsage {
        let files = findFiles(in: sessionsURL, withExtension: "json")
            .filter { $0.lastPathComponent.hasSuffix(".settings.json") }
        var canonicalPaths = Set<String>()
        var summariesBySession: [String: FactoryDroidSummary] = [:]
        var activityKeys = Set<String>()
        var result = RawTokenUsage()
        var activityEvents: [ActivityTimeEvent<String>] = []
        var decodedSettingsCount = 0
        var hadSettingsDecodeFailure = false

        for file in files.sorted(by: { $0.path < $1.path }) {
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
            guard let data = try? Data(contentsOf: file),
                  let settings = try? JSONDecoder().decode(FactoryDroidSettings.self, from: data) else {
                hadSettingsDecodeFailure = true
                continue
            }
            decodedSettingsCount += 1
            let model = normalizedModelID(settings.model)
            let sessionID = factoryDroidSessionID(from: file)
            let transcript = factoryDroidTranscript(
                settingsURL: file,
                sessionID: sessionID,
                from: startDate,
                to: endDate)
            appendFactoryDroidActivities(
                transcript,
                model: model,
                activityKeys: &activityKeys,
                activityEvents: &activityEvents)

            if let tokenUsage = settings.tokenUsage {
                let summary = FactoryDroidSummary(
                    modifiedDate: modifiedDate,
                    model: model,
                    provider: settings.providerLock?.trimmedNonEmpty
                        ?? inferredUsageProvider(from: model),
                    tokenUsage: tokenUsage,
                    transcript: transcript)
                if summariesBySession[transcript.sessionID]?.modifiedDate ?? .distantPast
                    < modifiedDate {
                    summariesBySession[transcript.sessionID] = summary
                }
            }
        }

        appendFactoryDroidSummaries(
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
    let tokenUsage: FactoryDroidTokenUsage
    let transcript: FactoryDroidTranscript
}

private func appendFactoryDroidSummaries(
    _ summariesBySession: [String: FactoryDroidSummary],
    from startDate: Date,
    to endDate: Date,
    usage: inout RawTokenUsage) {
    for sessionID in summariesBySession.keys.sorted() {
        guard let summary = summariesBySession[sessionID],
              summary.modifiedDate >= startDate,
              summary.modifiedDate < endDate else {
            continue
        }
        let counts = FactoryDroidTokenCounts(summary.tokenUsage)
        guard counts.totalTokens > 0 else { continue }
        let attribution = UsageAttribution(
            projectPath: summary.transcript.projectPath,
            sessionID: summary.transcript.sessionID,
            quality: summary.transcript.projectPath == nil ? .unknown : .exact)

        guard let totalTokens = usage.accumulateTokenCounts(
            input: counts.input,
            output: counts.output,
            cacheRead: counts.cacheRead,
            cacheWrite: counts.cacheWrite,
            reasoning: counts.reasoning) else {
            continue
        }
        usage.accumulatePerModelUsage(
            model: summary.model,
            source: FactoryDroidReader.sourceName,
            totalTokens: totalTokens)
        usage.recordTokenEvent(
            timestamp: summary.modifiedDate,
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

        enum CodingKeys: String, CodingKey {
            case role, id
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            role = try? container.decodeIfPresent(String.self, forKey: .role)
            id = try? container.decodeIfPresent(String.self, forKey: .id)
        }
    }
}

private struct FactoryDroidTranscript {
    let sessionID: String
    let projectPath: String?
    let activities: [FactoryDroidActivity]
}

private struct FactoryDroidActivity {
    let id: String
    let timestamp: Date
}

private func factoryDroidTranscript(
    settingsURL: URL,
    sessionID: String,
    from startDate: Date,
    to endDate: Date) -> FactoryDroidTranscript {
    let transcriptURL = settingsURL
        .deletingPathExtension()
        .deletingPathExtension()
        .appendingPathExtension("jsonl")
    let decoder = JSONDecoder()
    var resolvedSessionID = sessionID
    var projectPath: String?
    var activities: [FactoryDroidActivity] = []
    var activityIDs = Set<String>()

    for line in readJSONLLines(at: transcriptURL) {
        guard let data = line.data(using: .utf8),
              let entry = try? decoder.decode(FactoryDroidTranscriptEntry.self, from: data) else {
            continue
        }

        if entry.type == "session_start" {
            resolvedSessionID = entry.id?.trimmedNonEmpty ?? resolvedSessionID
            projectPath = entry.cwd?.trimmedNonEmpty ?? projectPath
            continue
        }

        guard entry.type == "message",
              entry.message?.role == "assistant",
              let timestamp = entry.timestamp.flatMap(DateParser.parse),
              timestamp >= startDate,
              timestamp < endDate else {
            continue
        }
        let activityID = entry.id?.trimmedNonEmpty
            ?? entry.message?.id?.trimmedNonEmpty
            ?? line
        guard activityIDs.insert(activityID).inserted else { continue }
        activities.append(FactoryDroidActivity(
            id: activityID,
            timestamp: timestamp))
    }

    return FactoryDroidTranscript(
        sessionID: resolvedSessionID,
        projectPath: projectPath,
        activities: activities.sorted { $0.timestamp < $1.timestamp })
}

private func factoryDroidSessionID(from url: URL) -> String {
    let fileName = url.lastPathComponent
    return String(fileName.dropLast(".settings.json".count))
}
