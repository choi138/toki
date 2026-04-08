import XCTest
@testable import Toki

final class TokiTests: XCTestCase {

    // MARK: - formattedTokens

    func test_formattedTokens_belowThousand() {
        XCTAssertEqual(0.formattedTokens(),   "0")
        XCTAssertEqual(1.formattedTokens(),   "1")
        XCTAssertEqual(999.formattedTokens(), "999")
    }

    func test_formattedTokens_thousands() {
        XCTAssertEqual(1_000.formattedTokens(),   "1.0K")
        XCTAssertEqual(1_500.formattedTokens(),   "1.5K")
        XCTAssertEqual(10_000.formattedTokens(),  "10.0K")
        XCTAssertEqual(999_999.formattedTokens(), "1000.0K")
    }

    func test_formattedTokens_millions() {
        XCTAssertEqual(1_000_000.formattedTokens(),   "1.0M")
        XCTAssertEqual(1_230_000.formattedTokens(),   "1.23M")
        XCTAssertEqual(11_000_000.formattedTokens(),  "11.0M")
        XCTAssertEqual(112_600_000.formattedTokens(), "112.6M")
    }

    func test_formattedTokens_billions() {
        XCTAssertEqual(1_000_000_000.formattedTokens(),   "1.0B")
        XCTAssertEqual(3_560_000_000.formattedTokens(),   "3.56B")
        XCTAssertEqual(10_000_000_000.formattedTokens(),  "10.0B")
    }

    // MARK: - formattedCost

    func test_formattedCost_small() {
        XCTAssertEqual(0.0.formattedCost(),  "$0.00")
        XCTAssertEqual(1.5.formattedCost(),  "$1.50")
        XCTAssertEqual(9.99.formattedCost(), "$9.99")
    }

    func test_formattedCost_medium() {
        XCTAssertEqual(10.0.formattedCost(),  "$10.0")
        XCTAssertEqual(99.9.formattedCost(),  "$99.9")
        XCTAssertEqual(100.0.formattedCost(), "$100")
        XCTAssertEqual(289.0.formattedCost(), "$289")
    }

    func test_formattedCost_large() {
        XCTAssertEqual(1_000.0.formattedCost(), "$1.0K")
        XCTAssertEqual(1_234.5.formattedCost(), "$1.2K")
    }

    // MARK: - cacheEfficiency

    func test_cacheEfficiency_zero() {
        let usage = UsageData(
            date: Date(),
            inputTokens: 1_000, outputTokens: 500,
            cacheReadTokens: 0, cacheWriteTokens: 0,
            reasoningTokens: 0, cost: 0, perModel: []
        )
        XCTAssertEqual(usage.cacheEfficiency, 0)
    }

    func test_cacheEfficiency_full() {
        let usage = UsageData(
            date: Date(),
            inputTokens: 0, outputTokens: 500,
            cacheReadTokens: 1_000, cacheWriteTokens: 0,
            reasoningTokens: 0, cost: 0, perModel: []
        )
        XCTAssertEqual(usage.cacheEfficiency, 100, accuracy: 0.001)
    }

    func test_cacheEfficiency_half() {
        let usage = UsageData(
            date: Date(),
            inputTokens: 500, outputTokens: 200,
            cacheReadTokens: 500, cacheWriteTokens: 0,
            reasoningTokens: 0, cost: 0, perModel: []
        )
        XCTAssertEqual(usage.cacheEfficiency, 50, accuracy: 0.001)
    }

    func test_cacheEfficiency_allZero() {
        let usage = UsageData(
            date: Date(),
            inputTokens: 0, outputTokens: 0,
            cacheReadTokens: 0, cacheWriteTokens: 0,
            reasoningTokens: 0, cost: 0, perModel: []
        )
        XCTAssertEqual(usage.cacheEfficiency, 0)
    }

    // MARK: - totalTokens

    func test_totalTokens_sumsAllFields() {
        let usage = UsageData(
            date: Date(),
            inputTokens: 1_000, outputTokens: 2_000,
            cacheReadTokens: 3_000, cacheWriteTokens: 4_000,
            reasoningTokens: 5_000, cost: 0, perModel: []
        )
        XCTAssertEqual(usage.totalTokens, 15_000)
    }

    func test_totalTokens_zero() {
        let usage = UsageData(
            date: Date(),
            inputTokens: 0, outputTokens: 0,
            cacheReadTokens: 0, cacheWriteTokens: 0,
            reasoningTokens: 0, cost: 0, perModel: []
        )
        XCTAssertEqual(usage.totalTokens, 0)
    }
}
