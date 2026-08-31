import Foundation
import TokiUsageCore

public struct KimiCLIReader: TokenReader {
    public static let sourceName = "Kimi CLI"

    public let name = Self.sourceName
    private let sessionRoots: [URL]

    public init(sessionRoots: [URL]? = nil) {
        self.sessionRoots = sessionRoots ?? LocalUsageReaderPaths().kimiCLISessions
    }

    public func readUsage(from startDate: Date, to endDate: Date) async throws -> RawTokenUsage {
        let sessions = sessionRoots.flatMap { root in
            kimiWireFiles(in: root).map { file in
                KimiCLISession(
                    streamID: file.path,
                    lineSource: .file(file))
            }
        }
        return Self.usage(from: sessions, from: startDate, to: endDate)
    }

    static func usage(
        fromJSONLLines lines: [String],
        streamID: String,
        from startDate: Date,
        to endDate: Date) -> RawTokenUsage {
        usage(
            from: [
                KimiCLISession(
                    streamID: streamID,
                    lineSource: .lines(lines)),
            ],
            from: startDate,
            to: endDate)
    }

    private static func usage(
        from sessions: [KimiCLISession],
        from startDate: Date,
        to endDate: Date) -> RawTokenUsage {
        let decoder = JSONDecoder()
        var snapshots: [String: KimiUsageEvent] = [:]

        for session in sessions {
            let identity = kimiCLIIdentity(from: session.streamID)
            session.lineSource.consume { line in
                guard let data = line.data(using: .utf8),
                      let wire = try? decoder.decode(KimiCLIWireLine.self, from: data),
                      wire.message?.type == "StatusUpdate",
                      let payload = wire.message?.payload,
                      let tokens = payload.tokenUsage?.counts,
                      let totalTokens = tokens.total,
                      totalTokens > 0,
                      let timestamp = kimiCLITimestamp(wire.timestamp),
                      timestamp >= startDate,
                      timestamp < endDate else {
                    return
                }

                let messageKey = if let messageID = nonemptyKimiValue(payload.messageID) {
                    "message:\(messageID)"
                } else {
                    "stream"
                }
                let event = KimiUsageEvent(
                    timestamp: timestamp,
                    model: kimiFallbackModel,
                    modelIsConcrete: false,
                    sessionID: identity.dedupScope,
                    sessionLabel: identity.sessionID,
                    projectName: identity.workspace,
                    streamID: identity.dedupScope,
                    tokens: tokens,
                    totalTokens: totalTokens,
                    dedupKey: "\(identity.dedupScope):\(messageKey)")
                if let existing = snapshots[event.dedupKey],
                   !event.shouldReplace(existing) {
                    return
                }
                snapshots[event.dedupKey] = event
            }
        }

        return kimiRawUsage(
            events: snapshots.values.sorted(by: kimiEventSort),
            source: sourceName,
            clippingEndDate: endDate)
    }
}

public struct KimiCodeReader: TokenReader {
    public static let sourceName = "Kimi Code"

    public let name = Self.sourceName
    private let sessionRoots: [URL]

    public init(sessionRoots: [URL]? = nil) {
        self.sessionRoots = sessionRoots ?? LocalUsageReaderPaths().kimiCodeSessions
    }

    public func readUsage(from startDate: Date, to endDate: Date) async throws -> RawTokenUsage {
        let sessions = sessionRoots.flatMap { root in
            kimiWireFiles(in: root).map { file in
                KimiCodeSession(
                    streamID: file.path,
                    lineSource: .file(file))
            }
        }
        return Self.usage(from: sessions, from: startDate, to: endDate)
    }

    static func usage(
        fromJSONLLines lines: [String],
        streamID: String,
        from startDate: Date,
        to endDate: Date) -> RawTokenUsage {
        usage(
            from: [
                KimiCodeSession(
                    streamID: streamID,
                    lineSource: .lines(lines)),
            ],
            from: startDate,
            to: endDate)
    }

