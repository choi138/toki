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

        // Pre-filter by startDate via findFiles, then check endDate cheaply
        let files = findFiles(in: chatsBaseURL, withExtension: "json", modifiedAfter: startDate)
        let decoder = JSONDecoder()

        return files.reduce(into: RawTokenUsage()) { acc, file in
            guard let fileDate = (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate,
                  fileDate < endDate else { return }

            guard let data = try? Data(contentsOf: file) else { return }

            // Single-pass: try array first, fall back to single object
            let messages: [GeminiMessage]
            if let array = try? decoder.decode([GeminiMessage].self, from: data) {
                messages = array
            } else {
                messages = (try? decoder.decode(GeminiMessage.self, from: data)).map { [$0] } ?? []
            }

            messages.forEach { msg in
                guard let meta = msg.usageMetadata else { return }
                acc.inputTokens += meta.promptTokenCount ?? 0
                acc.outputTokens += meta.candidatesTokenCount ?? 0
                acc.cacheReadTokens += meta.cachedContentTokenCount ?? 0
            }
        }
    }
}

// MARK: - Private Types

private struct GeminiMessage: Decodable {
    let usageMetadata: UsageMetadata?

    struct UsageMetadata: Decodable {
        let promptTokenCount: Int?
        let candidatesTokenCount: Int?
        let totalTokenCount: Int?
        let cachedContentTokenCount: Int?
    }
}
