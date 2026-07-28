import Foundation

// MARK: - Model Price

public struct ModelPrice {
    public let inputPerMillion: Double
    public let outputPerMillion: Double
    public let cacheReadPerMillion: Double
    public let cacheWritePerMillion: Double

    public init(
        inputPerMillion: Double,
        outputPerMillion: Double,
        cacheReadPerMillion: Double,
        cacheWritePerMillion: Double) {
        self.inputPerMillion = inputPerMillion
        self.outputPerMillion = outputPerMillion
        self.cacheReadPerMillion = cacheReadPerMillion
        self.cacheWritePerMillion = cacheWritePerMillion
    }

    public func cost(
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

// MARK: - Model Price Lookup

public struct ModelPriceLookup {
    public enum Match: Equatable {
        case exact(modelId: String)
        case prefix(prefix: String)
        case supplement(modelId: String)
        case missing
    }

    public let modelId: String
    public let price: ModelPrice?
    public let match: Match

    public var isPriced: Bool {
        price != nil
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
    // Claude 5 generation. These are fixed IDs without date suffixes, so they
    // are exact-only (see exactOnlyPricingKeys): a future claude-opus-5-1 or
    // claude-fable-5-mini tier must not silently inherit these rates.
    // Fast mode on claude-opus-5 bills $10/$50 under the same model ID, so
    // fast-mode usage is under-estimated by this table.
    "claude-fable-5": price(10.0, 50.0, 1.00, 12.5),
    "claude-opus-5": price(5.0, 25.0, 0.50, 6.25),
    // Introductory pricing through 2026-08-31 (UTC); the standard rate from
    // 2026-09-01 is applied per usage timestamp via scheduledPriceChanges.
    "claude-sonnet-5": price(2.0, 10.0, 0.20, 2.50),

    // Claude Opus 4 (specific versions)
    "claude-opus-4-8": price(5.0, 25.0, 0.50, 6.25),
    "claude-opus-4-7": price(5.0, 25.0, 0.50, 6.25),
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
    // GPT-5.6 standard short-context pricing.
    "gpt-5.6-sol": price(5.0, 30.0, 0.50, 6.25),
    "gpt-5.6-terra": price(2.50, 15.0, 0.25, 3.125),
    "gpt-5.6-luna": price(1.0, 6.0, 0.10, 1.25),
    "gpt-5.5-pro": price(30.0, 180.0, 0.0),
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

    // Nebius Token Factory self-service pricing does not list a separate cached-input discount,
    // so cache reads/writes are billed at the input rate for this provider path.
    // Both GLM keys are exact-only (see exactOnlyPricingKeys) so -Batch and
    // other variants never fall back to a GLM-5.2 prefix match; Batch is a
    // distinct exact key rather than a priced-down prefix of GLM-5.2.
    "zai-org/GLM-5.2": price(1.40, 4.40, 1.40, 1.40),
    "zai-org/GLM-5.2-Batch": price(0.70, 2.20, 0.70, 0.70),
]

private let exactOnlyPricingKeys: Set = [
    "claude-fable-5",
    "claude-opus-5",
    "claude-sonnet-5",
    "claude-opus-4",
    "gpt-5",
    "gemini-3",
    "grok",
    "grok-code",
    "zai-org/GLM-5.2",
    "zai-org/GLM-5.2-Batch",
]

private let prefixPricingTable: [String: ModelPrice] = exactPricingTable.filter { key, _ in
    !exactOnlyPricingKeys.contains(key)
}

private let sortedPrefixPricingKeys: [(key: String, value: ModelPrice)] =
    prefixPricingTable.sorted { $0.key.count > $1.key.count }

// MARK: - Scheduled Price Changes

private struct ScheduledPriceChange {
    let effectiveFrom: Date
    let price: ModelPrice
}

// claude-sonnet-5 standard pricing replaces the introductory rate at
// 2026-09-01T00:00:00Z. Changes must be sorted by ascending effectiveFrom;
// the base table entry applies before the earliest change.
private let scheduledPriceChanges: [String: [ScheduledPriceChange]] = [
    "claude-sonnet-5": [
        ScheduledPriceChange(
            effectiveFrom: Date(timeIntervalSince1970: 1_788_220_800),
            price: price(3.0, 15.0, 0.30, 3.75)),
    ],
]

private func matchedPricingKey(for match: ModelPriceLookup.Match) -> String? {
    switch match {
    case let .exact(modelId):
        modelId
    case let .prefix(prefix):
        prefix
    case .supplement, .missing:
        nil
    }
}

// MARK: - Lookup

/// Resolves the price effective at the given usage timestamp. Cost
/// computation for usage events must pass the event timestamp so that
/// scheduled price changes bill each event at its own effective rate.
public func modelPriceLookup(for modelId: String, at timestamp: Date) -> ModelPriceLookup {
    let lookup = baseModelPriceLookup(for: modelId, at: timestamp)
    guard let pricingKey = matchedPricingKey(for: lookup.match),
          let change = scheduledPriceChanges[pricingKey]?
          .last(where: { $0.effectiveFrom <= timestamp }) else {
        return lookup
    }
    return ModelPriceLookup(
        modelId: lookup.modelId,
        price: change.price,
        match: lookup.match)
}

/// Resolves the price effective now. Use for presence checks and
/// read-time fallbacks without an event timestamp; per-event costs
/// should use `modelPriceLookup(for:at:)` instead.
public func modelPriceLookup(for modelId: String) -> ModelPriceLookup {
    modelPriceLookup(for: modelId, at: Date())
}

public func modelPrice(for modelId: String, at timestamp: Date) -> ModelPrice? {
    modelPriceLookup(for: modelId, at: timestamp).price
}

public func modelPrice(for modelId: String) -> ModelPrice? {
    modelPriceLookup(for: modelId).price
}

/// Returns whether pricing is available for the complete half-open report
/// interval. Curated prices are timeless; supplemental prices honor catalog
/// additions and removals at their recorded effective timestamps.
public func modelPriceIsKnown(
    for modelId: String,
    throughout interval: DateInterval) -> Bool {
    if exactPricingTable[modelId] != nil
        || sortedPrefixPricingKeys.contains(where: { modelId.hasPrefix($0.key) }) {
        return true
    }
    return ModelPricingSupplement.hasPrice(for: modelId, throughout: interval)
}

private func baseModelPriceLookup(for modelId: String, at timestamp: Date) -> ModelPriceLookup {
    if let price = exactPricingTable[modelId] {
        return ModelPriceLookup(
            modelId: modelId,
            price: price,
            match: .exact(modelId: modelId))
    }

    if let match = sortedPrefixPricingKeys.first(where: { modelId.hasPrefix($0.key) }) {
        return ModelPriceLookup(
            modelId: modelId,
            price: match.value,
            match: .prefix(prefix: match.key))
    }

    if let price = ModelPricingSupplement.price(for: modelId, at: timestamp) {
        return ModelPriceLookup(
            modelId: modelId,
            price: price,
            match: .supplement(modelId: modelId))
    }

    return ModelPriceLookup(
        modelId: modelId,
        price: nil,
        match: .missing)
}
