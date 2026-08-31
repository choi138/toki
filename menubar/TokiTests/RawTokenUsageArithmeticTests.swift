import TokiUsageCore
import XCTest

final class RawTokenUsageArithmeticTests: XCTestCase {
    func test_mergeSaturatesPositiveOverflowAndNegativeUnderflowAtTheirRespectiveBounds() {
        var positive = RawTokenUsage(inputTokens: Int.max)
        positive += RawTokenUsage(inputTokens: 1)

        var negative = RawTokenUsage(inputTokens: Int.min)
        negative += RawTokenUsage(inputTokens: -1)

        XCTAssertEqual(positive.inputTokens, Int.max)
        XCTAssertEqual(negative.inputTokens, Int.min)
    }

    func test_recordTokenEventRejectsCountersAboveTheSafeReportingLimit() {
        var usage = RawTokenUsage()
        XCTAssertNil(usage.accumulateTokenCounts(input: Int.max, output: 0))
        for second in 0..<2 {
            usage.recordTokenEvent(
                timestamp: Date(timeIntervalSince1970: TimeInterval(second)),
                source: "fixture",
                model: nil,
                inputTokens: Int.max,
                outputTokens: 0)
        }

        XCTAssertEqual(usage.inputTokens, 0)
        XCTAssertTrue(usage.tokenEvents.isEmpty)
    }
}
