import XCTest
@testable import Toki

final class ModelPricingBehaviorTests: XCTestCase {
    func test_modelPrice_matchesGpt55Aliases() throws {
        let gpt55 = try XCTUnwrap(modelPrice(for: "gpt-5.5"))
        XCTAssertEqual(gpt55.inputPerMillion, 5.0, accuracy: 0.0001)
        XCTAssertEqual(gpt55.outputPerMillion, 30.0, accuracy: 0.0001)
        XCTAssertEqual(gpt55.cacheReadPerMillion, 0.50, accuracy: 0.0001)

        let gpt55Snapshot = try XCTUnwrap(modelPrice(for: "gpt-5.5-2026-04-23"))
        XCTAssertEqual(gpt55Snapshot.inputPerMillion, 5.0, accuracy: 0.0001)
        XCTAssertEqual(gpt55Snapshot.outputPerMillion, 30.0, accuracy: 0.0001)
        XCTAssertEqual(gpt55Snapshot.cacheReadPerMillion, 0.50, accuracy: 0.0001)

        let gpt55Pro = try XCTUnwrap(modelPrice(for: "gpt-5.5-pro"))
        XCTAssertEqual(gpt55Pro.inputPerMillion, 30.0, accuracy: 0.0001)
        XCTAssertEqual(gpt55Pro.outputPerMillion, 180.0, accuracy: 0.0001)
        XCTAssertEqual(gpt55Pro.cacheReadPerMillion, 0.0, accuracy: 0.0001)
    }

    func test_modelPrice_doesNotFallbackFromBroadBaseKeysToUnknownVariants() {
        XCTAssertNil(modelPrice(for: "claude-opus-4-7"))
        XCTAssertNil(modelPrice(for: "gpt-5-experimental"))
        XCTAssertNil(modelPrice(for: "gemini-3-ultra"))
    }
}
