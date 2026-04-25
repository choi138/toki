import XCTest
@testable import Toki

final class ModelPricingBehaviorTests: XCTestCase {
    func test_modelPrice_matchesGpt55Aliases() throws {
        let gpt55 = modelPrice(for: "gpt-5.5")
        XCTAssertNotNil(gpt55)
        XCTAssertEqual(try XCTUnwrap(gpt55?.inputPerMillion), 5.0, accuracy: 0.0001)
        XCTAssertEqual(try XCTUnwrap(gpt55?.outputPerMillion), 30.0, accuracy: 0.0001)
        XCTAssertEqual(try XCTUnwrap(gpt55?.cacheReadPerMillion), 0.50, accuracy: 0.0001)

        let gpt55Snapshot = modelPrice(for: "gpt-5.5-2026-04-23")
        XCTAssertNotNil(gpt55Snapshot)
        XCTAssertEqual(try XCTUnwrap(gpt55Snapshot?.inputPerMillion), 5.0, accuracy: 0.0001)
        XCTAssertEqual(try XCTUnwrap(gpt55Snapshot?.outputPerMillion), 30.0, accuracy: 0.0001)
        XCTAssertEqual(try XCTUnwrap(gpt55Snapshot?.cacheReadPerMillion), 0.50, accuracy: 0.0001)

        let gpt55Pro = modelPrice(for: "gpt-5.5-pro")
        XCTAssertNotNil(gpt55Pro)
        XCTAssertEqual(try XCTUnwrap(gpt55Pro?.inputPerMillion), 30.0, accuracy: 0.0001)
        XCTAssertEqual(try XCTUnwrap(gpt55Pro?.outputPerMillion), 180.0, accuracy: 0.0001)
        XCTAssertEqual(try XCTUnwrap(gpt55Pro?.cacheReadPerMillion), 30.0, accuracy: 0.0001)
    }

    func test_modelPrice_doesNotFallbackFromBroadBaseKeysToUnknownVariants() {
        XCTAssertNil(modelPrice(for: "claude-opus-4-7"))
        XCTAssertNil(modelPrice(for: "gpt-5-experimental"))
        XCTAssertNil(modelPrice(for: "gemini-3-ultra"))
    }
}
