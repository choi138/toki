import Foundation
import TokiUsageCore

/// Reads Gemini chat recordings (JSON and direct-message JSONL) under the selected tmp root.
public struct GeminiReader: TokenReader {
    public let name = "Gemini CLI"
    private let chatsBaseURLOverride: URL?
    private let readLimits: PiCompatibleReadLimits

    public init(chatsBaseURLOverride: URL? = nil) {
        self.chatsBaseURLOverride = chatsBaseURLOverride
        readLimits = .default
    }

    private var chatsBaseURL: URL {
        chatsBaseURLOverride ?? homeDir().appendingPathComponent(".gemini/tmp")
    }

    public func readUsage(from startDate: Date, to endDate: Date) async throws -> RawTokenUsage {
        var visitedEntryCount = 0
        var files = Set<URL>()
        for ext in ["json", "jsonl"] {
            try files.formUnion(findUsageFiles(
                in: chatsBaseURL,
                withExtension: ext,
                maximumFileCount: readLimits.maximumFileCount + 1,
                maximumEntryCount: readLimits.maximumEntryCount,
                visitedEntryCount: &visitedEntryCount))
            guard files.count <= readLimits.maximumFileCount else {
                throw PiCompatibleReaderError.tooManyFiles(files.count)
            }
        }
        var records: [GeminiMessageIdentity: GeminiUsageRecord] = [:]
        var result = RawTokenUsage()
        var activityEvents: [ActivityTimeEvent<String>] = []
        var recordCount = 0
        for file in files.sorted(by: { $0.path < $1.path }) {
            try Task.checkCancellation()
            if file.pathExtension == "jsonl" {
                try collectJSONL(at: file, records: &records, recordCount: &recordCount)
                continue
            }
            let data = try boundedUsageFileData(at: file, maximumBytes: readLimits.maximumFileBytes)
            try Task.checkCancellation()
            if let session = try? JSONDecoder().decode(GeminiSession.self, from: data) {
                for (index, message) in session.messages.enumerated() where message.type == "gemini" {
                    try collect(
                        message, sessionID: session.sessionID, modelHint: nil, file: file, index: index,
                        records: &records, recordCount: &recordCount)
                }
            } else {
                try accumulateLegacy(
                    data: data, file: file, from: startDate, to: endDate, result: &result,
                    activityEvents: &activityEvents, recordCount: &recordCount)
            }
        }
        guard records.count + result.tokenEvents.count <= readLimits.maximumEventCount else {
            throw PiCompatibleReaderError.tooManyEvents(records.count + result.tokenEvents.count)
        }
        // Select revisions before filtering dates so a superseded record cannot survive a boundary update.
        for record in records.values.sorted(by: GeminiUsageRecord.isOrdered)
            where record.date >= startDate && record.date < endDate {
            try Task.checkCancellation()
            let tokens = record.tokens
            let input = tokens.input ?? 0
            let output = (tokens.output ?? 0) + (tokens.tool ?? 0)
            let cacheRead = tokens.cached ?? 0
            let reasoning = tokens.thoughts ?? 0
            guard let total = result.accumulateTokenCounts(
                input: input, output: output, cacheRead: cacheRead, reasoning: reasoning) else {
                throw decodeError
            }
            let price = record.model.flatMap { modelPrice(for: $0, at: record.date) }
            let cost = price?.cost(input: input, output: output + reasoning, cacheRead: cacheRead, cacheWrite: 0) ?? 0
            result.cost += cost
            result.accumulatePerModelUsage(model: record.model, source: name, totalTokens: total, cost: cost)
            result.recordTokenEvent(
                timestamp: record.date, source: name, model: record.model,
                inputTokens: input, outputTokens: output, cacheReadTokens: cacheRead,
                reasoningTokens: reasoning, cost: cost, costIsKnown: price != nil,
                attribution: UsageAttribution(sessionID: record.sessionID, quality: .unknown))
            activityEvents.append(ActivityTimeEvent(
                streamID: record.sessionKey, timestamp: record.date,
                key: UsageModelGrouping.groupingKey(for: record.model)))
        }
        try Task.checkCancellation()
        result.mergeActivityEvents(activityEvents, source: name, clippingEndDate: endDate)
        return result
    }
}

