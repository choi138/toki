import Foundation

// MARK: - Model Price

struct ModelPrice {
    let inputPerMillion: Double
    let outputPerMillion: Double
    let cacheReadPerMillion: Double
    let cacheWritePerMillion: Double

    func cost(
        input: Int,
        output: Int,
        cacheRead: Int,
        cacheWrite: Int
    ) -> Double {
        let m = 1_000_000.0
        let inputCost      = Double(input)      * inputPerMillion
        let outputCost     = Double(output)     * outputPerMillion
        let cacheReadCost  = Double(cacheRead)  * cacheReadPerMillion
        let cacheWriteCost = Double(cacheWrite) * cacheWritePerMillion
        return (inputCost + outputCost + cacheReadCost + cacheWriteCost) / m
    }
}

// MARK: - Pricing Table

private let pricingTable: [String: ModelPrice] = [
    // Claude Opus 4 (specific versions)
    "claude-opus-4-5-thinking-high": ModelPrice(inputPerMillion: 5.0, outputPerMillion: 25.0, cacheReadPerMillion: 0.50, cacheWritePerMillion: 6.25),
    "claude-opus-4-6": ModelPrice(inputPerMillion: 5.0, outputPerMillion: 25.0, cacheReadPerMillion: 0.50, cacheWritePerMillion: 6.25),
    "claude-opus-4-5": ModelPrice(inputPerMillion: 5.0, outputPerMillion: 25.0, cacheReadPerMillion: 0.50, cacheWritePerMillion: 6.25),
    "claude-opus-4": ModelPrice(inputPerMillion: 15.0, outputPerMillion: 75.0, cacheReadPerMillion: 1.50, cacheWritePerMillion: 18.75),
    // Claude Sonnet 4 (specific versions)
    "claude-sonnet-4-5-thinking-medium": ModelPrice(inputPerMillion: 3.0, outputPerMillion: 15.0, cacheReadPerMillion: 0.30, cacheWritePerMillion: 3.75),
    "claude-sonnet-4-6": ModelPrice(inputPerMillion: 3.0, outputPerMillion: 15.0, cacheReadPerMillion: 0.30, cacheWritePerMillion: 3.75),
    "claude-sonnet-4-5": ModelPrice(inputPerMillion: 3.0, outputPerMillion: 15.0, cacheReadPerMillion: 0.30, cacheWritePerMillion: 3.75),
    "claude-sonnet-4": ModelPrice(inputPerMillion: 3.0, outputPerMillion: 15.0, cacheReadPerMillion: 0.30, cacheWritePerMillion: 3.75),
    // Claude Haiku 4
    "claude-haiku-4-5": ModelPrice(inputPerMillion: 1.0, outputPerMillion: 5.0, cacheReadPerMillion: 0.10, cacheWritePerMillion: 1.25),
    "claude-haiku-4": ModelPrice(inputPerMillion: 1.0, outputPerMillion: 5.0, cacheReadPerMillion: 0.10, cacheWritePerMillion: 1.25),
    // OpenAI
    "gpt-5.4": ModelPrice(inputPerMillion: 2.50, outputPerMillion: 15.0, cacheReadPerMillion: 0.25, cacheWritePerMillion: 0.0),
    "gpt-5.4-mini": ModelPrice(inputPerMillion: 0.75, outputPerMillion: 4.50, cacheReadPerMillion: 0.075, cacheWritePerMillion: 0.0),
    "gpt-5.3-codex": ModelPrice(inputPerMillion: 1.75, outputPerMillion: 14.0, cacheReadPerMillion: 0.175, cacheWritePerMillion: 0.0),
    "gpt-5.2-codex": ModelPrice(inputPerMillion: 1.75, outputPerMillion: 14.0, cacheReadPerMillion: 0.175, cacheWritePerMillion: 0.0),
    "gpt-5.1-codex-mini": ModelPrice(inputPerMillion: 0.25, outputPerMillion: 2.0, cacheReadPerMillion: 0.025, cacheWritePerMillion: 0.0),
    "gpt-5.1-codex-max": ModelPrice(inputPerMillion: 1.25, outputPerMillion: 10.0, cacheReadPerMillion: 0.125, cacheWritePerMillion: 0.0),
    "gpt-5.1-codex": ModelPrice(inputPerMillion: 1.25, outputPerMillion: 10.0, cacheReadPerMillion: 0.125, cacheWritePerMillion: 0.0),
    "gpt-5-codex": ModelPrice(inputPerMillion: 1.25, outputPerMillion: 10.0, cacheReadPerMillion: 0.125, cacheWritePerMillion: 0.0),
    "codex-mini-latest": ModelPrice(inputPerMillion: 1.50, outputPerMillion: 6.0, cacheReadPerMillion: 0.375, cacheWritePerMillion: 0.0),
    "gpt-5.2-pro": ModelPrice(inputPerMillion: 21.0, outputPerMillion: 168.0, cacheReadPerMillion: 0.0, cacheWritePerMillion: 0.0),
    "gpt-5": ModelPrice(inputPerMillion: 1.25, outputPerMillion: 10.0, cacheReadPerMillion: 0.125, cacheWritePerMillion: 0.0),
    // Google Gemini
    "gemini-3-pro-high": ModelPrice(inputPerMillion: 2.0, outputPerMillion: 12.0, cacheReadPerMillion: 0.20, cacheWritePerMillion: 0.0),
    "gemini-3-flash": ModelPrice(inputPerMillion: 0.50, outputPerMillion: 3.0, cacheReadPerMillion: 0.05, cacheWritePerMillion: 0.0),
    // Generic Gemini fallback remains an approximation for internal IDs that
    // don't map cleanly to a public SKU.
    "gemini-3": ModelPrice(inputPerMillion: 1.25, outputPerMillion: 10.0, cacheReadPerMillion: 0.125, cacheWritePerMillion: 0.0),
    // xAI Grok
    "grok-code-fast-1": ModelPrice(inputPerMillion: 0.20, outputPerMillion: 1.50, cacheReadPerMillion: 0.02, cacheWritePerMillion: 0.0),
    "grok-code": ModelPrice(inputPerMillion: 0.20, outputPerMillion: 1.50, cacheReadPerMillion: 0.02, cacheWritePerMillion: 0.0),
    "grok": ModelPrice(inputPerMillion: 3.0, outputPerMillion: 15.0, cacheReadPerMillion: 0.30, cacheWritePerMillion: 0.0)
]

// Pre-sorted once at startup — longest key first so most specific prefix wins
private let sortedPricingKeys: [(key: String, value: ModelPrice)] =
    pricingTable.sorted { $0.key.count > $1.key.count }

func modelPrice(for modelId: String) -> ModelPrice? {
    if let price = pricingTable[modelId] { return price }
    return sortedPricingKeys.first { modelId.hasPrefix($0.key) }?.value
}
