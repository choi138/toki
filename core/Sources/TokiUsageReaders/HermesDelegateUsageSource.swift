import Foundation
import TokiUsageCore

enum HermesDelegateProvider: String {
    case codex
    case claude

    var source: String {
        self == .codex ? "Codex" : "Claude Code"
    }
}

/// Only token/model metadata is retained. Prompts and tool output never enter this cache.
struct HermesDelegateUsageSource {
    let root: URL
    let provider: HermesDelegateProvider
    private let cache = HermesDelegateLogCache()

    static func locations(root: URL) -> [LocalUsageSourceLocation] {
        [.directory(root, extensions: ["jsonl", "out", "json", ""])]
    }

    func read() async throws -> HermesDelegateUsage {
        do {
            let limits = PiCompatibleReadLimits.default
            var visited = 0
            var files: [URL] = []
            // Scan once per extension; discovery skips child symlinks and enforces shared bounds.
            for ext in ["jsonl", "out"] {
                files += try findUsageFiles(
                    in: root, withExtension: ext, maximumFileCount: limits.maximumFileCount,
                    maximumEntryCount: limits.maximumEntryCount, visitedEntryCount: &visited)
            }
            let names: Set = ["events.jsonl", "claude.out", "review.out", "qa.out"]
            files = files.filter { names.contains($0.lastPathComponent) }
            guard files.count <= limits.maximumFileCount else {
                throw HermesDelegateReadError()
            }
            var logs: [HermesDelegateParsedLog] = []
            var eventCount = 0
            for file in files.sorted(by: { $0.path < $1.path }) {
                try Task.checkCancellation()
                let log = try await cache.log(at: file)
                guard log.provider == provider else { continue }
                try recordUsageEvents(log.entries.count, total: &eventCount, maximum: limits.maximumEventCount)
                logs.append(log)
            }
            await cache.retain(files: Set(files))
            return HermesDelegateUsage(provider: provider, logs: logs)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            // Underlying IO diagnostics can contain private worktree names.
            throw HermesDelegateReadError()
        }
    }
}

struct HermesDelegateReadError: LocalizedError {
    var errorDescription: String? {
        "Hermes delegated usage could not be read completely."
    }
}

struct HermesDelegateUsage {
    let provider: HermesDelegateProvider
    let logs: [HermesDelegateParsedLog]

    /// Workers start fresh sessions. A completed worker's final counters own that session;
    /// its normal transcript, when present, must not also contribute tokens.
    var completedSessionIDs: Set<String> {
        Set(logs.filter(\.isComplete).compactMap(\.sessionID))
    }

    func usage(
        from start: Date, to end: Date, nativeSessionIDs: Set<String> = []) -> RawTokenUsage {
        var result = RawTokenUsage()
        var sessions: [String: HermesDelegateParsedLog] = [:]
        // Select a whole copy before date filtering: copied mtimes and aggregate/model
        // representations must not let the same worker contribute twice.
        for log in logs {
            let sessionKey = log.sessionID ?? log.identity
            if let old = sessions[sessionKey], !log.isPreferred(over: old) { continue }
            sessions[sessionKey] = log
        }
        var incompleteCount = 0
        for (sessionKey, log) in sessions {
            if !log.isComplete {
                if log.timestamp >= start, log.timestamp < end { incompleteCount += 1 }
                if nativeSessionIDs.contains(sessionKey) { continue }
            }
            for entry in log.entries where entry.timestamp >= start && entry.timestamp < end {
                entry.accumulate(into: &result, source: provider.source)
            }
        }
        if incompleteCount > 0 {
            result.supplemental.append(SupplementalUsage(
                id: "hermes-delegate-incomplete-\(provider.rawValue)",
                label: "Delegated runs with incomplete usage", value: incompleteCount,
                unit: .count, source: provider.source, model: nil, includedInTotals: false, quality: .contextOnly))
        }
        return result
    }
}

struct HermesDelegateParsedLog {
    let provider: HermesDelegateProvider?
    let identity: String
    let sessionID: String?
    let timestamp: Date
    let isComplete: Bool
    let entries: [HermesDelegateUsageEntry]

    func isPreferred(over other: HermesDelegateParsedLog) -> Bool {
        if isComplete != other.isComplete { return isComplete }
        let total = entries.reduce(Decimal.zero) { $0 + Decimal($1.totalTokens) }
        let otherTotal = other.entries.reduce(Decimal.zero) { $0 + Decimal($1.totalTokens) }
        if total != otherTotal { return total > otherTotal }
        // The earliest completion wins when identical output has been copied later.
        return timestamp < other.timestamp
    }
}

struct HermesDelegateUsageEntry {
    let identity: String
    let timestamp: Date
    let model: String?
    let input: Int
    let output: Int
    let cacheRead: Int
    let cacheWrite: Int
    let cacheWriteOneHour: Int
    let reasoning: Int
    let attribution: UsageAttribution

    var totalTokens: Int {
        checkedTokenTotal(input, output, cacheRead, cacheWrite, reasoning) ?? 0
    }

    func accumulate(into result: inout RawTokenUsage, source: String) {
        let price = model.flatMap { modelPrice(for: $0, at: timestamp) }
        let cost = price?.cost(
            input: input, output: output + reasoning, cacheRead: cacheRead,
            cacheWrite: cacheWrite - cacheWriteOneHour, cacheWriteOneHour: cacheWriteOneHour) ?? 0
        guard let total = result.accumulateTokenCounts(
            input: input, output: output, cacheRead: cacheRead, cacheWrite: cacheWrite, reasoning: reasoning) else {
            return
        }
        result.cost += cost
        result.accumulatePerModelUsage(model: model, source: source, totalTokens: total, cost: cost)
        result.recordTokenEvent(
            timestamp: timestamp, source: source, model: model, inputTokens: input, outputTokens: output,
            cacheReadTokens: cacheRead, cacheWriteTokens: cacheWrite, reasoningTokens: reasoning,
            cost: cost, costIsKnown: price != nil, attribution: attribution)
    }
}

private actor HermesDelegateLogCache {
    private struct CachedLog {
        let fingerprint: [String]
        let log: HermesDelegateParsedLog
    }

    private var logs: [URL: CachedLog] = [:]

    func log(at file: URL) throws -> HermesDelegateParsedLog {
        let directory = file.deletingLastPathComponent()
        let files = [file] + ["meta.json", "status.json", "started_at", "ended_at"].map {
            directory.appendingPathComponent($0)
        }
        let fingerprint = try files.map { url -> String in
            guard FileManager.default.fileExists(atPath: url.path) else { return "missing" }
            let values = try url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
            return "\(values.fileSize ?? 0):\(values.contentModificationDate?.timeIntervalSince1970 ?? 0)"
        }
        if let cached = logs[file], cached.fingerprint == fingerprint { return cached.log }
        let parsed = try HermesDelegateLogParser.parse(file: file)
        logs[file] = CachedLog(fingerprint: fingerprint, log: parsed)
        return parsed
    }

    func retain(files: Set<URL>) {
        logs = logs.filter { files.contains($0.key) }
    }
}
