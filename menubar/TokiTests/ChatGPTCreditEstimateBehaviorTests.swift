import TokiUsageCore
import XCTest
@testable import Toki

final class ChatGPTCreditEstimateBehaviorTests: XCTestCase {
    private let terraLunaCut = Date(timeIntervalSince1970: 1_785_369_600)
    private let solCut = Date(timeIntervalSince1970: 1_787_270_400)

    func test_solBillsLaunchRateUntilItsOwnCut() {
        let launch = ChatGPTCreditRate(input: 125, cachedInput: 12.5, output: 750, fastMultiplier: 2.5)
        let reduced = ChatGPTCreditRate(input: 100, cachedInput: 10, output: 500, fastMultiplier: 2.5)

        XCTAssertEqual(chatGPTCreditRate(for: "gpt-5.6-sol", at: terraLunaCut), launch)
        XCTAssertEqual(chatGPTCreditRate(for: "gpt-5.6-sol", at: solCut.addingTimeInterval(-1)), launch)
        XCTAssertEqual(chatGPTCreditRate(for: "gpt-5.6-sol", at: solCut), reduced)
        XCTAssertEqual(chatGPTCreditRate(for: "gpt-5.6", at: solCut), reduced)
    }

    func test_terraAndLunaBillLaunchRateBeforeTheirCut() {
        XCTAssertEqual(
            chatGPTCreditRate(for: "gpt-5.6-terra", at: terraLunaCut.addingTimeInterval(-1)),
            ChatGPTCreditRate(input: 62.5, cachedInput: 6.25, output: 375, fastMultiplier: 2.5))
        XCTAssertEqual(
            chatGPTCreditRate(for: "gpt-5.6-terra", at: terraLunaCut),
            ChatGPTCreditRate(input: 50, cachedInput: 5, output: 300, fastMultiplier: 2.5))
        XCTAssertEqual(
            chatGPTCreditRate(for: "gpt-5.6-luna", at: terraLunaCut.addingTimeInterval(-1)),
            ChatGPTCreditRate(input: 25, cachedInput: 2.5, output: 150, fastMultiplier: 2.5))
        XCTAssertEqual(
            chatGPTCreditRate(for: "gpt-5.6-luna", at: terraLunaCut),
            ChatGPTCreditRate(input: 5, cachedInput: 0.5, output: 30, fastMultiplier: 2.5))
    }

    func test_estimateBillsEachEventAtItsOwnEffectiveRate() {
        let beforeCut = makeSolEvent(at: solCut.addingTimeInterval(-1))
        let afterCut = makeSolEvent(at: solCut)

        let estimate = chatGPTUsageEstimate(from: [beforeCut, afterCut])

        XCTAssertEqual(estimate.credits, 887.5 + 610, accuracy: 0.000_001)
        XCTAssertEqual(estimate.pricedTokens, 6_000_000)
        XCTAssertTrue(estimate.isComplete)
    }

    func test_longestPrefixWinsForMiniVariants() {
        XCTAssertEqual(
            chatGPTCreditRate(for: "gpt-5.4-mini-2026-05-01", at: solCut),
            ChatGPTCreditRate(input: 18.75, cachedInput: 1.875, output: 113, fastMultiplier: 2))
        XCTAssertEqual(
            chatGPTCreditRate(for: "gpt-5.4-2026-05-01", at: solCut),
            ChatGPTCreditRate(input: 62.5, cachedInput: 6.25, output: 375, fastMultiplier: 2))
    }

    func test_astraBillsItsOwnRateWithFastMultiplier() {
        let event = TokenUsageEvent(
            timestamp: solCut,
            source: "Codex",
            model: "gpt-6-astra",
            serviceTier: "fast",
            inputTokens: 1_000_000,
            outputTokens: 500_000,
            cacheReadTokens: 1_000_000,
            cacheWriteTokens: 0,
            reasoningTokens: 500_000,
            cost: 0)

        let estimate = chatGPTUsageEstimate(from: [event])

        XCTAssertEqual(
            chatGPTCreditRate(for: "gpt-6-astra-2026-09-01", at: solCut),
            ChatGPTCreditRate(input: 250, cachedInput: 25, output: 1250, fastMultiplier: 2.5))
        XCTAssertEqual(estimate.credits, (250 + 25 + 1250) * 2.5, accuracy: 0.000_001)
        XCTAssertEqual(estimate.pricedTokens, 3_000_000)
        XCTAssertTrue(estimate.isComplete)
    }