    private static func usage(
        from sessions: [KimiCodeSession],
        from startDate: Date,
        to endDate: Date) -> RawTokenUsage {
        let decoder = JSONDecoder()
        var eventsByKey: [String: KimiUsageEvent] = [:]

        for session in sessions {
            let identity = kimiCodeIdentity(from: session.streamID)
            var latestConcreteModel: String?
            var contentOccurrences: [String: Int] = [:]

            session.lineSource.consume { line in
                guard let data = line.data(using: .utf8),
                      let wire = try? decoder.decode(KimiCodeWireLine.self, from: data) else {
                    return
                }

                if wire.type == "llm.request" {
                    latestConcreteModel = concreteKimiCodeModel(wire.model) ?? latestConcreteModel
                    return
                }

                guard wire.type == "usage.record",
                      wire.usageScope == "turn",
                      let tokens = wire.usage?.counts,
                      let totalTokens = tokens.total,
                      totalTokens > 0,
                      let timestamp = kimiCodeTimestamp(wire.time),
                      timestamp >= startDate,
                      timestamp < endDate else {
                    return
                }

                let recordedModel = nonemptyKimiValue(wire.model)
                let concreteModel = concreteKimiCodeModel(recordedModel) ?? latestConcreteModel
                let model = concreteModel ?? kimiFallbackModel
                let contentIdentity = [
                    "\(identity.workspace?.utf8.count ?? 0):\(identity.workspace ?? "")",
                    "\(identity.sessionID.utf8.count):\(identity.sessionID)",
                    "\(identity.agent.utf8.count):\(identity.agent)",
                    String(timestamp.timeIntervalSince1970.bitPattern),
                    "\(recordedModel?.utf8.count ?? 0):\(recordedModel ?? "")",
                    String(tokens.input),
                    String(tokens.output),
                    String(tokens.cacheRead),
                    String(tokens.cacheWrite),
                ].joined(separator: "|")
                let occurrence = contentOccurrences[contentIdentity, default: 0]
                contentOccurrences[contentIdentity] = occurrence + 1
                let key = "\(contentIdentity)|occurrence:\(occurrence)"
                let event = KimiUsageEvent(
                    timestamp: timestamp,
                    model: model,
                    modelIsConcrete: concreteModel != nil,
                    sessionID: identity.sessionScope,
                    sessionLabel: identity.sessionID,
                    projectName: identity.workspace,
                    streamID: identity.streamID,
                    tokens: tokens,
                    totalTokens: totalTokens,
                    dedupKey: key)
                if let existing = eventsByKey[key], !event.shouldReplace(existing) {
                    return
                }
                eventsByKey[key] = event
            }
        }

        return kimiRawUsage(
            events: eventsByKey.values.sorted(by: kimiEventSort),
            source: sourceName,
            clippingEndDate: endDate)
    }
}

private struct KimiCLISession {
    let streamID: String
    let lineSource: JSONLLineSource
}

private struct KimiCodeSession {
    let streamID: String
    let lineSource: JSONLLineSource
}

private struct KimiCLIWireLine: Decodable {
    let timestamp: Double?
    let message: Message?

    struct Message: Decodable {
        let type: String?
        let payload: Payload?
    }

    struct Payload: Decodable {
        let tokenUsage: KimiTokenUsage?
        let messageID: String?

        enum CodingKeys: String, CodingKey {
            case tokenUsage = "token_usage"
            case messageID = "message_id"
        }
    }
}

private struct KimiCodeWireLine: Decodable {
    let type: String?
    let model: String?
    let usage: KimiTokenUsage?
    let usageScope: String?
    let time: Int64?
}

private struct KimiTokenUsage: Decodable {
    let inputOther: Int?
    let output: Int?
    let inputCacheRead: Int?
    let inputCacheCreation: Int?

    var counts: KimiTokenCounts {
        KimiTokenCounts(
            input: max(0, inputOther ?? 0),
            output: max(0, output ?? 0),
            cacheRead: max(0, inputCacheRead ?? 0),
            cacheWrite: max(0, inputCacheCreation ?? 0))
    }

    private enum CodingKeys: String, CodingKey {
        case inputOther
        case output
        case inputCacheRead
        case inputCacheCreation
        case inputOtherSnake = "input_other"
        case inputCacheReadSnake = "input_cache_read"
        case inputCacheCreationSnake = "input_cache_creation"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        inputOther = try container.decodeIfPresent(Int.self, forKey: .inputOther)
            ?? container.decodeIfPresent(Int.self, forKey: .inputOtherSnake)
        output = try container.decodeIfPresent(Int.self, forKey: .output)
        inputCacheRead = try container.decodeIfPresent(Int.self, forKey: .inputCacheRead)
            ?? container.decodeIfPresent(Int.self, forKey: .inputCacheReadSnake)
        inputCacheCreation = try container.decodeIfPresent(Int.self, forKey: .inputCacheCreation)
            ?? container.decodeIfPresent(Int.self, forKey: .inputCacheCreationSnake)
    }
}

private struct KimiTokenCounts {
    let input: Int
    let output: Int
    let cacheRead: Int
    let cacheWrite: Int

    var total: Int? {
        checkedTokenTotal(input, output, cacheRead, cacheWrite)
    }
}

private struct KimiUsageEvent {
    let timestamp: Date
    let model: String
    let modelIsConcrete: Bool
    let sessionID: String
    let sessionLabel: String
    let projectName: String?
    let streamID: String
    let tokens: KimiTokenCounts
    let totalTokens: Int
    let dedupKey: String

    func shouldReplace(_ existing: KimiUsageEvent) -> Bool {
        if totalTokens != existing.totalTokens {
            return totalTokens > existing.totalTokens
        }
        if timestamp != existing.timestamp {
            return timestamp > existing.timestamp
        }
        if modelIsConcrete != existing.modelIsConcrete {
            return modelIsConcrete
        }
        return model > existing.model
    }
}

