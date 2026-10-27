import CoreFoundation
import Foundation
import TokiUsageCore

enum HermesDelegateLogParser {
    static func parse(file: URL) throws -> HermesDelegateParsedLog {
        let directory = file.deletingLastPathComponent()
        let meta = try metadata(directory.appendingPathComponent("meta.json"))
        let status = try metadata(directory.appendingPathComponent("status.json"))
        let fallbackDate = try completionDate(directory: directory, file: file)
        var state = State(
            identity: file.path, timestamp: fallbackDate,
            model: status["model"] as? String ?? meta["model"] as? String,
            cwd: meta["workdir"] as? String)
        switch meta["reviewer"] as? String ?? meta["kind"] as? String {
        case "claude": state.provider = .claude
        case "codex", "qa": state.provider = .codex
        default:
            if file.lastPathComponent == "claude.out" { state.provider = .claude }
            if file.lastPathComponent == "events.jsonl" { state.provider = .codex }
        }
        try forEachBoundedJSONLLine(at: file, limits: .default) { line, index in
            guard let data = line.data(using: .utf8),
                  let event = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
            state.consume(event, index: index)
        }
        return state.finish()
    }

    private static func metadata(_ file: URL) throws -> [String: Any] {
        guard FileManager.default.fileExists(atPath: file.path) else { return [:] }
        let values = try file.resourceValues(forKeys: [.fileSizeKey, .isSymbolicLinkKey, .isRegularFileKey])
        guard values.isSymbolicLink != true, values.isRegularFile == true,
              (values.fileSize ?? Int.max) <= 1024 * 1024 else { throw HermesDelegateReadError() }
        return (try? JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any]) ?? [:]
    }

    private static func completionDate(directory: URL, file: URL) throws -> Date {
        let ended = directory.appendingPathComponent("ended_at")
        if FileManager.default.fileExists(atPath: ended.path) {
            let values = try ended.resourceValues(forKeys: [.fileSizeKey, .isSymbolicLinkKey])
            guard values.isSymbolicLink != true, (values.fileSize ?? Int.max) < 128 else {
                throw HermesDelegateReadError()
            }
            let value = try String(contentsOf: ended, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
            if let date = DateParser.parse(value) { return date }
        }
        guard let date = try file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate else {
            throw HermesDelegateReadError()
        }
        return date
    }
}

private extension HermesDelegateLogParser {
    struct State {
        let identity: String
        let timestamp: Date
        var model: String?
        var cwd: String?
        var provider: HermesDelegateProvider?
        var sessionID: String?
        var entries: [HermesDelegateUsageEntry] = []
        var messages: [String: HermesDelegateUsageEntry] = [:]
        var completed = false
        var turns = 0

        mutating func consume(_ event: [String: Any], index: Int) {
            sessionID = event["thread_id"] as? String ?? event["session_id"] as? String ?? sessionID
            cwd = event["cwd"] as? String ?? cwd
            switch event["type"] as? String {
            case "thread.started": provider = .codex
            case "turn.failed", "turn.started": completed = false
            case "turn.completed":
                provider = .codex
                guard let usage = event["usage"] as? [String: Any],
                      let entry = entry(
                          usage, key: "turn-\(turns)", date: eventDate(event), codex: true) else { return }
                entries.append(entry)
                turns += 1
                completed = true
            case "assistant":
                provider = .claude
                guard let message = event["message"] as? [String: Any],
                      let usage = message["usage"] as? [String: Any] else { return }
                model = message["model"] as? String ?? model
                let key = message["id"] as? String ?? event["request_id"] as? String ?? "line-\(index)"
                guard let next = entry(usage, key: key, date: eventDate(event)) else { return }
                if let old = messages[key], old.totalTokens >= next.totalTokens { return }
                messages[key] = next
            case "result":
                provider = .claude
                consumeResult(event)
            default: break
            }
        }

