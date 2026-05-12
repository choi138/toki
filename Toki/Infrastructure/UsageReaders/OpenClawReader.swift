import Foundation

/// Reads ~/.openclaw/agents/**/*.jsonl
struct OpenClawReader: TokenReader {
    let name = "OpenClaw"

    private var agentsURL: URL {
        homeDir().appendingPathComponent(".openclaw/agents")
    }

    func readUsage(from startDate: Date, to endDate: Date) async throws -> RawTokenUsage {
        guard FileManager.default.fileExists(atPath: agentsURL.path) else {
            return RawTokenUsage()
        }

        let files = findFiles(in: agentsURL, withExtension: "jsonl", modifiedAfter: startDate)
        let decoder = JSONDecoder()

        var result = RawTokenUsage()
        var activityEvents: [ActivityTimeEvent<String>] = []

        for file in files {
            for line in readJSONLLines(at: file) {
                guard let data = line.data(using: .utf8),
                      let msg = try? decoder.decode(RawMessage.self, from: data),
                      msg.role == "assistant" else { continue }

                var eventDate: Date?
                if let tsStr = msg.timestamp ?? msg.createdAt {
                    guard let date = DateParser.parse(tsStr),
                          date >= startDate, date < endDate else { continue }
                    eventDate = date
                }

                guard let usage = msg.usage else { continue }
                let input = usage.inputTokens ?? usage.promptTokens ?? 0
                let output = usage.outputTokens ?? usage.completionTokens ?? 0
                let cacheRead = usage.cacheReadInputTokens ?? 0
                let cacheWrite = usage.cacheCreationInputTokens ?? 0

                result.inputTokens += input
                result.outputTokens += output
                result.cacheReadTokens += cacheRead
                result.cacheWriteTokens += cacheWrite
                if let eventDate {
                    activityEvents.append(
                        ActivityTimeEvent(
                            streamID: file.path,
                            timestamp: eventDate,
                            key: nil))
                    result.recordTokenEvent(
                        timestamp: eventDate,
                        source: name,
                        model: nil,
                        inputTokens: input,
                        outputTokens: output,
                        cacheReadTokens: cacheRead,
                        cacheWriteTokens: cacheWrite)
                }
            }
        }

        result.mergeActivityEvents(activityEvents, source: name, clippingEndDate: endDate)

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
