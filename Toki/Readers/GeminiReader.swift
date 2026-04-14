import Foundation

// Reads ~/.gemini/tmp/*/chats/**/*.json
// Parses Gemini API usageMetadata from conversation history files
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

        return files.reduce(into: RawTokenUsage()) { acc, file in
            guard let data = try? Data(contentsOf: file) else { return }

            if let session = try? decoder.decode(GeminiSession.self, from: data) {
                acc += usage(from: session.messages, from: startDate, to: endDate)
                return
            }

            guard let fileDate = (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate,
                  fileDate >= startDate && fileDate < endDate else { return }

            let messages: [LegacyGeminiMessage]
            if let array = try? decoder.decode([LegacyGeminiMessage].self, from: data) {
                messages = array
            } else {
                messages = (try? decoder.decode(LegacyGeminiMessage.self, from: data)).map { [$0] } ?? []
            }

            messages.forEach { msg in
                guard let meta = msg.usageMetadata else { return }
                acc.inputTokens += meta.promptTokenCount ?? 0
                acc.outputTokens += meta.candidatesTokenCount ?? 0
                acc.cacheReadTokens += meta.cachedContentTokenCount ?? 0
            }
        }
    }

    private func usage(from messages: [GeminiSession.Message], from startDate: Date, to endDate: Date) -> RawTokenUsage {
        messages.reduce(into: RawTokenUsage()) { acc, msg in
            guard msg.type == "gemini",
                  let timestamp = msg.timestamp,
                  let date = DateParser.parse(timestamp),
                  date >= startDate && date < endDate,
                  let tokens = msg.tokens else { return }

            let input = tokens.input ?? 0
            let output = (tokens.output ?? 0) + (tokens.tool ?? 0)
            let cacheRead = tokens.cached ?? 0
            let reasoning = tokens.thoughts ?? 0

            acc.inputTokens += input
            acc.outputTokens += output
            acc.cacheReadTokens += cacheRead
            acc.reasoningTokens += reasoning

            let entryCost: Double
            if let model = msg.model, let price = modelPrice(for: model) {
                entryCost = price.cost(
                    input: input,
                    output: output + reasoning,
                    cacheRead: cacheRead,
                    cacheWrite: 0
                )
                acc.cost += entryCost
            } else {
                entryCost = 0
            }

            if let model = msg.model, !model.isEmpty {
                let totalTokens = input + output + cacheRead + reasoning
                acc.perModel[model, default: PerModelUsage()].totalTokens += totalTokens
                acc.perModel[model, default: PerModelUsage()].cost += entryCost
                acc.perModel[model, default: PerModelUsage()].sources.insert(name)
            }
        }
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