        mutating func consumeResult(_ event: [String: Any]) {
            guard let usage = event["usage"] as? [String: Any],
                  let aggregate = entry(usage, key: "result", date: eventDate(event)) else { return }
            let models = event["modelUsage"] as? [String: [String: Any]] ?? [:]
            let modelEntries = models.keys.sorted().compactMap { model -> HermesDelegateUsageEntry? in
                guard let raw = models[model] else { return nil }
                let normalized: [String: Any] = [
                    "input_tokens": raw["inputTokens"] ?? 0, "output_tokens": raw["outputTokens"] ?? 0,
                    "cache_read_input_tokens": raw["cacheReadInputTokens"] ?? 0,
                    "cache_creation_input_tokens": raw["cacheCreationInputTokens"] ?? 0,
                ]
                return entry(normalized, key: "result-\(model)", date: eventDate(event), modelOverride: model)
            }
            // Model counters and aggregate counters describe the same calls, never add both.
            let matches = [\HermesDelegateUsageEntry.input, \.output, \.cacheRead, \.cacheWrite].allSatisfy { field in
                modelEntries.reduce(Decimal.zero) { $0 + Decimal($1[keyPath: field]) }
                    == Decimal(aggregate[keyPath: field])
            }
            if matches, modelEntries.count == 1, let modelEntry = modelEntries.first,
               let reconciled = entry(
                   usage, key: modelEntry.identity, date: modelEntry.timestamp, modelOverride: modelEntry.model) {
                entries = [reconciled]
            } else {
                // A mixed-model breakdown has no per-model cache TTLs. Retain the
                // aggregate when splitting it would discard one-hour cache writes.
                entries = !modelEntries.isEmpty && matches && aggregate.cacheWriteOneHour == 0
                    ? modelEntries : [aggregate]
            }
            completed = true
        }

        func finish() -> HermesDelegateParsedLog {
            HermesDelegateParsedLog(
                provider: provider, identity: identity, sessionID: sessionID, timestamp: timestamp,
                isComplete: completed, entries: completed || provider == .codex ? entries : Array(messages.values))
        }

        func eventDate(_ event: [String: Any]) -> Date {
            (event["timestamp"] as? String).flatMap(DateParser.parse) ?? timestamp
        }

        func entry(
            _ raw: [String: Any], key: String, date: Date,
            codex: Bool = false, modelOverride: String? = nil) -> HermesDelegateUsageEntry? {
            let input = count(raw["input_tokens"])
            let output = count(raw["output_tokens"])
            let read = count(raw[codex ? "cached_input_tokens" : "cache_read_input_tokens"])
            let write = count(raw[codex ? "cache_write_input_tokens" : "cache_creation_input_tokens"])
            let reasoning = codex ? count(raw["reasoning_output_tokens"] ?? raw["reasoning_tokens"]) : 0
            guard let input, let output, let read, let write, let reasoning,
                  !codex || (read <= input && reasoning <= output),
                  checkedTokenTotal(input, output, read, write, reasoning) != nil,
                  raw["input_tokens"] != nil || raw["output_tokens"] != nil else { return nil }
            let creation = raw["cache_creation"] as? [String: Any]
            let hour = min(write, count(creation?["ephemeral_1h_input_tokens"]) ?? 0)
            return HermesDelegateUsageEntry(
                identity: key, timestamp: date, model: normalizedModelID(modelOverride ?? model),
                input: codex ? input - read : input, output: codex ? output - reasoning : output,
                cacheRead: read, cacheWrite: write, cacheWriteOneHour: hour, reasoning: reasoning,
                attribution: UsageAttribution(
                    projectPath: cwd, sessionID: sessionID, sessionLabel: "Hermes delegation",
                    quality: cwd == nil ? .unknown : .exact))
        }

        func count(_ raw: Any?) -> Int? {
            guard let raw else { return 0 }
            guard let number = raw as? NSNumber,
                  CFGetTypeID(number) != CFBooleanGetTypeID(),
                  number.doubleValue >= 0, number.doubleValue < Double(Int.max),
                  number.doubleValue.rounded(.towardZero) == number.doubleValue else { return nil }
            return number.intValue
        }
    }
}
