import XCTest
@testable import Toki

final class UsageFormattingBehaviorTests: XCTestCase {
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
}
