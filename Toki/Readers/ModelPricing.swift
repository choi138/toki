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
    "claude-opus-4-5-thinking-high": ModelPrice(inputPerMillion: 15.0, outputPerMillion: 75.0, cacheReadPerMillion: 1.50, cacheWritePerMillion: 18.75),
    "claude-opus-4-6": ModelPrice(inputPerMillion: 15.0, outputPerMillion: 75.0, cacheReadPerMillion: 1.50, cacheWritePerMillion: 18.75),
    "claude-opus-4-5": ModelPrice(inputPerMillion: 15.0, outputPerMillion: 75.0, cacheReadPerMillion: 1.50, cacheWritePerMillion: 18.75),
    "claude-opus-4": ModelPrice(inputPerMillion: 15.0, outputPerMillion: 75.0, cacheReadPerMillion: 1.50, cacheWritePerMillion: 18.75),
    // Claude Sonnet 4 (specific versions)
    "claude-sonnet-4-5-thinking-medium": ModelPrice(inputPerMillion: 3.0, outputPerMillion: 15.0, cacheReadPerMillion: 0.30, cacheWritePerMillion: 3.75),
    "claude-sonnet-4-6": ModelPrice(inputPerMillion: 3.0, outputPerMillion: 15.0, cacheReadPerMillion: 0.30, cacheWritePerMillion: 3.75),
    "claude-sonnet-4-5": ModelPrice(inputPerMillion: 3.0, outputPerMillion: 15.0, cacheReadPerMillion: 0.30, cacheWritePerMillion: 3.75),
    "claude-sonnet-4": ModelPrice(inputPerMillion: 3.0, outputPerMillion: 15.0, cacheReadPerMillion: 0.30, cacheWritePerMillion: 3.75),
    // Claude Haiku 4
    "claude-haiku-4-5": ModelPrice(inputPerMillion: 0.80, outputPerMillion: 4.0, cacheReadPerMillion: 0.08, cacheWritePerMillion: 1.00),
    "claude-haiku-4": ModelPrice(inputPerMillion: 0.80, outputPerMillion: 4.0, cacheReadPerMillion: 0.08, cacheWritePerMillion: 1.00),
    // OpenAI
    "gpt-5.4": ModelPrice(inputPerMillion: 10.0, outputPerMillion: 40.0, cacheReadPerMillion: 5.0, cacheWritePerMillion: 0.0),
    "gpt-5.2-pro": ModelPrice(inputPerMillion: 10.0, outputPerMillion: 40.0, cacheReadPerMillion: 5.0, cacheWritePerMillion: 0.0),
    "gpt-5": ModelPrice(inputPerMillion: 10.0, outputPerMillion: 40.0, cacheReadPerMillion: 5.0, cacheWritePerMillion: 0.0),
    // Google Gemini (estimates)
    "gemini-3-pro-high": ModelPrice(inputPerMillion: 2.0, outputPerMillion: 8.0, cacheReadPerMillion: 0.5, cacheWritePerMillion: 0.0),
    "gemini-3-flash": ModelPrice(inputPerMillion: 0.10, outputPerMillion: 0.40, cacheReadPerMillion: 0.025, cacheWritePerMillion: 0.0),
    "gemini-3": ModelPrice(inputPerMillion: 1.0, outputPerMillion: 4.0, cacheReadPerMillion: 0.25, cacheWritePerMillion: 0.0),
    // xAI Grok (estimate)
    "grok-code": ModelPrice(inputPerMillion: 3.0, outputPerMillion: 15.0, cacheReadPerMillion: 0.30, cacheWritePerMillion: 0.0),
    "grok": ModelPrice(inputPerMillion: 3.0, outputPerMillion: 15.0, cacheReadPerMillion: 0.30, cacheWritePerMillion: 0.0)
]

// Pre-sorted once at startup — longest key first so most specific prefix wins
private let sortedPricingKeys: [(key: String, value: ModelPrice)] =
    pricingTable.sorted { $0.key.count > $1.key.count }

func modelPrice(for modelId: String) -> ModelPrice? {
    if let price = pricingTable[modelId] { return price }
    return sortedPricingKeys.first { modelId.hasPrefix($0.key) }?.value
}