private extension GeminiReader {
    var decodeError: LocalUsageReaderDiagnosticError {
        .decodeFailed(source: name, stage: "chat recording")
    }

    func collectJSONL(
        at file: URL, records: inout [GeminiMessageIdentity: GeminiUsageRecord],
        recordCount: inout Int) throws {
        let decoder = JSONDecoder()
        var sessionID: String?
        var currentModel: String?
        try forEachBoundedJSONLLine(at: file, limits: readLimits) { line, index in
            guard let data = line.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let message = try? decoder.decode(GeminiMessage.self, from: data) else {
                throw decodeError
            }
            // Stats snapshots need separate cumulative/delta reconciliation.
            guard object["stats"] == nil,
                  (object["result"] as? [String: Any])?["stats"] == nil else {
                throw decodeError
            }
            if let newSessionID = message.sessionID?.trimmedNonEmpty, newSessionID != sessionID {
                sessionID = newSessionID
                currentModel = nil
            }
            if let model = normalizedModelID(message.model) { currentModel = model }
            if message.tokens != nil {
                try collect(
                    message, sessionID: sessionID, modelHint: currentModel, file: file, index: index,
                    records: &records, recordCount: &recordCount)
            } else if !["init", "user", "gemini", "info", "error", "warning"].contains(message.type ?? ""),
                      message.sessionID?.trimmedNonEmpty == nil {
                throw decodeError
            }
        }
    }

    func collect(
        _ message: GeminiMessage, sessionID: String?, modelHint: String?, file: URL, index: Int,
        records: inout [GeminiMessageIdentity: GeminiUsageRecord], recordCount: inout Int) throws {
        try Task.checkCancellation()
        guard let tokens = message.tokens else { return }
        guard tokens.isSupported, let timestamp = message.timestamp,
              let date = DateParser.parse(timestamp) else { throw decodeError }
        try recordUsageEvents(1, total: &recordCount, maximum: readLimits.maximumUnreconciledEventCount)
        let id = sessionID?.trimmedNonEmpty
        let sessionKey = id.map { "session:\($0)" } ?? "file:\(file.path)"
        let identity = message.id?.trimmedNonEmpty.map { GeminiMessageIdentity.message(session: sessionKey, id: $0) }
            ?? .line(file: file.path, index: index)
        let record = GeminiUsageRecord(
            file: file, index: index, sessionKey: sessionKey,
            sessionID: id ?? usageSessionID(fromPath: file.path), date: date,
            model: normalizedModelID(message.model) ?? modelHint, tokens: tokens)
        if let previous = records[identity], !record.isPreferred(over: previous) { return }
        records[identity] = record
    }

    func accumulateLegacy(
        data: Data, file: URL, from startDate: Date, to endDate: Date,
        result: inout RawTokenUsage, activityEvents: inout [ActivityTimeEvent<String>],
        recordCount: inout Int) throws {
        let decoder = JSONDecoder()
        let messages: [LegacyGeminiMessage]
        if let array = try? decoder.decode([LegacyGeminiMessage].self, from: data) {
            messages = array
        } else if let single = try? decoder.decode(LegacyGeminiMessage.self, from: data) {
            messages = [single]
        } else {
            throw decodeError
        }
        guard messages.contains(where: { $0.usageMetadata != nil }) else {
            let value = try? JSONSerialization.jsonObject(with: data)
            let objects = (value as? [[String: Any]]) ?? (value as? [String: Any]).map { [$0] }
            if let objects, objects.allSatisfy({ object in
                ["user", "model", "assistant"].contains(object["role"] as? String ?? "")
                    && !["messages", "stats", "result", "tokens"].contains(where: { object[$0] != nil })
            }) {
                // Empty arrays and recognized unmetered legacy turns are valid chats.
                return
            }
            // The tmp tree also contains unrelated JSON metadata. Only recording-shaped
            // locations/objects should diagnose an unsupported usage schema.
            let object = value as? [String: Any]
            if file.deletingLastPathComponent().lastPathComponent == "chats"
                || file.lastPathComponent.hasPrefix("session-")
                || ["messages", "stats", "result", "tokens", "usageMetadata"].contains(where: { object?[$0] != nil }) {
                throw decodeError
            }
            return
        }
        let fileDate = try file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
        // Legacy JSON carries no event date/model; retain its existing file-mtime contract.
        guard let fileDate, fileDate >= startDate, fileDate < endDate else { return }
        for message in messages {
            try Task.checkCancellation()
            guard let meta = message.usageMetadata else { continue }
            try recordUsageEvents(1, total: &recordCount, maximum: readLimits.maximumUnreconciledEventCount)
            let input = meta.promptTokenCount ?? 0
            let output = meta.candidatesTokenCount ?? 0
            let cached = meta.cachedContentTokenCount ?? 0
            guard let total = result.accumulateTokenCounts(input: input, output: output, cacheRead: cached) else {
                throw decodeError
            }
            result.accumulatePerModelUsage(model: nil, source: name, totalTokens: total)
            result.recordTokenEvent(
                timestamp: fileDate, source: name, model: nil,
                inputTokens: input, outputTokens: output, cacheReadTokens: cached,
                attribution: UsageAttribution(sessionID: usageSessionID(fromPath: file.path), quality: .unknown))
        }
        if !messages.isEmpty {
            activityEvents.append(ActivityTimeEvent(
                streamID: file.path, timestamp: fileDate, key: UsageModelGrouping.groupingKey(for: nil)))
        }
    }
}

