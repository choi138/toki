import XCTest
@testable import Toki

final class PanelHeroComparisonContentTests: XCTestCase {
    func test_noUsageYesterdayUsesTextOnlyNeutralState() throws {
        let content = try XCTUnwrap(PanelHeroComparisonContent.make(
            currentTotal: 120,
            yesterdayTotal: 0))

        XCTAssertNil(content.symbolName)
        XCTAssertEqual(content.text, "No usage yesterday")
    }

    func test_equalTotalsUsesNeutralMinusState() throws {
        let content = try XCTUnwrap(PanelHeroComparisonContent.make(
            currentTotal: 120,
            yesterdayTotal: 120))

        XCTAssertEqual(content.symbolName, Optional("minus"))
        XCTAssertEqual(content.text, "0% from yesterday")
    }

    func test_increasedAndDecreasedTotalsUseDirectionalStates() throws {
        let increased = try XCTUnwrap(PanelHeroComparisonContent.make(
            currentTotal: 150,
            yesterdayTotal: 100))
        let decreased = try XCTUnwrap(PanelHeroComparisonContent.make(
            currentTotal: 50,
            yesterdayTotal: 100))

        XCTAssertEqual(increased.symbolName, Optional("arrow.up"))
        XCTAssertEqual(increased.text, "50% from yesterday")
        XCTAssertEqual(decreased.symbolName, Optional("arrow.down"))
        XCTAssertEqual(decreased.text, "50% from yesterday")
    }
}