    func test_gpt6SolAndLunaUseStandardAndPriorityCreditRates() {
        let timestamp = solCut
        let events = [
            makeGpt6Event(model: "gpt-6-sol", serviceTier: nil, at: timestamp),
            makeGpt6Event(model: "GPT-6-LUNA-2024-02-29", serviceTier: "priority", at: timestamp),
        ]

        let estimate = chatGPTUsageEstimate(from: events)

        XCTAssertEqual(estimate.credits, 305 + 15.25 * 2.5, accuracy: 0.000_001)
        XCTAssertEqual(estimate.pricedTokens, 6_000_000)
        XCTAssertEqual(estimate.unpricedTokens, 0)
        XCTAssertTrue(estimate.isComplete)
    }

    func test_gpt6InvalidDerivativesAreUnpriced() {
        let invalidSuffixes = [
            "-mini", "-pro", "-preview", "-fast", "-experimental", "junk", " ", "\n",
            "-2024-02-30", "-2023-02-29", "-1900-02-29", "-0000-01-01",
            "-2024-00-01", "-2024-13-01", "-2024-01-00", "-2024-04-31",
            "-２０２４-０２-２９", "-2024-02-29-extra", "-2024-02-29\n",
            "-2024-2-29", "-2024-02-9", "-10000-01-01", "-2024/02/29",
        ]
        let invalidModels = ["gpt-6-astra", "gpt-6-sol", "gpt-6-luna"].flatMap { model in
            invalidSuffixes.map { model + $0 }
        } + ["gpt-6", "gpt-6-pro", "gpt-6-terra"]
        let events = invalidModels.map { makeGpt6Event(model: $0, serviceTier: nil, at: solCut) }

        let estimate = chatGPTUsageEstimate(from: events)

        XCTAssertEqual(estimate.credits, 0)
        XCTAssertEqual(estimate.pricedTokens, 0)
        XCTAssertEqual(estimate.unpricedTokens, invalidModels.count * 3_000_000)
        XCTAssertFalse(estimate.isComplete)
    }

    func test_gpt6SolAndLunaEachSupportStandardFastAndPriority() {
        for (model, standard) in [("gpt-6-sol", 305.0), ("gpt-6-luna", 15.25)] {
            for tier: String? in [nil, "fast", "priority"] {
                let estimate = chatGPTUsageEstimate(from: [makeGpt6Event(model: model, serviceTier: tier, at: solCut)])
                XCTAssertEqual(estimate.credits, standard * (tier == nil ? 1 : 2.5), accuracy: 0.000_001)
                XCTAssertEqual(estimate.pricedTokens, 3_000_000)
                XCTAssertEqual(estimate.unpricedTokens, 0)
                XCTAssertTrue(estimate.isComplete)
            }
        }
    }

    private func makeSolEvent(at timestamp: Date) -> TokenUsageEvent {
        TokenUsageEvent(
            timestamp: timestamp,
            source: "Codex",
            model: "gpt-5.6-sol",
            inputTokens: 1_000_000,
            outputTokens: 1_000_000,
            cacheReadTokens: 1_000_000,
            cacheWriteTokens: 0,
            reasoningTokens: 0,
            cost: 0)
    }

    private func makeGpt6Event(model: String, serviceTier: String?, at timestamp: Date) -> TokenUsageEvent {
        TokenUsageEvent(
            timestamp: timestamp,
            source: "Codex",
            model: model,
            serviceTier: serviceTier,
            inputTokens: 1_000_000,
            outputTokens: 1_000_000,
            cacheReadTokens: 1_000_000,
            cacheWriteTokens: 0,
            reasoningTokens: 0,
            cost: 0)
    }
}
