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
}
