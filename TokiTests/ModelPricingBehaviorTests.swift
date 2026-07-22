import XCTest
@testable import Toki
@testable import TokiUsageReaders

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

    func test_modelPrice_matchesGpt56Models() throws {
        let expectedPrices: [String: ModelPrice] = [
            "gpt-5.6-sol": ModelPrice(
                inputPerMillion: 5.0,
                outputPerMillion: 30.0,
                cacheReadPerMillion: 0.50,
                cacheWritePerMillion: 6.25),
            "gpt-5.6-terra": ModelPrice(
                inputPerMillion: 2.50,
                outputPerMillion: 15.0,
                cacheReadPerMillion: 0.25,
                cacheWritePerMillion: 3.125),
            "gpt-5.6-luna": ModelPrice(
                inputPerMillion: 1.0,
                outputPerMillion: 6.0,
                cacheReadPerMillion: 0.10,
                cacheWritePerMillion: 1.25),
        ]

        for (modelID, expected) in expectedPrices {
            let price = try XCTUnwrap(modelPrice(for: modelID))

            XCTAssertEqual(price.inputPerMillion, expected.inputPerMillion, accuracy: 0.0001)
            XCTAssertEqual(price.outputPerMillion, expected.outputPerMillion, accuracy: 0.0001)
            XCTAssertEqual(price.cacheReadPerMillion, expected.cacheReadPerMillion, accuracy: 0.0001)
            XCTAssertEqual(price.cacheWritePerMillion, expected.cacheWritePerMillion, accuracy: 0.0001)
        }
    }

    func test_modelPriceLookup_matchesGpt56SnapshotPrefixes() {
        let expectedPrefixes = [
            "gpt-5.6-sol": "gpt-5.6-sol-2026-07-10",
            "gpt-5.6-terra": "gpt-5.6-terra-2026-07-10",
            "gpt-5.6-luna": "gpt-5.6-luna-2026-07-10",
        ]

        for (prefix, modelID) in expectedPrefixes {
            let lookup = modelPriceLookup(for: modelID)

            XCTAssertEqual(lookup.match, .prefix(prefix: prefix))
            XCTAssertTrue(lookup.isPriced)
        }
    }

    func test_modelPrice_calculatesGpt56CostWithCacheRates() throws {
        let expectedCosts: [(modelID: String, cost: Double)] = [
            ("gpt-5.6-sol", 41.75),
            ("gpt-5.6-terra", 20.875),
            ("gpt-5.6-luna", 8.35),
        ]

        for expected in expectedCosts {
            let price = try XCTUnwrap(modelPrice(for: expected.modelID))
            let cost = price.cost(
                input: 1_000_000,
                output: 1_000_000,
                cacheRead: 1_000_000,
                cacheWrite: 1_000_000)

            XCTAssertEqual(cost, expected.cost, accuracy: 0.0001)
        }
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
        XCTAssertNil(modelPrice(for: "zai-org/GLM-5.2-Experimental"))
        XCTAssertNil(modelPrice(for: "zai-org/GLM-5.2-Batch-Experimental"))
    }

    func test_modelPrice_treatsGlm52AsExactOnly() {
        // zai-org/GLM-5.2 is exact-only: an unrecognized variant must not
        // match the GLM-5.2 key as a prefix (otherwise -Batch style suffixes
        // would silently pick up the non-batch price).
        XCTAssertNil(modelPrice(for: "zai-org/GLM-5.2-Other"))
        XCTAssertNil(modelPrice(for: "zai-org/GLM-5.2-preview"))
    }
}
