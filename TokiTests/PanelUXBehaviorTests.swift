import XCTest
@testable import Toki

final class PanelUXBehaviorTests: XCTestCase {
    func test_menuBarUsageSummary_formatsTitleAndToolTip() {
        let summary = MenuBarUsageSummary(
            totalTokens: 1_234_000,
            cost: 4.2,
            hasUnpricedUsage: false)

        XCTAssertEqual(menuBarUsageSummaryTitle(for: summary), 4.2.formattedCost())
        let toolTip = menuBarUsageToolTip(for: summary)
        XCTAssertTrue(toolTip.hasPrefix("Toki — Today: "))
        XCTAssertTrue(toolTip.contains(1_234_000.formattedTokens()))
        XCTAssertTrue(toolTip.contains(4.2.formattedCost()))
        XCTAssertTrue(toolTip.contains("Estimated cost"))
        XCTAssertFalse(toolTip.contains("excludes unpriced usage"))
    }

    func test_menuBarUsageSummary_marksIncompleteCostWhenUsageIsUnpriced() {
        let summary = MenuBarUsageSummary(
            totalTokens: 1_234_000,
            cost: 4.2,
            hasUnpricedUsage: true)

        XCTAssertEqual(menuBarUsageSummaryTitle(for: summary), "~\(4.2.formattedCost())")
        XCTAssertTrue(menuBarUsageToolTip(for: summary).contains("excludes unpriced usage"))
    }

    func test_menuBarUsageContainsUnpricedModels_ignoresEmptyModels() {
        let priced = makeModel(id: "priced", totalTokens: 10, isPriceKnown: true)
        let emptyUnpriced = makeModel(id: "empty", totalTokens: 0, isPriceKnown: false)
        let usedUnpriced = makeModel(id: "unpriced", totalTokens: 10, isPriceKnown: false)

        XCTAssertFalse(menuBarUsageContainsUnpricedModels([priced, emptyUnpriced]))
        XCTAssertTrue(menuBarUsageContainsUnpricedModels([priced, usedUnpriced]))
    }

    func test_readerFailureNames_returnsOnlyFailedReaders() {
        let statuses = [
            ReaderStatus(
                name: "Claude Code",
                state: .failed,
                message: "boom",
                lastReadAt: nil,
                totalTokens: 0,
                isOriginPartitioned: false),
            ReaderStatus(
                name: "Codex",
                state: .loaded,
                message: nil,
                lastReadAt: nil,
                totalTokens: 10,
                isOriginPartitioned: false),
            ReaderStatus(
                name: "Hermes",
                state: .disabled,
                message: nil,
                lastReadAt: nil,
                totalTokens: 0,
                isOriginPartitioned: false),
            ReaderStatus(
                name: "Cursor",
                state: .failed,
                message: nil,
                lastReadAt: nil,
                totalTokens: 0,
                isOriginPartitioned: false),
        ]

        XCTAssertEqual(readerFailureNames(from: statuses), ["Claude Code", "Cursor"])
        XCTAssertEqual(readerFailureNames(from: []), [])
    }

    private func makeModel(id: String, totalTokens: Int, isPriceKnown: Bool) -> ModelStat {
        ModelStat(
            id: id,
            totalTokens: totalTokens,
            cost: 0,
            activeSeconds: 0,
            sources: ["Test"],
            isPriceKnown: isPriceKnown)
    }
}
