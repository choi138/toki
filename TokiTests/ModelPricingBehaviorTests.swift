import XCTest
@testable import Toki

final class ModelPricingBehaviorTests: XCTestCase {
    func test_modelPriceLookup_reportsExactMatch() throws {
        let lookup = modelPriceLookup(for: "gpt-5.5")
        let price = try XCTUnwrap(lookup.price)

        XCTAssertEqual(lookup.modelId, "gpt-5.5")
        XCTAssertEqual(lookup.match, .exact(modelId: "gpt-5.5"))
        XCTAssertTrue(lookup.isPriced)
        XCTAssertEqual(price.inputPerMillion, 5.0, accuracy: 0.0001)
        XCTAssertEqual(price.outputPerMillion, 30.0, accuracy: 0.0001)
        XCTAssertEqual(price.cacheReadPerMillion, 0.50, accuracy: 0.0001)
    }

    func test_modelPriceLookup_reportsPrefixMatch() throws {
        let lookup = modelPriceLookup(for: "gpt-5.5-2026-04-23")
        let price = try XCTUnwrap(lookup.price)

        XCTAssertEqual(lookup.modelId, "gpt-5.5-2026-04-23")
        XCTAssertEqual(lookup.match, .prefix(prefix: "gpt-5.5"))
        XCTAssertTrue(lookup.isPriced)
        XCTAssertEqual(price.inputPerMillion, 5.0, accuracy: 0.0001)
        XCTAssertEqual(price.outputPerMillion, 30.0, accuracy: 0.0001)
        XCTAssertEqual(price.cacheReadPerMillion, 0.50, accuracy: 0.0001)
    }

    func test_modelPriceLookup_reportsMissingForUnpricedModels() {
        for modelId in ["gpt-5-experimental", "unknown-model"] {
            let lookup = modelPriceLookup(for: modelId)

            XCTAssertEqual(lookup.modelId, modelId)
            XCTAssertEqual(lookup.match, .missing)
            XCTAssertFalse(lookup.isPriced)
            XCTAssertNil(lookup.price)
        }
    }

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

    func test_modelPrice_matchesNebiusGlm52() throws {
        let glm52 = try XCTUnwrap(modelPrice(for: "zai-org/GLM-5.2"))
        XCTAssertEqual(glm52.inputPerMillion, 1.40, accuracy: 0.0001)
        XCTAssertEqual(glm52.outputPerMillion, 4.40, accuracy: 0.0001)
        XCTAssertEqual(glm52.cacheReadPerMillion, 1.40, accuracy: 0.0001)
        XCTAssertEqual(glm52.cacheWritePerMillion, 1.40, accuracy: 0.0001)

        let glm52Batch = try XCTUnwrap(modelPrice(for: "zai-org/GLM-5.2-Batch"))
        XCTAssertEqual(glm52Batch.inputPerMillion, 0.70, accuracy: 0.0001)
        XCTAssertEqual(glm52Batch.outputPerMillion, 2.20, accuracy: 0.0001)
        XCTAssertEqual(glm52Batch.cacheReadPerMillion, 0.70, accuracy: 0.0001)
        XCTAssertEqual(glm52Batch.cacheWritePerMillion, 0.70, accuracy: 0.0001)
    }

    func test_modelPrice_doesNotFallbackFromBroadBaseKeysToUnknownVariants() {
        XCTAssertNil(modelPrice(for: "claude-opus-4-7"))
        XCTAssertNil(modelPrice(for: "gpt-5-experimental"))
        XCTAssertNil(modelPrice(for: "gemini-3-ultra"))
        XCTAssertNil(modelPrice(for: "zai-org/GLM-5.2-Batch-Experimental"))
    }
}
