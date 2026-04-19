import XCTest
@testable import Toki

final class UsageFormattingBehaviorTests: XCTestCase {
    func test_formattedTokens_promotesRoundedBoundaryToNextSuffix() {
        XCTAssertEqual(999_950.formattedTokens(), "1.0M")
        XCTAssertEqual(999_950_000.formattedTokens(), "1.0B")
    }
}
