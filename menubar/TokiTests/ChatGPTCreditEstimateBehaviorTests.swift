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
}
