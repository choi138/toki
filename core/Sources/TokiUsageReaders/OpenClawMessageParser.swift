import CoreFoundation
import Foundation
import TokiSyncProtocol
import TokiUsageCore

/// Format interpretation follows junhoyeo/tokscale@3bd6dceb98925edab4e149c9bb1cf3fec9123f17
/// sessions/openclaw.rs and sessions/utils.rs (MIT; license reproduced below).
struct OpenClawTokenCounts: Hashable {
    let input: Int
    let output: Int
    let cacheRead: Int
    let cacheWrite: Int
    let reasoning: Int

    init?(usage: [String: Any], nested: Bool) {
        let keys = nested
            ? ["input", "output", "cacheRead", "cacheWrite", "reasoningTokens"]
            : ["input_tokens", "output_tokens", "cache_read_input_tokens", "cache_creation_input_tokens"]
        guard keys.contains(where: { usage[$0] != nil })
            || usage["prompt_tokens"] != nil || usage["completion_tokens"] != nil else { return nil }
        guard let input = Self.count(usage[nested ? "input" : "input_tokens"], fallback: usage["prompt_tokens"]),
              let output = Self.count(usage[nested ? "output" : "output_tokens"], fallback: usage["completion_tokens"]),
              let cacheRead = Self.count(usage[nested ? "cacheRead" : "cache_read_input_tokens"]),
              let cacheWrite = Self.count(usage[nested ? "cacheWrite" : "cache_creation_input_tokens"]),
              let reasoning = Self.count(nested ? usage["reasoningTokens"] : nil) else { return nil }
        self.input = input
        self.cacheRead = cacheRead
        self.cacheWrite = cacheWrite
        // OpenClaw's totalTokens includes reasoning in output, not as an extra bucket.
        self.reasoning = min(reasoning, output)
        self.output = output - self.reasoning
    }

    private static func count(_ value: Any?, fallback: Any? = nil) -> Int? {
        // JSONSerialization represents JSON null as NSNull, which must not hide a populated alias.
        let selected = value.flatMap { $0 is NSNull ? nil : $0 } ?? fallback
        guard let selected, !(selected is NSNull) else { return 0 }
        guard let number = openClawNumber(selected), number >= 0, number <= 1_000_000_000,
              number.rounded(.towardZero) == number else { return nil }
        return Int(number)
    }
}

struct OpenClawEventIdentity: Hashable {
    let agent: String
    let id: String
    let timestamp: Date?
    let fallbackSessionID: String?
    let tokens: OpenClawTokenCounts
}

struct OpenClawFallbackEventKey: Hashable {
    let agent: String
    let sessionID: String
    let timestamp: Date?
    let model: String?
    let provider: String?
    let tokens: OpenClawTokenCounts
    let reportedCost: Double?
}

struct OpenClawFallbackEventIdentity: Hashable {
    let event: OpenClawFallbackEventKey
    let occurrence: Int
}

struct OpenClawUsageEvent {
    let id: String?
    let sessionID: String
    let date: Date
    let ownDate: Date?
    let model: String?
    let provider: String?
    let tokens: OpenClawTokenCounts
    let reportedCost: Double?

    func identity(agent: String) -> OpenClawEventIdentity? {
        // Timestamped IDs survive migration and forks. Without an event timestamp,
        // only replicas of the same session have enough evidence to reconcile.
        id.map {
            OpenClawEventIdentity(
                agent: agent, id: $0, timestamp: ownDate,
                fallbackSessionID: ownDate == nil ? sessionID : nil, tokens: tokens)
        }
    }

    func fallbackIdentityKey(agent: String) -> OpenClawFallbackEventKey {
        // Copy reconciliation deliberately excludes message content and uses only
        // session provenance plus normalized usage metadata.
        OpenClawFallbackEventKey(
            agent: agent,
            sessionID: sessionID,
            timestamp: ownDate,
            model: model,
            provider: provider,
            tokens: tokens,
            reportedCost: reportedCost)
    }
}

struct OpenClawMessageParser {
    var sessionID: String
    var acceptsSessionHeader = false
    private var currentModel: String?
    private var currentProvider: String?
    private var recognizedRows = 0
    private var invalidRows = 0

    init(sessionID: String, acceptsSessionHeader: Bool = false) {
        self.sessionID = sessionID
        self.acceptsSessionHeader = acceptsSessionHeader
    }

