import Foundation

/// Reads ~/.gemini/tmp/*/chats/**/*.json
/// Parses Gemini API usageMetadata from conversation history files
struct GeminiReader: TokenReader {
    let name = "Gemini CLI"

    private var chatsBaseURL: URL {
        homeDir().appendingPathComponent(".gemini/tmp")
    }

    func readUsage(from startDate: Date, to endDate: Date) async throws -> RawTokenUsage {
        guard FileManager.default.fileExists(atPath: chatsBaseURL.path) else {
            return RawTokenUsage()
        }

        let files = findFiles(in: chatsBaseURL, withExtension: "json", modifiedAfter: startDate)
        let decoder = JSONDecoder()
        var result = RawTokenUsage()
        var activityEvents: [ActivityTimeEvent<String>] = []

        for file in files {
            guard let data = try? Data(contentsOf: file) else { continue }

            if let session = try? decoder.decode(GeminiSession.self, from: data) {
                result += usage(
                    from: session.messages,
                    from: startDate,
                    to: endDate,
                    streamID: file.path,
                    activityEvents: &activityEvents)
                continue
            }

            guard let fileDate = (
                try? file.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate,
                fileDate >= startDate, fileDate < endDate else { continue }

            let messages: [LegacyGeminiMessage] = if let array = try? decoder.decode(
                [LegacyGeminiMessage].self,
                from: data) {
                array
            } else {
                (try? decoder.decode(LegacyGeminiMessage.self, from: data)).map { [$0] } ?? []
            }

            var hasUsageMetadata = false
            for msg in messages {
                guard let meta = msg.usageMetadata else { continue }
                hasUsageMetadata = true
                result.inputTokens += meta.promptTokenCount ?? 0
                result.outputTokens += meta.candidatesTokenCount ?? 0
                result.cacheReadTokens += meta.cachedContentTokenCount ?? 0
            }

            if hasUsageMetadata {
                activityEvents.append(
                    ActivityTimeEvent(
                        streamID: file.path,
                        timestamp: fileDate,
                        key: nil))
            }
        }

        result.mergeActivityEvents(activityEvents, source: name)

        return result
    }

    private func usage(
        from messages: [GeminiSession.Message],
        from startDate: Date,
        to endDate: Date,
        streamID: String,
        activityEvents: inout [ActivityTimeEvent<String>]) -> RawTokenUsage {
        var result = RawTokenUsage()

        for msg in messages {
            guard msg.type == "gemini",
                  let timestamp = msg.timestamp,
                  let date = DateParser.parse(timestamp),
                  date >= startDate, date < endDate,
                  let tokens = msg.tokens else { continue }

            let input = tokens.input ?? 0
            let output = (tokens.output ?? 0) + (tokens.tool ?? 0)
            let cacheRead = tokens.cached ?? 0
            let reasoning = tokens.thoughts ?? 0

            result.inputTokens += input
            result.outputTokens += output
            result.cacheReadTokens += cacheRead
            result.reasoningTokens += reasoning
            activityEvents.append(
                ActivityTimeEvent(
                    streamID: streamID,
                    timestamp: date,
                    key: normalizedModelID(msg.model)))

            let entryCost: Double
            if let model = normalizedModelID(msg.model), let price = modelPrice(for: model) {
                entryCost = price.cost(
                    input: input,
                    output: output + reasoning,
                    cacheRead: cacheRead,
                    cacheWrite: 0)
                result.cost += entryCost
            } else {
                entryCost = 0
            }

            if let model = normalizedModelID(msg.model) {
                let totalTokens = input + output + cacheRead + reasoning
                result.perModel[model, default: PerModelUsage()].totalTokens += totalTokens
                result.perModel[model, default: PerModelUsage()].cost += entryCost
                result.perModel[model, default: PerModelUsage()].sources.insert(name)
            }
        }

        return result
    }
}

// MARK: - Private Types

private struct LegacyGeminiMessage: Decodable {
    let usageMetadata: UsageMetadata?

    struct UsageMetadata: Decodable {
        let promptTokenCount: Int?
        let candidatesTokenCount: Int?
        let totalTokenCount: Int?
        let cachedContentTokenCount: Int?
    }
}

private struct GeminiSession: Decodable {
    let messages: [Message]

    struct Message: Decodable {
        let timestamp: String?
        let type: String?
        let tokens: Tokens?
        let model: String?

        struct Tokens: Decodable {
            let input: Int?
            let output: Int?
            let cached: Int?
            let thoughts: Int?
            let tool: Int?
            let total: Int?
        }
    }
}