private func kimiRawUsage(
    events: [KimiUsageEvent],
    source: String,
    clippingEndDate: Date) -> RawTokenUsage {
    var result = RawTokenUsage()
    var activityEvents: [ActivityTimeEvent<String>] = []

    for event in events {
        guard let accumulatedTotal = checkedTokenTotal(
            result.inputTokens,
            result.outputTokens,
            result.cacheReadTokens,
            result.cacheWriteTokens,
            result.reasoningTokens,
            result.unclassifiedTokens),
            checkedTokenTotal(accumulatedTotal, event.totalTokens) != nil else {
            continue
        }
        result.inputTokens += event.tokens.input
        result.outputTokens += event.tokens.output
        result.cacheReadTokens += event.tokens.cacheRead
        result.cacheWriteTokens += event.tokens.cacheWrite
        result.accumulatePerModelUsage(
            model: event.model,
            source: source,
            totalTokens: event.totalTokens)
        result.recordTokenEvent(
            timestamp: event.timestamp,
            source: source,
            model: event.model,
            provider: inferredUsageProvider(from: event.model),
            inputTokens: event.tokens.input,
            outputTokens: event.tokens.output,
            cacheReadTokens: event.tokens.cacheRead,
            cacheWriteTokens: event.tokens.cacheWrite,
            costIsKnown: false,
            attribution: UsageAttribution(
                projectName: event.projectName,
                sessionID: event.sessionID,
                sessionLabel: event.sessionLabel,
                quality: event.projectName == nil ? .unknown : .inferred))
        activityEvents.append(
            ActivityTimeEvent(
                streamID: event.streamID,
                timestamp: event.timestamp,
                key: event.model))
    }

    result.mergeActivityEvents(
        activityEvents,
        source: source,
        clippingEndDate: clippingEndDate)
    return result
}

private func kimiWireFiles(in root: URL) -> [URL] {
    findFiles(in: root, withExtension: "jsonl")
        .filter { $0.lastPathComponent == "wire.jsonl" }
        .reduce(into: [String: URL]()) { files, file in
            files[file.resolvingSymlinksInPath().standardizedFileURL.path] = file
        }
        .values
        .sorted { $0.path < $1.path }
}

private struct KimiCLIIdentity {
    let workspace: String?
    let sessionID: String
    let dedupScope: String
}

private func kimiCLIIdentity(from path: String) -> KimiCLIIdentity {
    let session = URL(fileURLWithPath: path).deletingLastPathComponent()
    let workspace = nonemptyKimiValue(session.deletingLastPathComponent().lastPathComponent)
    let sessionID = nonemptyKimiValue(session.lastPathComponent) ?? usageSessionID(fromPath: path)
    return KimiCLIIdentity(
        workspace: workspace,
        sessionID: sessionID,
        dedupScope: "\(workspace?.utf8.count ?? 0):\(workspace ?? "")|\(sessionID.utf8.count):\(sessionID)")
}

private struct KimiCodeIdentity {
    let workspace: String?
    let sessionID: String
    let sessionScope: String
    let agent: String
    let streamID: String
}

private func kimiCodeIdentity(from path: String) -> KimiCodeIdentity {
    let agent = URL(fileURLWithPath: path).deletingLastPathComponent()
    let session = agent.deletingLastPathComponent().deletingLastPathComponent()
    let workspace = session.deletingLastPathComponent()
    let workspaceName = nonemptyKimiValue(workspace.lastPathComponent)
    let sessionID = nonemptyKimiValue(session.lastPathComponent) ?? usageSessionID(fromPath: path)
    let agentName = nonemptyKimiValue(agent.lastPathComponent) ?? "main"
    let sessionScope = [
        "\(workspaceName?.utf8.count ?? 0):\(workspaceName ?? "")",
        "\(sessionID.utf8.count):\(sessionID)",
    ].joined(separator: "|")
    return KimiCodeIdentity(
        workspace: workspaceName,
        sessionID: sessionID,
        sessionScope: sessionScope,
        agent: agentName,
        streamID: [
            sessionScope,
            "\(agentName.utf8.count):\(agentName)",
        ].joined(separator: "|"))
}

private func concreteKimiCodeModel(_ value: String?) -> String? {
    guard let model = nonemptyKimiValue(value),
          !(model.hasPrefix("__") && model.hasSuffix("__")) else {
        return nil
    }
    return model
}

private let kimiFallbackModel = "kimi-for-coding"

private func kimiCLITimestamp(_ value: Double?) -> Date? {
    guard let value, value.isFinite, value > 0 else { return nil }
    return Date(timeIntervalSince1970: value)
}

private func kimiCodeTimestamp(_ value: Int64?) -> Date? {
    guard let value, value > 0 else { return nil }
    return Date(timeIntervalSince1970: Double(value) / 1000)
}

private func kimiEventSort(_ lhs: KimiUsageEvent, _ rhs: KimiUsageEvent) -> Bool {
    if lhs.timestamp != rhs.timestamp { return lhs.timestamp < rhs.timestamp }
    return lhs.dedupKey < rhs.dedupKey
}

private func nonemptyKimiValue(_ value: String?) -> String? {
    guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines),
          !value.isEmpty else {
        return nil
    }
    return value
}
