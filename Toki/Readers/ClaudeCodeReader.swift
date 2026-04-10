import Foundation

// Reads ~/.claude/projects/**/*.jsonl
// Deduplicates by requestId, keeps max token counts per message
struct ClaudeCodeReader: TokenReader {
    let name = "Claude Code"

    func readUsage(from startDate: Date, to endDate: Date) async throws -> RawTokenUsage {
        let projectsURL = homeDir().appendingPathComponent(".claude/projects")
        guard FileManager.default.fileExists(atPath: projectsURL.path) else {
            return RawTokenUsage()
        }

        let files = findFiles(in: projectsURL, withExtension: "jsonl", modifiedAfter: startDate)
        let decoder = JSONDecoder()

        // requestId → entry (dedup, keep max)
        var dedup: [String: Entry] = [:]

        files.forEach { file in
            readJSONLLines(at: file).forEach { line in
                guard let data = line.data(using: .utf8),
                      let msg = try? decoder.decode(RawMessage.self, from: data),
                      msg.type == "assistant",
                      let tsStr = msg.timestamp,
                      let date = DateParser.parse(tsStr),
                      date >= startDate && date < endDate,
                      let usage = msg.message?.usage else { return }

                let key = msg.requestId ?? msg.message?.id ?? UUID().uuidString
                let entry = Entry(
                    model: msg.message?.model,
                    input: usage.inputTokens ?? 0,
                    output: usage.outputTokens ?? 0,
                    cacheRead: usage.cacheReadInputTokens ?? 0,
                    cacheWrite: usage.cacheCreationInputTokens ?? 0
                )

                if let existing = dedup[key] {
                    dedup[key] = existing.mergedMax(with: entry)
                } else {
                    dedup[key] = entry
                }
            }
        }

        return dedup.values.reduce(into: RawTokenUsage()) { acc, entry in
            acc.inputTokens += entry.input
            acc.outputTokens += entry.output
            acc.cacheReadTokens += entry.cacheRead
            acc.cacheWriteTokens += entry.cacheWrite

            let entryCost: Double
            if let price = modelPrice(for: entry.model ?? "") {
                entryCost = price.cost(
                    input: entry.input,
                    output: entry.output,
                    cacheRead: entry.cacheRead,
                    cacheWrite: entry.cacheWrite
                )
                acc.cost += entryCost
            } else {
                entryCost = 0
            }

            let modelKey = entry.model ?? ""
            let isValidModel = !modelKey.isEmpty && modelKey != "<synthetic>"
            if isValidModel {
                let entryTokens = entry.input + entry.output + entry.cacheRead + entry.cacheWrite
                acc.perModel[modelKey, default: PerModelUsage()].totalTokens += entryTokens
                acc.perModel[modelKey, default: PerModelUsage()].cost += entryCost
            }
        }
    }
}

// MARK: - Private Types

private struct Entry {
    let model: String?
    let input, output, cacheRead, cacheWrite: Int

    func mergedMax(with other: Entry) -> Entry {
        Entry(
            model: model ?? other.model,
            input: max(input, other.input),
            output: max(output, other.output),
            cacheRead: max(cacheRead, other.cacheRead),
            cacheWrite: max(cacheWrite, other.cacheWrite)
        )
    }
}

private struct RawMessage: Decodable {
    let type: String?
    let timestamp: String?
    let requestId: String?
    let message: Message?

    struct Message: Decodable {
        let id: String?
        let model: String?
        let usage: Usage?

        struct Usage: Decodable {
            let inputTokens: Int?
            let outputTokens: Int?
            let cacheReadInputTokens: Int?
            let cacheCreationInputTokens: Int?

            enum CodingKeys: String, CodingKey {
                case inputTokens = "input_tokens"
                case outputTokens = "output_tokens"
                case cacheReadInputTokens = "cache_read_input_tokens"
                case cacheCreationInputTokens = "cache_creation_input_tokens"
            }
        }
    }
}
