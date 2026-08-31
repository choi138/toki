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
            let model = kimiCLIModel(at: root.deletingLastPathComponent())
            return kimiWireFiles(in: root).map { file in
                KimiCLISession(
                    streamID: file.path,
                    lines: readJSONLLines(at: file),
                    model: model,
                    fallbackDate: fileModificationDate(file))
            }
        }
        return Self.usage(from: sessions, from: startDate, to: endDate)
    }

    static func usage(
        fromJSONLLines lines: [String],
        streamID: String,
        model: String?,
        from startDate: Date,
        to endDate: Date) -> RawTokenUsage {
        usage(
            from: [
                KimiCLISession(
                    streamID: streamID,
                    lines: lines,
                    model: model,
                    fallbackDate: nil),
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
            let model = normalizedModelID(session.model) ?? "kimi-for-coding"
            let namespace = [identity.workspace, identity.sessionID]
                .compactMap { $0 }
                .joined(separator: ":")
            var fingerprintOccurrences: [String: Int] = [:]
            for line in session.lines {
                guard let data = line.data(using: .utf8),
                      let wire = try? decoder.decode(KimiCLIWireLine.self, from: data),
                      wire.message?.type == "StatusUpdate",
                      let payload = wire.message?.payload,
                      let tokens = payload.tokenUsage?.counts,
                      tokens.total > 0,
                      let timestamp = kimiCLITimestamp(wire.timestamp) ?? session.fallbackDate,
                      timestamp >= startDate,
                      timestamp < endDate else {
                    continue
                }

                let messageKey: String
                if let messageID = nonemptyKimiValue(payload.messageID) {
                    messageKey = "message:\(messageID)"
                } else {
                    let fingerprint = kimiCodeEventFingerprint(
                        timestamp: timestamp,
                        model: model,
                        tokens: tokens)
                    let occurrence = fingerprintOccurrences[fingerprint, default: 0]
                    fingerprintOccurrences[fingerprint] = occurrence + 1
                    messageKey = "content:\(fingerprint):\(occurrence)"
                }
                let event = KimiUsageEvent(
                    timestamp: timestamp,
                    model: model,
                    sessionID: identity.sessionID,
                    projectName: identity.workspace,
                    streamID: namespace,
                    tokens: tokens,
                    dedupKey: "\(namespace):\(messageKey)")
                if let existing = snapshots[event.dedupKey],
                   !event.shouldReplace(existing) {
                    continue
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
                    lines: readJSONLLines(at: file),
                    fallbackDate: fileModificationDate(file))
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
                    lines: lines,
                    fallbackDate: nil),
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
            var fingerprintOccurrences: [String: Int] = [:]

            for line in session.lines {
                guard let data = line.data(using: .utf8),
                      let wire = try? decoder.decode(KimiCodeWireLine.self, from: data) else {
                    continue
                }

                if wire.type == "llm.request" {
                    latestConcreteModel = concreteKimiCodeModel(wire.model) ?? latestConcreteModel
                    continue
                }

                guard wire.type == "usage.record",
                      wire.usageScope == "turn",
                      let tokens = wire.usage?.counts,
                      tokens.total > 0,
                      let timestamp = kimiCodeTimestamp(wire.time) ?? session.fallbackDate,
                      timestamp >= startDate,
                      timestamp < endDate else {
                    continue
                }

                let model = concreteKimiCodeModel(wire.model)
                    ?? latestConcreteModel
                    ?? "kimi-for-coding"
                let fingerprint = kimiCodeEventFingerprint(
                    timestamp: timestamp,
                    model: model,
                    tokens: tokens)
                let occurrence = fingerprintOccurrences[fingerprint, default: 0]
                fingerprintOccurrences[fingerprint] = occurrence + 1
                let namespace = [identity.workspace, identity.sessionID, identity.agent]
                    .compactMap { $0 }
                    .joined(separator: ":")
                let key = "\(namespace):\(fingerprint):\(occurrence)"
                eventsByKey[key] = KimiUsageEvent(
                    timestamp: timestamp,
                    model: model,
                    sessionID: identity.sessionID,
                    projectName: identity.workspace,
                    streamID: namespace,
                    tokens: tokens,
                    dedupKey: key)
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
    let lines: [String]
    let model: String?
    let fallbackDate: Date?
}

private struct KimiCodeSession {
    let streamID: String
    let lines: [String]
    let fallbackDate: Date?
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

    var total: Int {
        checkedTokenTotal(input, output, cacheRead, cacheWrite) ?? 0
    }
}

private struct KimiUsageEvent {
    let timestamp: Date
    let model: String
    let sessionID: String
    let projectName: String?
    let streamID: String
    let tokens: KimiTokenCounts
    let dedupKey: String

    func shouldReplace(_ existing: KimiUsageEvent) -> Bool {
        tokens.total > existing.tokens.total
            || (tokens.total == existing.tokens.total && timestamp > existing.timestamp)
    }
}

private func kimiRawUsage(
    events: [KimiUsageEvent],
    source: String,
    clippingEndDate: Date) -> RawTokenUsage {
    var result = RawTokenUsage()
    var activityEvents: [ActivityTimeEvent<String>] = []

    for event in events {
        guard let totalTokens = result.accumulateTokenCounts(
            input: event.tokens.input,
            output: event.tokens.output,
            cacheRead: event.tokens.cacheRead,
            cacheWrite: event.tokens.cacheWrite) else {
            continue
        }
        result.accumulatePerModelUsage(
            model: event.model,
            source: source,
            totalTokens: totalTokens)
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

private func kimiCodeEventFingerprint(
    timestamp: Date,
    model: String,
    tokens: KimiTokenCounts) -> String {
    [
        String(timestamp.timeIntervalSince1970),
        model,
        String(tokens.input),
        String(tokens.output),
        String(tokens.cacheRead),
        String(tokens.cacheWrite),
    ].joined(separator: ":")
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

private func kimiCLIModel(at root: URL) -> String? {
    let configURL = root.appendingPathComponent("config.json")
    guard let data = try? Data(contentsOf: configURL),
          let config = try? JSONDecoder().decode(KimiCLIConfig.self, from: data) else {
        return nil
    }
    return normalizedModelID(config.model)
}

private struct KimiCLIConfig: Decodable {
    let model: String?
}

private struct KimiCLIIdentity {
    let workspace: String?
    let sessionID: String
}

private func kimiCLIIdentity(from path: String) -> KimiCLIIdentity {
    let session = URL(fileURLWithPath: path).deletingLastPathComponent()
    let workspace = session.deletingLastPathComponent()
    return KimiCLIIdentity(
        workspace: nonemptyKimiValue(workspace.lastPathComponent),
        sessionID: nonemptyKimiValue(session.lastPathComponent) ?? usageSessionID(fromPath: path))
}

private struct KimiCodeIdentity {
    let workspace: String?
    let sessionID: String
    let agent: String
}

private func kimiCodeIdentity(from path: String) -> KimiCodeIdentity {
    let agent = URL(fileURLWithPath: path).deletingLastPathComponent()
    let session = agent.deletingLastPathComponent().deletingLastPathComponent()
    let workspace = session.deletingLastPathComponent()
    return KimiCodeIdentity(
        workspace: nonemptyKimiValue(workspace.lastPathComponent),
        sessionID: nonemptyKimiValue(session.lastPathComponent) ?? usageSessionID(fromPath: path),
        agent: nonemptyKimiValue(agent.lastPathComponent) ?? "main")
}

private func concreteKimiCodeModel(_ value: String?) -> String? {
    guard let model = nonemptyKimiValue(value),
          !(model.hasPrefix("__") && model.hasSuffix("__")) else {
        return nil
    }
    return model
}

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

private func fileModificationDate(_ url: URL) -> Date? {
    (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
}

private func nonemptyKimiValue(_ value: String?) -> String? {
    guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines),
          !value.isEmpty else {
        return nil
    }
    return value
}
