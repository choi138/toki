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
            let configuration = kimiCLIConfiguration(at: root.deletingLastPathComponent())
            return kimiWireFiles(in: root).map { file in
                KimiCLISession(
                    streamID: file.path,
                    lines: readJSONLLines(at: file),
                    model: configuration?.model,
                    provider: configuration?.provider,
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
                    provider: nil,
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
            var fallbackOccurrences: [String: Int] = [:]
            for line in session.lines {
                guard let data = line.data(using: .utf8),
                      let wire = try? decoder.decode(KimiCLIWireLine.self, from: data),
                      wire.message?.type == "StatusUpdate",
                      let payload = wire.message?.payload,
                      let tokens = payload.tokenUsage?.counts,
                      let totalTokens = tokens.total,
                      totalTokens > 0,
                      let timestamp = kimiCLITimestamp(wire.timestamp) ?? session.fallbackDate,
                      timestamp >= startDate,
                      timestamp < endDate else {
                    continue
                }

                let model = normalizedModelID(session.model) ?? "kimi-for-coding"
                let messageKey: String
                if let messageID = nonemptyKimiValue(payload.messageID) {
                    messageKey = "message:\(messageID)"
                } else {
                    let contentIdentity = [
                        String(timestamp.timeIntervalSince1970.bitPattern),
                        "\(model.utf8.count):\(model)",
                        String(tokens.input),
                        String(tokens.output),
                        String(tokens.cacheRead),
                        String(tokens.cacheWrite),
                    ].joined(separator: "|")
                    let occurrence = fallbackOccurrences[contentIdentity, default: 0]
                    fallbackOccurrences[contentIdentity] = occurrence + 1
                    messageKey = "content:\(contentIdentity)|occurrence:\(occurrence)"
                }
                let event = KimiUsageEvent(
                    timestamp: timestamp,
                    model: model,
                    sessionID: identity.sessionID,
                    projectName: identity.workspace,
                    streamID: identity.sessionID,
                    tokens: tokens,
                    totalTokens: totalTokens,
                    provider: session.provider,
                    dedupKey: "\(identity.dedupScope):\(messageKey)")
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
            var contentOccurrences: [String: Int] = [:]

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
                      let totalTokens = tokens.total,
                      totalTokens > 0,
                      let timestamp = kimiCodeTimestamp(wire.time) ?? session.fallbackDate,
                      timestamp >= startDate,
                      timestamp < endDate else {
                    continue
                }

                let model = concreteKimiCodeModel(wire.model)
                    ?? latestConcreteModel
                    ?? "kimi-for-coding"
                let contentIdentity = [
                    "\(identity.workspace?.utf8.count ?? 0):\(identity.workspace ?? "")",
                    "\(identity.sessionID.utf8.count):\(identity.sessionID)",
                    "\(identity.agent.utf8.count):\(identity.agent)",
                    String(timestamp.timeIntervalSince1970.bitPattern),
                    "\(model.utf8.count):\(model)",
                    String(tokens.input),
                    String(tokens.output),
                    String(tokens.cacheRead),
                    String(tokens.cacheWrite),
                ].joined(separator: "|")
                let occurrence = contentOccurrences[contentIdentity, default: 0]
                contentOccurrences[contentIdentity] = occurrence + 1
                let key = "\(contentIdentity)|occurrence:\(occurrence)"
                eventsByKey[key] = KimiUsageEvent(
                    timestamp: timestamp,
                    model: model,
                    sessionID: identity.sessionID,
                    projectName: identity.workspace,
                    streamID: "\(identity.sessionID):\(identity.agent)",
                    tokens: tokens,
                    totalTokens: totalTokens,
                    provider: nil,
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
    let provider: String?
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

    var total: Int? {
        checkedTokenTotal(input, output, cacheRead, cacheWrite)
    }
}

private struct KimiUsageEvent {
    let timestamp: Date
    let model: String
    let sessionID: String
    let projectName: String?
    let streamID: String
    let tokens: KimiTokenCounts
    let totalTokens: Int
    let provider: String?
    let dedupKey: String

    func shouldReplace(_ existing: KimiUsageEvent) -> Bool {
        totalTokens > existing.totalTokens
            || (totalTokens == existing.totalTokens && timestamp > existing.timestamp)
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
            provider: event.provider ?? inferredUsageProvider(from: event.model),
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

private func kimiWireFiles(in root: URL) -> [URL] {
    findFiles(in: root, withExtension: "jsonl")
        .filter { $0.lastPathComponent == "wire.jsonl" }
        .reduce(into: [String: URL]()) { files, file in
            files[file.resolvingSymlinksInPath().standardizedFileURL.path] = file
        }
        .values
        .sorted { $0.path < $1.path }
}

private func kimiCLIConfiguration(at root: URL) -> KimiCLIResolvedConfiguration? {
    let tomlURL = root.appendingPathComponent("config.toml")
    if let contents = try? String(contentsOf: tomlURL, encoding: .utf8),
       let configuration = kimiCLITOMLConfiguration(contents) {
        return configuration
    }

    let jsonURL = root.appendingPathComponent("config.json")
    guard let data = try? Data(contentsOf: jsonURL),
          let config = try? JSONDecoder().decode(KimiCLIConfig.self, from: data) else {
        return nil
    }
    let defaultModel = normalizedModelID(config.defaultModel) ?? normalizedModelID(config.model)
    guard let defaultModel else { return nil }
    let selectedModel = config.models?[defaultModel]
    return KimiCLIResolvedConfiguration(
        model: normalizedModelID(selectedModel?.model) ?? defaultModel,
        provider: normalizedModelID(selectedModel?.provider))
}

private struct KimiCLIConfig: Decodable {
    let model: String?
    let defaultModel: String?
    let models: [String: KimiCLIModelConfiguration]?

    enum CodingKeys: String, CodingKey {
        case model, models
        case defaultModel = "default_model"
    }
}

private struct KimiCLIModelConfiguration: Decodable {
    let provider: String?
    let model: String?
}

private struct KimiCLIResolvedConfiguration {
    let model: String
    let provider: String?
}

private func kimiCLITOMLConfiguration(_ contents: String) -> KimiCLIResolvedConfiguration? {
    var section: String?
    var defaultModel: String?
    var models: [String: [String: String]] = [:]

    for rawLine in contents.components(separatedBy: .newlines) {
        let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !line.isEmpty, !line.hasPrefix("#") else { continue }

        if line.hasPrefix("["), line.hasSuffix("]") {
            section = String(line.dropFirst().dropLast())
            continue
        }

        guard let separator = line.firstIndex(of: "="),
              let value = kimiTOMLStringValue(String(line[line.index(after: separator)...])) else {
            continue
        }
        let key = line[..<separator].trimmingCharacters(in: .whitespacesAndNewlines)
        if section == nil, key == "default_model" {
            defaultModel = normalizedModelID(value)
            continue
        }
        guard let section,
              section.hasPrefix("models."),
              key == "model" || key == "provider" else {
            continue
        }
        let modelName = String(section.dropFirst("models.".count))
        models[modelName, default: [:]][key] = value
    }

    guard let defaultModel else { return nil }
    return KimiCLIResolvedConfiguration(
        model: normalizedModelID(models[defaultModel]?["model"]) ?? defaultModel,
        provider: normalizedModelID(models[defaultModel]?["provider"]))
}

private func kimiTOMLStringValue(_ rawValue: String) -> String? {
    let value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
    guard let quote = value.first, quote == "\"" || quote == "'" else { return nil }

    var escaped = false
    for index in value.indices.dropFirst() {
        let character = value[index]
        if quote == "\"", character == "\\", !escaped {
            escaped = true
            continue
        }
        if character == quote, !escaped {
            let content = String(value[value.index(after: value.startIndex)..<index])
            if quote == "\"" {
                let data = Data("\"\(content)\"".utf8)
                if let decoded = try? JSONDecoder().decode(String.self, from: data) {
                    return decoded
                }
            }
            return content
        }
        escaped = false
    }
    return nil
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