    mutating func parse(
        _ data: Data,
        fallbackDate: Date? = nil,
        sessionModel: String? = nil,
        sessionProvider: String? = nil) -> OpenClawUsageEvent? {
        guard !data.allSatisfy({ [9, 10, 13, 32].contains($0) }) else { return nil }
        guard let entry = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            invalidRows += 1
            return nil
        }
        let type = entry["type"] as? String
        if handleContext(entry, type: type) { return nil }
        let nested = type == "message" && entry["message"] is [String: Any]
        guard let message = nested ? entry["message"] as? [String: Any] : entry,
              let role = message["role"] as? String,
              ["assistant", "user", "tool", "toolResult", "system"].contains(role) else {
            invalidRows += 1
            return nil
        }
        guard role == "assistant", !Self.isArtifact(message), let usageValue = message["usage"] else {
            recognizedRows += 1
            return nil
        }
        guard let usage = usageValue as? [String: Any],
              let tokens = OpenClawTokenCounts(usage: usage, nested: nested) else {
            invalidRows += 1
            return nil
        }
        let model = normalizedModelID(message["model"] as? String)
            ?? currentModel ?? normalizedModelID(sessionModel)
        let provider = Self.nonEmpty(message["provider"]) ?? currentProvider ?? Self.nonEmpty(sessionProvider)
        let ownValue = [message["timestamp"], message["created_at"], nested ? entry["timestamp"] : nil]
            .compactMap { $0 }
            .first { !($0 is NSNull) }
        let ownDate = Self.date(ownValue)
        if !nested, ownValue == nil {
            // Legacy top-level rows without dates were intentionally ignored.
            recognizedRows += 1
            return nil
        }
        guard ownValue == nil || ownDate != nil,
              let date = ownDate ?? (nested ? fallbackDate : nil) else {
            invalidRows += 1
            return nil
        }
        // Apply context before range selection, including valid messages outside the report window.
        currentModel = model
        currentProvider = provider
        recognizedRows += 1
        let rawCost = (usage["cost"] as? [String: Any])?["total"]
        let reportedCost = openClawNumber(rawCost).flatMap {
            (0...RemoteUsageSnapshotValidator.maximumCostPerEvent).contains($0) ? $0 : nil
        }
        return OpenClawUsageEvent(
            id: Self.nonEmpty(entry["id"]), sessionID: sessionID, date: date, ownDate: ownDate,
            model: model, provider: provider, tokens: tokens, reportedCost: reportedCost)
    }

    func validate() throws {
        if invalidRows > 0, recognizedRows == 0 { throw OpenClawReadError.unrecognizedTranscript }
    }

    mutating func beginSession(_ id: String) {
        sessionID = id
        currentModel = nil
        currentProvider = nil
    }

    mutating func recordMalformedRow() {
        invalidRows += 1
    }

    private mutating func handleContext(_ entry: [String: Any], type: String?) -> Bool {
        switch type {
        case "session":
            if acceptsSessionHeader, let id = Self.nonEmpty(entry["id"]) { sessionID = id }
            currentModel = nil
            currentProvider = nil
        case "model_change":
            currentModel = normalizedModelID(entry["modelId"] as? String) ?? currentModel
            currentProvider = Self.nonEmpty(entry["provider"]) ?? currentProvider
        case "custom":
            if entry["customType"] as? String == "model-snapshot", let data = entry["data"] as? [String: Any] {
                currentModel = normalizedModelID(data["modelId"] as? String) ?? currentModel
                currentProvider = Self.nonEmpty(data["provider"]) ?? currentProvider
            }
        default:
            return false
        }
        recognizedRows += 1
        return true
    }

    private static func isArtifact(_ message: [String: Any]) -> Bool {
        message["api"] as? String == "openclaw-transcript"
            || (message["provider"] as? String == "openclaw"
                && ["delivery-mirror", "gateway-injected"].contains(message["model"] as? String ?? ""))
    }

    static func date(_ value: Any?) -> Date? {
        if let text = value as? String { return DateParser.parse(text) }
        guard let number = openClawNumber(value), number > 0 else { return nil }
        let seconds = number > 100_000_000_000 ? number / 1000 : number
        guard seconds < 253_402_300_800 else { return nil }
        return Date(timeIntervalSince1970: seconds)
    }

    private static func nonEmpty(_ value: Any?) -> String? {
        guard let string = value as? String else { return nil }
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

private func openClawNumber(_ value: Any?) -> Double? {
    guard let value = value as? NSNumber, CFGetTypeID(value) != CFBooleanGetTypeID(),
          value.doubleValue.isFinite else { return nil }
    return value.doubleValue
}

/*
 Format and fixture attribution: junhoyeo/tokscale, MIT License
 Copyright (c) 2025 Junho Yeo

 Permission is hereby granted, free of charge, to any person obtaining a copy
 of this software and associated documentation files (the "Software"), to deal
 in the Software without restriction, including without limitation the rights
 to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
 copies of the Software, and to permit persons to whom the Software is
 furnished to do so, subject to the following conditions:

 The above copyright notice and this permission notice shall be included in all
 copies or substantial portions of the Software.

 THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
 IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
 FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
 AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
 LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
 OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
 SOFTWARE.
 */
