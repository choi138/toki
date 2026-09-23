import Foundation
import TokiUsageCore
import TokiUsageReaders

struct ChatGPTCreditRate: Equatable {
    let input: Double
    let cachedInput: Double
    let output: Double
    let fastMultiplier: Double
}

func chatGPTUsageEstimate(from events: [TokenUsageEvent]) -> ChatGPTUsageEstimate {
    var credits = 0.0
    var pricedTokens = 0
    var unpricedTokens = 0

    for event in events where isCodexUsageSource(event.source) {
        guard let model = event.model,
              let rate = chatGPTCreditRate(for: model, at: event.timestamp) else {
            unpricedTokens += event.totalTokens
            continue
        }

        let baseCredits = (
            Double(event.inputTokens) * rate.input
                + Double(event.cacheReadTokens) * rate.cachedInput
                + Double(event.outputTokens + event.reasoningTokens) * rate.output) / 1_000_000
        let multiplier = chatGPTFastServiceTiers.contains(event.serviceTier?.lowercased() ?? "")
            ? rate.fastMultiplier
            : 1
        credits += baseCredits * multiplier
        pricedTokens += event.totalTokens - event.cacheWriteTokens
        unpricedTokens += event.cacheWriteTokens
    }

    return ChatGPTUsageEstimate(
        credits: credits,
        pricedTokens: pricedTokens,
        unpricedTokens: unpricedTokens)
}

/// Resolves the ChatGPT credit rate effective at the given usage timestamp, so
/// events recorded before a rate cut keep the rate they were actually billed at.
func chatGPTCreditRate(for model: String, at timestamp: Date) -> ChatGPTCreditRate? {
    guard let key = chatGPTCreditRateKey(for: model),
          let baseRate = chatGPTBaseCreditRates[key] else {
        return nil
    }
    return scheduledChatGPTCreditRateChanges[key]?
        .last(where: { $0.effectiveFrom <= timestamp })?
        .rate ?? baseRate
}

private func isCodexUsageSource(_ source: String) -> Bool {
    source == "Codex" || source.hasPrefix("Codex · ")
}

private let chatGPTFastServiceTiers: Set = ["fast", "priority"]

private func chatGPTCreditRateKey(for model: String) -> String? {
    let modelID = model.lowercased()
    if modelID.hasPrefix("gpt-5.5-pro") || modelID.hasPrefix("gpt-5.2-pro") {
        return nil
    }
    if modelID == "gpt-5.6" {
        return "gpt-5.6-sol"
    }
    return chatGPTCreditRateKeysLongestFirst.first { modelIDMatchesPricingPrefix(modelID, prefix: $0) }
}

/// Longest prefix wins so gpt-5.4-mini is not captured by gpt-5.4.
private let chatGPTCreditRateKeysLongestFirst = chatGPTBaseCreditRates.keys
    .sorted { $0.count > $1.count }

/// Credits per 1M tokens from the ChatGPT rate card. One credit is $0.04, so each
/// entry is the model's standard API price × 25. Fast mode multiplies the whole
/// event; GPT-5.3-Codex and GPT-5.2 have no Fast tier.
/// https://learn.chatgpt.com/docs/pricing
/// https://learn.chatgpt.com/docs/agent-configuration/speed
///
/// GPT-5.6 entries are the launch rates. OpenAI cut them after launch, so the
/// reduced rates live in scheduledChatGPTCreditRateChanges and usage recorded
/// before each cut still bills at the launch rate.
private let chatGPTBaseCreditRates: [String: ChatGPTCreditRate] = [
    "gpt-6-astra": ChatGPTCreditRate(input: 250, cachedInput: 25, output: 1250, fastMultiplier: 2.5),
    "gpt-6-sol": ChatGPTCreditRate(input: 50, cachedInput: 5, output: 250, fastMultiplier: 2.5),
    "gpt-6-luna": ChatGPTCreditRate(input: 2.5, cachedInput: 0.25, output: 12.5, fastMultiplier: 2.5),
    "gpt-5.6-sol": ChatGPTCreditRate(input: 125, cachedInput: 12.5, output: 750, fastMultiplier: 2.5),
    "gpt-5.6-terra": ChatGPTCreditRate(input: 62.5, cachedInput: 6.25, output: 375, fastMultiplier: 2.5),
    "gpt-5.6-luna": ChatGPTCreditRate(input: 25, cachedInput: 2.5, output: 150, fastMultiplier: 2.5),
    "gpt-5.5": ChatGPTCreditRate(input: 125, cachedInput: 12.5, output: 750, fastMultiplier: 2.5),
    "gpt-5.4-mini": ChatGPTCreditRate(input: 18.75, cachedInput: 1.875, output: 113, fastMultiplier: 2),
    "gpt-5.4": ChatGPTCreditRate(input: 62.5, cachedInput: 6.25, output: 375, fastMultiplier: 2),
    "gpt-5.3-codex": ChatGPTCreditRate(input: 43.75, cachedInput: 4.375, output: 350, fastMultiplier: 1),
    "gpt-5.2": ChatGPTCreditRate(input: 43.75, cachedInput: 4.375, output: 350, fastMultiplier: 1),
]

private struct ScheduledChatGPTCreditRateChange {
    let effectiveFrom: Date
    let rate: ChatGPTCreditRate
}

/// Changes must be sorted by ascending effectiveFrom; the base entry applies
/// before the earliest change. The cut dates match ModelPricing: Terra and Luna
/// at 2026-07-30T00:00:00Z, Sol alone at 2026-08-21T00:00:00Z. Sol's reduced
/// rate is promotional through at least 2026-11-21 with no published successor,
/// so no revert is scheduled.
private let scheduledChatGPTCreditRateChanges: [String: [ScheduledChatGPTCreditRateChange]] = [
    "gpt-5.6-sol": [
        ScheduledChatGPTCreditRateChange(
            effectiveFrom: Date(timeIntervalSince1970: 1_787_270_400),
            rate: ChatGPTCreditRate(input: 100, cachedInput: 10, output: 500, fastMultiplier: 2.5)),
    ],
    "gpt-5.6-terra": [
        ScheduledChatGPTCreditRateChange(
            effectiveFrom: Date(timeIntervalSince1970: 1_785_369_600),
            rate: ChatGPTCreditRate(input: 50, cachedInput: 5, output: 300, fastMultiplier: 2.5)),
    ],
    "gpt-5.6-luna": [
        ScheduledChatGPTCreditRateChange(
            effectiveFrom: Date(timeIntervalSince1970: 1_785_369_600),
            rate: ChatGPTCreditRate(input: 5, cachedInput: 0.5, output: 30, fastMultiplier: 2.5)),
    ],
]
