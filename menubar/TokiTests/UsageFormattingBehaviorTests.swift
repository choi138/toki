import TokiUsageCore
import XCTest
@testable import Toki

final class UsageFormattingBehaviorTests: XCTestCase {
    func test_chatGPTUsageEstimateWeightsModelTokenTypesAndFastMode() {
        let event = TokenUsageEvent(
            timestamp: Date(timeIntervalSince1970: 0),
            source: "Codex",
            model: "gpt-5.6-terra",
            serviceTier: "priority",
            inputTokens: 20000,
            outputTokens: 60000,
            cacheReadTokens: 10000,
            cacheWriteTokens: 0,
            reasoningTokens: 10000,
            cost: 0)

        let estimate = chatGPTUsageEstimate(from: [event])

        XCTAssertEqual(estimate.credits, 55.125, accuracy: 0.000_001)
        XCTAssertEqual(estimate.creditsPerMillionTokens, 551.25, accuracy: 0.000_001)
        XCTAssertEqual(estimate.pricedTokens, 100_000)
        XCTAssertTrue(estimate.isComplete)
    }

    func test_chatGPTUsageEstimateExcludesUnknownModelsAndNonCodexSources() {
        let unknownCodex = TokenUsageEvent(
            timestamp: Date(timeIntervalSince1970: 0),
            source: "Codex",
            model: "unknown-model",
            inputTokens: 100,
            outputTokens: 0,
            cacheReadTokens: 0,
            cacheWriteTokens: 0,
            reasoningTokens: 0,
            cost: 0)
        let otherSource = TokenUsageEvent(
            timestamp: Date(timeIntervalSince1970: 0),
            source: "Claude Code",
            model: "gpt-5.6-terra",
            inputTokens: 200,
            outputTokens: 0,
            cacheReadTokens: 0,
            cacheWriteTokens: 0,
            reasoningTokens: 0,
            cost: 0)

        let estimate = chatGPTUsageEstimate(from: [unknownCodex, otherSource])

        XCTAssertEqual(estimate.pricedTokens, 0)
        XCTAssertEqual(estimate.unpricedTokens, 100)
        XCTAssertFalse(estimate.hasPricedUsage)
        XCTAssertFalse(estimate.isComplete)
    }

    func test_chatGPTUsageEstimatePricesLegacyCodexModels() {
        for model in ["gpt-5.3-codex", "gpt-5.2", "gpt-5.2-codex"] {
            let event = TokenUsageEvent(
                timestamp: Date(timeIntervalSince1970: 0),
                source: "Codex",
                model: model,
                serviceTier: "priority",
                inputTokens: 1_000_000,
                outputTokens: 1_000_000,
                cacheReadTokens: 1_000_000,
                cacheWriteTokens: 0,
                reasoningTokens: 0,
                cost: 0)

            let estimate = chatGPTUsageEstimate(from: [event])

            XCTAssertEqual(estimate.credits, 398.125, accuracy: 0.000_001, model)
            XCTAssertEqual(estimate.pricedTokens, 3_000_000, model)
            XCTAssertTrue(estimate.isComplete, model)
        }
    }

    func test_chatGPTUsageEstimateDoesNotApplyStandardRatesToGpt52Pro() {
        let event = TokenUsageEvent(
            timestamp: Date(timeIntervalSince1970: 0),
            source: "Codex",
            model: "gpt-5.2-pro",
            inputTokens: 1_000_000,
            outputTokens: 0,
            cacheReadTokens: 0,
            cacheWriteTokens: 0,
            reasoningTokens: 0,
            cost: 0)

        let estimate = chatGPTUsageEstimate(from: [event])

        XCTAssertFalse(estimate.hasPricedUsage)
        XCTAssertEqual(estimate.unpricedTokens, 1_000_000)
    }

    func test_formattedTokens_promotesRoundedBoundaryToNextSuffix() {
        XCTAssertEqual(999_950.formattedTokens(), "1.0M")
        XCTAssertEqual(999_950_000.formattedTokens(), "1.0B")
    }

    func test_formattedTokensPerSecond() {
        XCTAssertEqual(0.0.formattedTokensPerSecond(), "0 token/s")
        XCTAssertEqual((-1.0).formattedTokensPerSecond(), "0 token/s")
        XCTAssertEqual(4.25.formattedTokensPerSecond(), "4.3 token/s")
        XCTAssertEqual(9.96.formattedTokensPerSecond(), "10 token/s")
        XCTAssertEqual(42.3.formattedTokensPerSecond(), "42 token/s")
    }

    func test_periodOutputTokensPerSecond_usesOutputTokensOverWorkTime() {
        let usage = UsageData(
            date: Date(),
            inputTokens: 1000,
            outputTokens: 7200,
            cacheReadTokens: 50000,
            cacheWriteTokens: 0,
            reasoningTokens: 300,
            cost: 0,
            activeSeconds: 360,
            workTime: WorkTimeMetrics(
                agentSeconds: 360,
                wallClockSeconds: 240,
                activeStreamCount: 2,
                maxConcurrentStreams: 2),
            perModel: [])

        XCTAssertEqual(usage.periodOutputTokensPerSecond, 30, accuracy: 0.000_001)
    }

    func test_periodOutputTokensPerSecond_zeroWithoutWorkTime() {
        let usage = UsageData(
            date: Date(),
            inputTokens: 0,
            outputTokens: 7200,
            cacheReadTokens: 0,
            cacheWriteTokens: 0,
            reasoningTokens: 0,
            cost: 0,
            activeSeconds: 0,
            workTime: .zero,
            perModel: [])

        XCTAssertEqual(usage.periodOutputTokensPerSecond, 0)
    }

