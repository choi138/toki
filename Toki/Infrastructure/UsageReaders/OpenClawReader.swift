import Foundation

// Reads ~/.openclaw/agents/**/*.jsonl
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
            readJSONLLines(at: file).forEach { line in
                guard let data = line.data(using: .utf8),
                      let msg = try? decoder.decode(RawMessage.self, from: data),
                      msg.role == "assistant" else { return }

                var eventDate: Date?
                if let tsStr = msg.timestamp ?? msg.createdAt {
                    guard let date = DateParser.parse(tsStr),
                          date >= startDate && date < endDate else { return }
                    eventDate = date
                }

                guard let usage = msg.usage else { return }
                result.inputTokens += usage.inputTokens ?? usage.promptTokens ?? 0
                result.outputTokens += usage.outputTokens ?? usage.completionTokens ?? 0
                result.cacheReadTokens += usage.cacheReadInputTokens ?? 0
                result.cacheWriteTokens += usage.cacheCreationInputTokens ?? 0
                if let eventDate {
                    activityEvents.append(
                        ActivityTimeEvent(
                            streamID: file.path,
                            timestamp: eventDate,
                            key: nil
                        )
                    )
                }
            }
        }

        result.mergeActivityEvents(activityEvents, source: name)

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
