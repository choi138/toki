import CoreFoundation
import Foundation
import TokiUsageCore

struct OpenCodeMessageIdentity: Hashable {
    let session: String
    let message: String
}

struct OpenCodeMessage {
    let messageID: String?
    let sessionID: String
    let originID: String
    var namespace: String
    let timestamp: Date
    let model: String?
    let provider: String?
    let input: Int
    let output: Int
    let reasoning: Int
    let cacheRead: Int
    let cacheWrite: Int
    let cost: Double
    let costIsKnown: Bool
    let projectPath: String?
    let sessionLabel: String?

    var identity: OpenCodeMessageIdentity {
        OpenCodeMessageIdentity(
            session: sessionID,
            message: messageID.map { "id:\($0)" } ?? "origin:\(originID)")
    }

    var migrationIdentity: OpenCodeMessageIdentity? {
        messageID.map { OpenCodeMessageIdentity(session: sessionID, message: "id:\($0)") }
    }

    var streamID: String {
        "\(namespace):session:\(openCodeIdentityComponent(sessionID))"
    }

    struct Context {
        let namespace: String
        let originID: String
        var rowID: String?
        var sessionID: String?
        var fallbackSessionID: String?
        var timestampMilliseconds: Double?
        var assistantType = false
        var projectPath: String?
        var sessionLabel: String?
    }

    static func parse(_ data: Data, context: Context) -> OpenCodeMessage? {
        guard let payload = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return nil }
        return parse(payload, context: context)
    }

    static func parse(_ payload: [String: Any], context: Context) -> OpenCodeMessage? {
        let role = payload["role"] as? String
        guard role == "assistant" || (context.assistantType && payload["role"] == nil),
              let tokens = payload["tokens"] as? [String: Any] else { return nil }
        if let cache = tokens["cache"], !(cache is NSNull), !(cache is [String: Any]) { return nil }
        let cache = tokens["cache"] as? [String: Any] ?? [:]
        guard let input = count(tokens["input"]), let output = count(tokens["output"]),
              let reasoning = count(tokens["reasoning"]), let cacheRead = count(cache["read"]),
              let cacheWrite = count(cache["write"]) else { return nil }
        let milliseconds: Double?
        if let rawTime = payload["time"], !(rawTime is NSNull) {
            guard let time = rawTime as? [String: Any] else { return nil }
            if let created = time["created"] {
                milliseconds = number(created)
            } else {
                milliseconds = context.timestampMilliseconds
            }
        } else {
            milliseconds = context.timestampMilliseconds
        }
        guard let milliseconds, milliseconds.isFinite,
              (0...253_402_300_799_999).contains(milliseconds) else { return nil }
        let timestamp = Date(timeIntervalSince1970: milliseconds / 1000)
        let nestedModel = payload["model"] as? [String: Any]
        let model = normalizedModelID(payload["modelID"] as? String)
            ?? normalizedModelID(nestedModel?["id"] as? String)
        let provider = text(payload["providerID"]) ?? text(nestedModel?["providerID"])
            ?? inferredUsageProvider(from: model)
        let reported = number(payload["cost"])
        let cost: Double
        let known: Bool
        // Upstream treats positive reported cost as authoritative. Zero usually means
        // OpenCode had no price, so preserve unknown state unless local pricing exists.
        if let reported, reported.isFinite, reported > 0 {
            cost = reported
            known = true
        } else if let model, let price = modelPrice(for: model, at: timestamp) {
            cost = price.cost(input: input, output: output + reasoning, cacheRead: cacheRead, cacheWrite: cacheWrite)
            known = true
        } else {
            cost = 0
            known = false
        }
        let embeddedPath = (payload["path"] as? [String: Any])?["root"]
        return OpenCodeMessage(
            messageID: text(payload["id"]) ?? context.rowID,
            sessionID: context.sessionID ?? text(payload["sessionID"])
                ?? context.fallbackSessionID ?? "anonymous:\(context.originID)",
            originID: context.originID,
            namespace: context.namespace,
            timestamp: timestamp,
            model: model,
            provider: provider,
            input: input,
            output: output,
            reasoning: reasoning,
            cacheRead: cacheRead,
            cacheWrite: cacheWrite,
            cost: cost,
            costIsKnown: known,
            projectPath: text(context.projectPath) ?? text(embeddedPath),
            sessionLabel: text(context.sessionLabel))
    }

    func accumulate(into usage: inout RawTokenUsage) throws {
        guard input + output + reasoning + cacheRead + cacheWrite > 0 || cost > 0 else { return }
        let nextCost = usage.cost + cost
        guard nextCost.isFinite else { throw OpenCodeReaderError.invalidAggregate }
        guard let total = usage.accumulateTokenCounts(
            input: input, output: output, cacheRead: cacheRead, cacheWrite: cacheWrite, reasoning: reasoning) else {
            throw OpenCodeReaderError.invalidAggregate
        }
        usage.cost = nextCost
        usage.accumulatePerModelUsage(model: model, source: "OpenCode", totalTokens: total, cost: cost)
        usage.recordTokenEvent(
            timestamp: timestamp, source: "OpenCode", model: model, provider: provider,
            inputTokens: input, outputTokens: output, cacheReadTokens: cacheRead, cacheWriteTokens: cacheWrite,
            reasoningTokens: reasoning, cost: cost, costIsKnown: costIsKnown,
            attribution: UsageAttribution(
                projectPath: projectPath, sessionID: streamID, sessionLabel: sessionLabel, quality: .exact))
        usage.activityEvents.append(ActivityTimeEvent(
            streamID: streamID, timestamp: timestamp, key: UsageModelGrouping.groupingKey(for: model)))
    }

    private static func text(_ value: Any?) -> String? {
        (value as? String)?.trimmedNonEmpty
    }

    private static func number(_ value: Any?) -> Double? {
        guard let value = value as? NSNumber, CFGetTypeID(value) != CFBooleanGetTypeID() else { return nil }
        return value.doubleValue
    }

    private static func count(_ value: Any?) -> Int? {
        guard let value, !(value is NSNull) else { return 0 }
        guard let number = number(value), number.isFinite, number.rounded(.towardZero) == number,
              number <= 1_000_000_000 else { return nil }
        return Int(max(0, number))
    }
}
