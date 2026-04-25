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
        cacheWrite: Int) -> Double {
        let million = 1_000_000.0
        let inputCost = Double(input) * inputPerMillion
        let outputCost = Double(output) * outputPerMillion
        let cacheReadCost = Double(cacheRead) * cacheReadPerMillion
        let cacheWriteCost = Double(cacheWrite) * cacheWritePerMillion
        return (inputCost + outputCost + cacheReadCost + cacheWriteCost) / million
    }
}

// MARK: - Pricing Table

private func price(
    _ input: Double,
    _ output: Double,
    _ cacheRead: Double,
    _ cacheWrite: Double = 0) -> ModelPrice {
    ModelPrice(
        inputPerMillion: input,
        outputPerMillion: output,
        cacheReadPerMillion: cacheRead,
        cacheWritePerMillion: cacheWrite)
}

private let exactPricingTable: [String: ModelPrice] = [
    // Claude Opus 4 (specific versions)
    "claude-opus-4-5-thinking-high": price(5.0, 25.0, 0.50, 6.25),
    "claude-opus-4-6": price(5.0, 25.0, 0.50, 6.25),
    "claude-opus-4-5": price(5.0, 25.0, 0.50, 6.25),
    "claude-opus-4": price(15.0, 75.0, 1.50, 18.75),

    // Claude Sonnet 4 (specific versions)
    "claude-sonnet-4-5-thinking-medium": price(3.0, 15.0, 0.30, 3.75),
    "claude-sonnet-4-6": price(3.0, 15.0, 0.30, 3.75),
    "claude-sonnet-4-5": price(3.0, 15.0, 0.30, 3.75),
    "claude-sonnet-4": price(3.0, 15.0, 0.30, 3.75),

    // Claude Haiku 4
    "claude-haiku-4-5": price(1.0, 5.0, 0.10, 1.25),
    "claude-haiku-4": price(1.0, 5.0, 0.10, 1.25),

    // OpenAI
    "gpt-5.5-pro": price(30.0, 180.0, 30.0),
    "gpt-5.5": price(5.0, 30.0, 0.50),
    "gpt-5.4": price(2.50, 15.0, 0.25),
    "gpt-5.4-mini": price(0.75, 4.50, 0.075),
    "gpt-5.3-codex": price(1.75, 14.0, 0.175),
    "gpt-5.2": price(1.75, 14.0, 0.175),
    "gpt-5.2-codex": price(1.75, 14.0, 0.175),
    "gpt-5.1-codex-mini": price(0.25, 2.0, 0.025),
    "gpt-5.1-codex-max": price(1.25, 10.0, 0.125),
    "gpt-5.1-codex": price(1.25, 10.0, 0.125),
    "gpt-5-codex": price(1.25, 10.0, 0.125),
    "codex-mini-latest": price(1.50, 6.0, 0.375),
    "gpt-5.2-pro": price(21.0, 168.0, 0.0),
    "gpt-5": price(1.25, 10.0, 0.125),
    // Cursor aliases
    "claude-4.5-sonnet-thinking": price(3.0, 15.0, 0.30, 3.75),
    "claude-4.5-sonnet": price(3.0, 15.0, 0.30, 3.75),

    // Google Gemini
    "gemini-3-pro-high": price(2.0, 12.0, 0.20),
    "gemini-3-flash": price(0.50, 3.0, 0.05),

    // Generic Gemini fallback remains an approximation for internal IDs that
    // don't map cleanly to a public SKU.
    "gemini-3": price(1.25, 10.0, 0.125),

    // xAI Grok
    "grok-code-fast-1": price(0.20, 1.50, 0.02),
    "grok-code": price(0.20, 1.50, 0.02),
    "grok": price(3.0, 15.0, 0.30),
]

private let exactOnlyPricingKeys: Set = [
    "claude-opus-4",
    "gpt-5",
    "gemini-3",
    "grok",
    "grok-code",
]

private let prefixPricingTable: [String: ModelPrice] = exactPricingTable.filter { key, _ in
    !exactOnlyPricingKeys.contains(key)
}

private let sortedPrefixPricingKeys: [(key: String, value: ModelPrice)] =
    prefixPricingTable.sorted { $0.key.count > $1.key.count }

func modelPrice(for modelId: String) -> ModelPrice? {
    if let price = exactPricingTable[modelId] {
        return price
    }
    return sortedPrefixPricingKeys.first { modelId.hasPrefix($0.key) }?.value
}
