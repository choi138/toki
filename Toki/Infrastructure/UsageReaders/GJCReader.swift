import Foundation

/// Reads ~/.gjc/agent/sessions/**/*.jsonl
struct GJCReader: TokenReader {
    static let sourceName = "GJC"

    let name = Self.sourceName

    private var sessionsURL: URL {
        homeDir().appendingPathComponent(".gjc/agent/sessions")
    }

    func readUsage(from startDate: Date, to endDate: Date) async throws -> RawTokenUsage {
        guard FileManager.default.fileExists(atPath: sessionsURL.path) else {
            return RawTokenUsage()
        }

        let files = findFiles(in: sessionsURL, withExtension: "jsonl", modifiedAfter: startDate)
        var result = RawTokenUsage()
        for file in files {
            result += Self.usage(
                fromJSONLLines: readJSONLLines(at: file),
                streamID: file.path,
                from: startDate,
                to: endDate)
        }
        return result
    }

    static func usage(
        fromJSONLLines lines: [String],
        streamID: String,
        from startDate: Date,
        to endDate: Date) -> RawTokenUsage {
        usage(
            fromJSONLSessions: [(streamID: streamID, lines: lines)],
            from: startDate,
            to: endDate)
    }

    private static func usage(
        fromJSONLSessions sessions: [(streamID: String, lines: [String])],
        from startDate: Date,
        to endDate: Date) -> RawTokenUsage {
        let decoder = JSONDecoder()

        var result = RawTokenUsage()
        var activityEvents: [ActivityTimeEvent<String>] = []

        for session in sessions {
            var context = GJCSessionContext()

            for line in session.lines {
                guard let data = line.data(using: .utf8),
                      let entry = try? decoder.decode(GJCEntry.self, from: data) else {
                    continue
                }

                if entry.type == "session" {
                    context.id = nonEmpty(entry.id) ?? context.id
                    context.cwd = nonEmpty(entry.cwd) ?? context.cwd
                    continue
                }

                guard entry.type == "message",
                      let message = entry.message,
                      let usage = usagePayload(from: message),
                      let eventDate = entry.timestamp.flatMap(DateParser.parse),
                      eventDate >= startDate,
                      eventDate < endDate else {
                    continue
                }

                let counts = tokenCounts(from: usage)
                let model = normalizedModelID(message.model)
                let sessionID = context.id ?? usageSessionID(fromPath: session.streamID)
                let attribution = UsageAttribution(
                    projectPath: context.cwd,
                    sessionID: sessionID,
                    quality: context.cwd == nil ? .unknown : .exact)

                result.inputTokens += counts.input
                result.outputTokens += counts.output
                result.cacheReadTokens += counts.cacheRead
                result.cacheWriteTokens += counts.cacheWrite
                result.reasoningTokens += counts.reasoning
                result.cost += counts.cost

                activityEvents.append(
                    ActivityTimeEvent(
                        streamID: sessionID,
                        timestamp: eventDate,
                        key: model))

                if let model {
                    result.perModel[model, default: PerModelUsage()].totalTokens += counts.totalTokens
                    result.perModel[model, default: PerModelUsage()].cost += counts.cost
                    result.perModel[model, default: PerModelUsage()].sources.insert(sourceName)
                }

                result.recordTokenEvent(
                    timestamp: eventDate,
                    source: sourceName,
                    model: model,
                    inputTokens: counts.input,
                    outputTokens: counts.output,
                    cacheReadTokens: counts.cacheRead,
                    cacheWriteTokens: counts.cacheWrite,
                    reasoningTokens: counts.reasoning,
                    cost: counts.cost,
                    attribution: attribution)
            }
        }

        result.mergeActivityEvents(
            activityEvents,
            source: sourceName,
            clippingEndDate: endDate)

        return result
    }

    private static func usagePayload(from message: GJCMessage) -> GJCUsage? {
        if message.role == "assistant" {
            return message.usage
        }

        if message.role == "toolResult", message.toolName == "task" {
            return message.details?.usage
        }

        return nil
    }

    private static func tokenCounts(from usage: GJCUsage) -> GJCTokenCounts {
        let reasoning = max(0, usage.reasoningTokens ?? 0)
        let outputIncludingReasoning = max(0, usage.output ?? 0)
        return GJCTokenCounts(
            input: max(0, usage.input ?? 0),
            output: max(0, outputIncludingReasoning - reasoning),
            cacheRead: max(0, usage.cacheRead ?? 0),
            cacheWrite: max(0, usage.cacheWrite ?? 0),
            reasoning: reasoning,
            cost: max(0, usage.cost?.total ?? 0))
    }
}

// MARK: - Private Types

private struct GJCSessionContext {
    var id: String?
    var cwd: String?
}

private struct GJCTokenCounts {
    let input: Int
    let output: Int
    let cacheRead: Int
    let cacheWrite: Int
    let reasoning: Int
    let cost: Double

    var totalTokens: Int {
        input + output + cacheRead + cacheWrite + reasoning
    }
}

private struct GJCEntry: Decodable {
    let type: String?
    let id: String?
    let timestamp: String?
    let cwd: String?
    let message: GJCMessage?
}

private struct GJCMessage: Decodable {
    let role: String?
    let toolName: String?
    let model: String?
    let usage: GJCUsage?
    let details: GJCDetails?

    enum CodingKeys: String, CodingKey {
        case role, toolName, model, usage, details
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        role = try? container.decodeIfPresent(String.self, forKey: .role)
        toolName = try? container.decodeIfPresent(String.self, forKey: .toolName)
        model = try? container.decodeIfPresent(String.self, forKey: .model)
        usage = try? container.decodeIfPresent(GJCUsage.self, forKey: .usage)
        details = try? container.decodeIfPresent(GJCDetails.self, forKey: .details)
    }
}

private struct GJCDetails: Decodable {
    let usage: GJCUsage?
}

private struct GJCUsage: Decodable {
    let input: Int?
    let output: Int?
    let cacheRead: Int?
    let cacheWrite: Int?
    let totalTokens: Int?
    let premiumRequests: Int?
    let reasoningTokens: Int?
    let cost: GJCCost?
}

private struct GJCCost: Decodable {
    let total: Double?
}

private func nonEmpty(_ value: String?) -> String? {
    guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines),
          !trimmed.isEmpty else {
        return nil
    }
    return trimmed
}
