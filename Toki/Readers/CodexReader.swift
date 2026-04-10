import Foundation
import SQLite3

// Reads ~/.codex/state_5.sqlite to discover active rollouts,
// then reconstructs per-range usage from rollout JSONL token_count snapshots.
struct CodexReader: TokenReader {
    let name = "Codex"

    private var dbPath: String {
        homeDir().appendingPathComponent(".codex/state_5.sqlite").path
    }

    func readUsage(from startDate: Date, to endDate: Date) async throws -> RawTokenUsage {
        guard FileManager.default.fileExists(atPath: dbPath) else {
            return RawTokenUsage()
        }

        let sessions = overlappingSessions(from: startDate, to: endDate)
        guard !sessions.isEmpty else { return RawTokenUsage() }

        return sessions.reduce(into: RawTokenUsage()) { result, session in
            let url = URL(fileURLWithPath: session.rolloutPath)
            guard FileManager.default.fileExists(atPath: url.path) else { return }
            result += Self.usage(
                fromRolloutLines: readJSONLLines(at: url),
                model: session.model,
                from: startDate,
                to: endDate
            )
        }
    }

    static func usage(
        fromRolloutLines lines: [String],
        model: String?,
        from startDate: Date,
        to endDate: Date
    ) -> RawTokenUsage {
        let decoder = JSONDecoder()
        let normalizedModel = model?.isEmpty == false ? model : nil

        var previousSnapshot: CodexUsageSnapshot?
        var result = RawTokenUsage()

        lines.forEach { line in
            guard let data = line.data(using: .utf8),
                  let entry = try? decoder.decode(CodexRolloutEntry.self, from: data),
                  let timestamp = entry.timestamp,
                  let date = DateParser.parse(timestamp),
                  let snapshot = entry.tokenSnapshot else { return }

            let delta = snapshot.delta(since: previousSnapshot)
            previousSnapshot = snapshot

            guard date >= startDate && date < endDate else { return }

            let usage = delta.normalizedUsage
            guard usage.totalTokens > 0 else { return }

            result.inputTokens += usage.inputTokens
            result.outputTokens += usage.outputTokens
            result.cacheReadTokens += usage.cacheReadTokens
            result.reasoningTokens += usage.reasoningTokens

            let entryCost: Double
            if let model = normalizedModel, let price = modelPrice(for: model) {
                entryCost = price.cost(
                    input: usage.inputTokens,
                    output: usage.outputTokens + usage.reasoningTokens,
                    cacheRead: usage.cacheReadTokens,
                    cacheWrite: 0
                )
                result.cost += entryCost
            } else {
                entryCost = 0
            }

            if let model = normalizedModel {
                result.perModel[model, default: PerModelUsage()].totalTokens += usage.totalTokens
                result.perModel[model, default: PerModelUsage()].cost += entryCost
            }
        }

        return result
    }

    private func overlappingSessions(from startDate: Date, to endDate: Date) -> [CodexSession] {
        var db: OpaquePointer?
        guard sqlite3_open_v2(dbPath, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
            return []
        }
        defer { sqlite3_close(db) }
        sqlite3_busy_timeout(db, 2000)

        let startEpoch = startDate.timeIntervalSince1970
        let endEpoch   = endDate.timeIntervalSince1970
        let query = """
            SELECT DISTINCT rollout_path, COALESCE(model, '')
            FROM threads
            WHERE updated_at >= ? AND created_at < ?
        """

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, query, -1, &stmt, nil) == SQLITE_OK else {
            return []
        }
        defer { sqlite3_finalize(stmt) }

        sqlite3_bind_int64(stmt, 1, Int64(startEpoch))
        sqlite3_bind_int64(stmt, 2, Int64(endEpoch))

        var sessions: [CodexSession] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            guard let rolloutPathPtr = sqlite3_column_text(stmt, 0) else { continue }
            let rolloutPath = String(cString: rolloutPathPtr)
            let model = sqlite3_column_text(stmt, 1).map { String(cString: $0) }
            sessions.append(CodexSession(rolloutPath: rolloutPath, model: model))
        }
        return sessions
    }
}

private struct CodexSession {
    let rolloutPath: String
    let model: String?
}

private struct CodexRolloutEntry: Decodable {
    let timestamp: String?
    let type: String?
    let payload: Payload?

    var tokenSnapshot: CodexUsageSnapshot? {
        guard type == "event_msg",
              payload?.type == "token_count",
              let totalUsage = payload?.info?.totalTokenUsage else {
            return nil
        }
        return CodexUsageSnapshot(
            inputTokens: totalUsage.inputTokens ?? 0,
            cachedInputTokens: totalUsage.cachedInputTokens ?? 0,
            outputTokens: totalUsage.outputTokens ?? 0,
            reasoningOutputTokens: totalUsage.reasoningOutputTokens ?? 0
        )
    }

    struct Payload: Decodable {
        let type: String?
        let info: Info?

        struct Info: Decodable {
            let totalTokenUsage: TotalTokenUsage?

            enum CodingKeys: String, CodingKey {
                case totalTokenUsage = "total_token_usage"
            }
        }
    }
}

private struct TotalTokenUsage: Decodable {
    let inputTokens: Int?
    let cachedInputTokens: Int?
    let outputTokens: Int?
    let reasoningOutputTokens: Int?

    enum CodingKeys: String, CodingKey {
        case inputTokens = "input_tokens"
        case cachedInputTokens = "cached_input_tokens"
        case outputTokens = "output_tokens"
        case reasoningOutputTokens = "reasoning_output_tokens"
    }
}

private struct CodexUsageSnapshot {
    let inputTokens: Int
    let cachedInputTokens: Int
    let outputTokens: Int
    let reasoningOutputTokens: Int

    func delta(since previous: CodexUsageSnapshot?) -> CodexUsageSnapshot {
        guard let previous else { return self }
        return CodexUsageSnapshot(
            inputTokens: max(0, inputTokens - previous.inputTokens),
            cachedInputTokens: max(0, cachedInputTokens - previous.cachedInputTokens),
            outputTokens: max(0, outputTokens - previous.outputTokens),
            reasoningOutputTokens: max(0, reasoningOutputTokens - previous.reasoningOutputTokens)
        )
    }

    var normalizedUsage: RawTokenUsage {
        let uncachedInput = max(0, inputTokens - cachedInputTokens)
        let nonReasoningOutput = max(0, outputTokens - reasoningOutputTokens)

        return RawTokenUsage(
            inputTokens: uncachedInput,
            outputTokens: nonReasoningOutput,
            cacheReadTokens: cachedInputTokens,
            reasoningTokens: reasoningOutputTokens
        )
    }
}