private enum GeminiMessageIdentity: Hashable {
    case message(session: String, id: String)
    case line(file: String, index: Int)
}

private struct GeminiUsageRecord {
    let file: URL
    let index: Int
    let sessionKey: String
    let sessionID: String
    let date: Date
    let model: String?
    let tokens: GeminiMessage.Tokens

    func isPreferred(over other: Self) -> Bool {
        if file == other.file { return index > other.index }
        if date != other.date { return date > other.date }
        // Current append-only recordings win ties with their JSON migration copy.
        if file.pathExtension != other.file.pathExtension { return file.pathExtension == "jsonl" }
        return file.path < other.file.path
    }

    static func isOrdered(_ lhs: Self, _ rhs: Self) -> Bool {
        if lhs.date != rhs.date { return lhs.date < rhs.date }
        if lhs.file != rhs.file { return lhs.file.path < rhs.file.path }
        return lhs.index < rhs.index
    }
}

private struct LegacyGeminiMessage: Decodable {
    let usageMetadata: UsageMetadata?

    struct UsageMetadata: Decodable {
        let promptTokenCount: Int?
        let candidatesTokenCount: Int?
        let totalTokenCount: Int?
        let cachedContentTokenCount: Int?
    }
}

private struct GeminiSession: Decodable {
    let sessionId: String?
    let sessionIdSnake: String?
    let messages: [GeminiMessage]

    var sessionID: String? {
        sessionId ?? sessionIdSnake
    }

    enum CodingKeys: String, CodingKey {
        case sessionId, messages
        case sessionIdSnake = "session_id"
    }
}

private struct GeminiMessage: Decodable {
    let id: String?
    let sessionId: String?
    let sessionIdSnake: String?
    let timestamp: String?
    let type: String?
    let tokens: Tokens?
    let model: String?

    var sessionID: String? {
        sessionId ?? sessionIdSnake
    }

    enum CodingKeys: String, CodingKey {
        case id, sessionId, timestamp, type, tokens, model
        case sessionIdSnake = "session_id"
    }

    struct Tokens: Decodable {
        let input: Int?
        let output: Int?
        let cached: Int?
        let thoughts: Int?
        let tool: Int?
        let total: Int?

        init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()
            let counts = try container.decode([String: Int?].self)
            let supported = Set(["input", "output", "cached", "thoughts", "tool", "total"])
            guard Set(counts.keys).isSubset(of: supported) else {
                throw DecodingError.dataCorruptedError(
                    in: container, debugDescription: "Unsupported Gemini token fields")
            }
            input = counts["input"] ?? nil
            output = counts["output"] ?? nil
            cached = counts["cached"] ?? nil
            thoughts = counts["thoughts"] ?? nil
            tool = counts["tool"] ?? nil
            total = counts["total"] ?? nil
        }

        var isSupported: Bool {
            let values = [input, output, cached, thoughts, tool].compactMap { $0 }
            return !values.isEmpty && values.allSatisfy { $0 >= 0 && boundedUsageTokenCount($0) == $0 }
        }
    }
}
