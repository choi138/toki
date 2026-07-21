import Foundation
import TokiUsageCore

/// Reads ~/.openclaw/agents/**/*.jsonl
struct OpenClawReader: TokenReader {
    static let sourceName = "OpenClaw"

    let name = Self.sourceName

    private var agentsURL: URL {
        homeDir().appendingPathComponent(".openclaw/agents")
    }

    func readUsage(from startDate: Date, to endDate: Date) async throws -> RawTokenUsage {
        guard FileManager.default.fileExists(atPath: agentsURL.path) else {
            return RawTokenUsage()
        }

        let files = findFiles(in: agentsURL, withExtension: "jsonl", modifiedAfter: startDate)
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
            for line in session.lines {
                guard let data = line.data(using: .utf8),
                      let msg = try? decoder.decode(RawMessage.self, from: data),
                      msg.role == "assistant",
                      let tsStr = msg.timestamp ?? msg.createdAt,
                      let eventDate = DateParser.parse(tsStr),
                      eventDate >= startDate,
                      eventDate < endDate,
                      let usage = msg.usage else { continue }

                let input = usage.inputTokens ?? usage.promptTokens ?? 0
                let output = usage.outputTokens ?? usage.completionTokens ?? 0
                let cacheRead = usage.cacheReadInputTokens ?? 0
                let cacheWrite = usage.cacheCreationInputTokens ?? 0

                result.inputTokens += input
                result.outputTokens += output
                result.cacheReadTokens += cacheRead
                result.cacheWriteTokens += cacheWrite
                activityEvents.append(
                    ActivityTimeEvent(
                        streamID: session.streamID,
                        timestamp: eventDate,
                        key: nil))
                result.recordTokenEvent(
                    timestamp: eventDate,
                    source: sourceName,
                    model: nil,
                    inputTokens: input,
                    outputTokens: output,
                    cacheReadTokens: cacheRead,
                    cacheWriteTokens: cacheWrite,
                    attribution: UsageAttribution(
                        sessionID: usageSessionID(fromPath: session.streamID),
                        quality: .unknown))
            }
        }

        result.mergeActivityEvents(activityEvents, source: sourceName, clippingEndDate: endDate)

        return result
    }
}

// MARK: - Private Types

private struct RawMessage: Decodable {
    let role: String?
    let timestamp: String?
    let createdAt: String?
    let usage: Usage?

    enum CodingKeys: String, CodingKey {
        case role, timestamp, usage
        case createdAt = "created_at"
    }

    struct Usage: Decodable {
        let inputTokens: Int?
        let outputTokens: Int?
        let promptTokens: Int?
        let completionTokens: Int?
        let cacheReadInputTokens: Int?
        let cacheCreationInputTokens: Int?

        enum CodingKeys: String, CodingKey {
            case inputTokens = "input_tokens"
            case outputTokens = "output_tokens"
            case promptTokens = "prompt_tokens"
            case completionTokens = "completion_tokens"
            case cacheReadInputTokens = "cache_read_input_tokens"
            case cacheCreationInputTokens = "cache_creation_input_tokens"
        }
    }
}
