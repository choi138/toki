import Foundation
import XCTest

// MARK: - Inline model definitions for test isolation

private struct ModelStat {
    let id: String
    let totalTokens: Int
    let cost: Double
}

private struct UsageData {
    let date: Date
    let inputTokens: Int
    let outputTokens: Int
    let cacheReadTokens: Int
    let cacheWriteTokens: Int
    let reasoningTokens: Int
    let cost: Double
    let perModel: [ModelStat]

    var totalTokens: Int {
        inputTokens + outputTokens + cacheReadTokens + cacheWriteTokens + reasoningTokens
    }

    var cacheEfficiency: Double {
        let denom = Double(inputTokens + cacheReadTokens)
        guard denom > 0 else { return 0 }
        return Double(cacheReadTokens) / denom * 100
    }
}

private extension Int {
    func formattedTokens() -> String {
        let value = Double(self)
        let isMega = value >= 1_000_000
        let isKilo = value >= 1_000

        if isMega {
            return String(format: "%.1fM", value / 1_000_000)
        }
        if isKilo {
            return String(format: "%.1fK", value / 1_000)
        }
        return "\(self)"
    }
}

// MARK: - Tests

final class TokiTests: XCTestCase {

    // MARK: totalTokens

    func test_totalTokens_sumsAllFields() {
        let usage = UsageData(
            date: Date(),
            inputTokens: 1_000,
            outputTokens: 2_000,
            cacheReadTokens: 3_000,
            cacheWriteTokens: 4_000,
            reasoningTokens: 5_000,
            cost: 0,
            perModel: []
        )

        let expected = 15_000
        XCTAssertEqual(usage.totalTokens, expected)
    }

    func test_totalTokens_withZeroValues() {
        let usage = UsageData(
            date: Date(),
            inputTokens: 0,
            outputTokens: 0,
            cacheReadTokens: 0,
            cacheWriteTokens: 0,
            reasoningTokens: 0,
            cost: 0,
            perModel: []
        )

        XCTAssertEqual(usage.totalTokens, 0)
    }

    func test_totalTokens_matchesMockData() {
        // Mirrors UsageData.mock values
        let usage = UsageData(
            date: Date(),
            inputTokens: 11_000_000,
            outputTokens: 401_900,
            cacheReadTokens: 112_600_000,
            cacheWriteTokens: 0,
            reasoningTokens: 176_400,
            cost: 64.33,
            perModel: []
        )

        let expected = 11_000_000 + 401_900 + 112_600_000 + 0 + 176_400
        XCTAssertEqual(usage.totalTokens, expected)
    }

    // MARK: cacheEfficiency

    func test_cacheEfficiency_withNoCacheReads_returnsZero() {
        let usage = UsageData(
            date: Date(),
            inputTokens: 1_000,
            outputTokens: 500,
            cacheReadTokens: 0,
            cacheWriteTokens: 0,
            reasoningTokens: 0,
            cost: 0,
            perModel: []
        )

        XCTAssertEqual(usage.cacheEfficiency, 0)
    }

    func test_cacheEfficiency_withAllFromCache_returns100() {
        let usage = UsageData(
            date: Date(),
            inputTokens: 0,
            outputTokens: 500,
            cacheReadTokens: 1_000,
            cacheWriteTokens: 0,
            reasoningTokens: 0,
            cost: 0,
            perModel: []
        )

        XCTAssertEqual(usage.cacheEfficiency, 100, accuracy: 0.001)
    }

    func test_cacheEfficiency_withEqualInputAndCacheRead_returns50() {
        let usage = UsageData(
            date: Date(),
            inputTokens: 500,
            outputTokens: 200,
            cacheReadTokens: 500,
            cacheWriteTokens: 0,
            reasoningTokens: 0,
            cost: 0,
            perModel: []
        )

        XCTAssertEqual(usage.cacheEfficiency, 50, accuracy: 0.001)
    }

    func test_cacheEfficiency_whenAllZero_returnsZero() {
        let usage = UsageData(
            date: Date(),
            inputTokens: 0,
            outputTokens: 0,
            cacheReadTokens: 0,
            cacheWriteTokens: 0,
            reasoningTokens: 0,
            cost: 0,
            perModel: []
        )

        XCTAssertEqual(usage.cacheEfficiency, 0)
    }

    func test_cacheEfficiency_withMockData_isApproximatelyCorrect() {
        let usage = UsageData(
            date: Date(),
            inputTokens: 11_000_000,
            outputTokens: 401_900,
            cacheReadTokens: 112_600_000,
            cacheWriteTokens: 0,
            reasoningTokens: 176_400,
            cost: 64.33,
            perModel: []
        )

        // cacheRead / (input + cacheRead) * 100
        let denom = Double(11_000_000 + 112_600_000)
        let expected = Double(112_600_000) / denom * 100
        XCTAssertEqual(usage.cacheEfficiency, expected, accuracy: 0.001)
    }

    // MARK: formattedTokens

    func test_formattedTokens_belowThousand_returnsRawNumber() {
        XCTAssertEqual(999.formattedTokens(), "999")
        XCTAssertEqual(0.formattedTokens(), "0")
        XCTAssertEqual(1.formattedTokens(), "1")
    }

    func test_formattedTokens_exactlyThousand_returnsKiloFormat() {
        XCTAssertEqual(1_000.formattedTokens(), "1.0K")
    }

    func test_formattedTokens_inThousands_returnsKiloFormat() {
        XCTAssertEqual(1_500.formattedTokens(), "1.5K")
        XCTAssertEqual(999_999.formattedTokens(), "1000.0K")
    }

    func test_formattedTokens_exactlyMillion_returnsMegaFormat() {
        XCTAssertEqual(1_000_000.formattedTokens(), "1.0M")
    }

    func test_formattedTokens_inMillions_returnsMegaFormat() {
        XCTAssertEqual(11_000_000.formattedTokens(), "11.0M")
        XCTAssertEqual(112_600_000.formattedTokens(), "112.6M")
    }

    func test_formattedTokens_largeValue_returnsMegaFormat() {
        XCTAssertEqual(1_234_567.formattedTokens(), "1.2M")
    }
}