    func test_modelStatPanelTimeSummaryShowsActiveTimeOnlyForUnpricedModel() {
        let stat = ModelStat(
            id: "codex-auto-review",
            totalTokens: 4_790_000,
            cost: 0,
            activeSeconds: TimeInterval((2 * 60 + 5) * 60),
            sources: ["GJC"],
            isPriceKnown: false)

        XCTAssertEqual(stat.panelTimeSummary, "2h 5m used")
    }

    func test_modelStatPanelTimeSummaryShowsZeroWhenNoActiveTime() {
        let stat = ModelStat(
            id: "codex-auto-review",
            totalTokens: 4_790_000,
            cost: 0,
            activeSeconds: 0,
            sources: ["GJC"],
            isPriceKnown: false)

        XCTAssertEqual(stat.panelTimeSummary, "0s used")
    }

    func test_modelStatPanelCostSummaryShowsUnpricedForUnknownPrice() {
        let stat = ModelStat(
            id: "codex-auto-review",
            totalTokens: 4_790_000,
            cost: 0,
            activeSeconds: TimeInterval((2 * 60 + 5) * 60),
            sources: ["GJC"],
            isPriceKnown: false)

        XCTAssertEqual(stat.panelCostSummary, "unpriced")
    }

    func test_modelStatPanelCostSummaryShowsZeroForKnownPrice() {
        let stat = ModelStat(
            id: "gpt-5.4",
            totalTokens: 100,
            cost: 0,
            activeSeconds: 0,
            sources: ["GJC"],
            isPriceKnown: true)

        XCTAssertEqual(stat.panelCostSummary, "$0.00")
        XCTAssertTrue(stat.hasKnownPanelCost)
    }

    func test_unknownCostEventDoesNotContributeInventedCost() throws {
        let timestamp = Date(timeIntervalSince1970: 1_765_756_800)
        var usage = RawTokenUsage()
        usage.recordTokenEvent(
            timestamp: timestamp,
            source: "Kimi CLI",
            model: "gpt-5.4",
            inputTokens: 1,
            outputTokens: 0,
            cost: 42,
            costIsKnown: false)

        let stat = try XCTUnwrap(UsageReportBuilder.buildModelStats(
            from: usage,
            startDate: timestamp.addingTimeInterval(-1),
            endDate: timestamp.addingTimeInterval(1)).first)

        XCTAssertEqual(stat.cost, 0)
        XCTAssertFalse(stat.isPriceKnown)
    }

    func test_knownZeroCostPreservesKnownPriceForUnpricedModel() throws {
        let timestamp = Date(timeIntervalSince1970: 1_765_756_800)
        var usage = RawTokenUsage()
        usage.recordTokenEvent(
            timestamp: timestamp,
            source: "Kimi CLI",
            model: "custom-free-model",
            inputTokens: 1,
            outputTokens: 0,
            cost: 0,
            costIsKnown: true)

        let stat = try XCTUnwrap(UsageReportBuilder.buildModelStats(
            from: usage,
            startDate: timestamp.addingTimeInterval(-1),
            endDate: timestamp.addingTimeInterval(1)).first)

        XCTAssertEqual(stat.cost, 0)
        XCTAssertTrue(stat.isPriceKnown)
    }
}

extension UsageFormattingBehaviorTests {
    func test_chatGPTUsageEstimateTreatsCacheWriteTokensAsUnpriced() {
        let mixedEvent = TokenUsageEvent(
            timestamp: Date(timeIntervalSince1970: 0),
            source: "Codex",
            model: "gpt-5.6-terra",
            inputTokens: 1_000_000,
            outputTokens: 0,
            cacheReadTokens: 0,
            cacheWriteTokens: 2_000_000,
            reasoningTokens: 0,
            cost: 0)
        let cacheWriteOnlyEvent = TokenUsageEvent(
            timestamp: Date(timeIntervalSince1970: 0),
            source: "Codex",
            model: "gpt-5.6-terra",
            inputTokens: 0,
            outputTokens: 0,
            cacheReadTokens: 0,
            cacheWriteTokens: 2_000_000,
            reasoningTokens: 0,
            cost: 0)

        let mixedEstimate = chatGPTUsageEstimate(from: [mixedEvent])
        let cacheWriteOnlyEstimate = chatGPTUsageEstimate(from: [cacheWriteOnlyEvent])

        XCTAssertEqual(mixedEstimate.credits, 50, accuracy: 0.000_001)
        XCTAssertEqual(mixedEstimate.creditsPerMillionTokens, 50, accuracy: 0.000_001)
        XCTAssertEqual(mixedEstimate.pricedTokens, 1_000_000)
        XCTAssertEqual(mixedEstimate.unpricedTokens, 2_000_000)
        XCTAssertFalse(mixedEstimate.isComplete)
        XCTAssertFalse(cacheWriteOnlyEstimate.hasPricedUsage)
        XCTAssertEqual(cacheWriteOnlyEstimate.unpricedTokens, 2_000_000)
    }

    func test_chatGPTUsageEstimateDoesNotApplyStandardRatesToGpt55Pro() {
        let event = TokenUsageEvent(
            timestamp: Date(timeIntervalSince1970: 0),
            source: "Codex",
            model: "gpt-5.5-pro",
            inputTokens: 1_000_000,
            outputTokens: 0,
            cacheReadTokens: 0,
            cacheWriteTokens: 0,
            reasoningTokens: 0,
            cost: 0)

        let estimate = chatGPTUsageEstimate(from: [event])

        XCTAssertFalse(estimate.hasPricedUsage)
        XCTAssertEqual(estimate.unpricedTokens, 1_000_000)
    }
}
