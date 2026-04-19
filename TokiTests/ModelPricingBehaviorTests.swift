import XCTest
@testable import Toki

final class ModelPricingBehaviorTests: XCTestCase {
    func test_modelPrice_doesNotFallbackFromBroadBaseKeysToUnknownVariants() {
        XCTAssertNil(modelPrice(for: "claude-opus-4-7"))
        XCTAssertNil(modelPrice(for: "gpt-5-experimental"))
        XCTAssertNil(modelPrice(for: "gemini-3-ultra"))
    }
}
