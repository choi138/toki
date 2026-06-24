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
}
