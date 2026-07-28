import XCTest
@testable import Toki

final class PanelUXBehaviorTests: XCTestCase {
    func test_menuBarUsageSummary_formatsTitleAndToolTip() {
        let summary = MenuBarUsageSummary(totalTokens: 1_234_000, cost: 4.2)

        XCTAssertEqual(menuBarUsageSummaryTitle(for: summary), 4.2.formattedCost())
        let toolTip = menuBarUsageToolTip(for: summary)
        XCTAssertTrue(toolTip.hasPrefix("Toki — Today: "))
        XCTAssertTrue(toolTip.contains(1_234_000.formattedTokens()))
        XCTAssertTrue(toolTip.contains(4.2.formattedCost()))
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
}
