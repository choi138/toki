import XCTest
@testable import Toki
@testable import TokiUsageReaders

final class Claude5ModelPricingBehaviorTests: XCTestCase {
    // 2026-07-28T00:00:00Z — inside the claude-sonnet-5 introductory window.
    private static let claude5IntroductoryDate = Date(timeIntervalSince1970: 1_785_196_800)
    // 2026-08-31T23:59:59Z — the last instant of the introductory window.
    private static let sonnet5LastIntroductoryDate = Date(timeIntervalSince1970: 1_788_220_799)
    // 2026-09-01T00:00:00Z — the first instant of standard pricing.
    private static let sonnet5StandardPricingStart = Date(timeIntervalSince1970: 1_788_220_800)

    func test_modelPrice_matchesClaude5Models() throws {
        let expectedPrices: [String: ModelPrice] = [
            "claude-fable-5": ModelPrice(
                inputPerMillion: 10.0,
                outputPerMillion: 50.0,
                cacheReadPerMillion: 1.00,
                cacheWritePerMillion: 12.5),
            "claude-opus-5": ModelPrice(
                inputPerMillion: 5.0,
                outputPerMillion: 25.0,
                cacheReadPerMillion: 0.50,
                cacheWritePerMillion: 6.25),
            "claude-sonnet-5": ModelPrice(
                inputPerMillion: 2.0,
                outputPerMillion: 10.0,
                cacheReadPerMillion: 0.20,
                cacheWritePerMillion: 2.50),
        ]

        for (modelID, expected) in expectedPrices {
            let lookup = modelPriceLookup(for: modelID, at: Self.claude5IntroductoryDate)
            let price = try XCTUnwrap(lookup.price)

            XCTAssertEqual(lookup.match, .exact(modelId: modelID))
            XCTAssertEqual(price.inputPerMillion, expected.inputPerMillion, accuracy: 0.0001)
            XCTAssertEqual(price.outputPerMillion, expected.outputPerMillion, accuracy: 0.0001)
            XCTAssertEqual(price.cacheReadPerMillion, expected.cacheReadPerMillion, accuracy: 0.0001)
            XCTAssertEqual(price.cacheWritePerMillion, expected.cacheWritePerMillion, accuracy: 0.0001)
        }
    }

    func test_modelPrice_calculatesClaude5CostWithCacheRates() throws {
        let expectedCosts: [(modelID: String, cost: Double)] = [
            ("claude-fable-5", 73.5),
            ("claude-opus-5", 36.75),
            ("claude-sonnet-5", 14.7),
        ]

        for expected in expectedCosts {
            let price = try XCTUnwrap(modelPrice(for: expected.modelID, at: Self.claude5IntroductoryDate))
            let cost = price.cost(
                input: 1_000_000,
                output: 1_000_000,
                cacheRead: 1_000_000,
                cacheWrite: 1_000_000)

            XCTAssertEqual(cost, expected.cost, accuracy: 0.0001)
        }
    }

    func test_modelPrice_selectsSonnet5RateByUsageTimestamp() throws {
        let intro = try XCTUnwrap(modelPrice(for: "claude-sonnet-5", at: Self.sonnet5LastIntroductoryDate))
        XCTAssertEqual(intro.inputPerMillion, 2.0, accuracy: 0.0001)
        XCTAssertEqual(intro.outputPerMillion, 10.0, accuracy: 0.0001)
        XCTAssertEqual(intro.cacheReadPerMillion, 0.20, accuracy: 0.0001)
        XCTAssertEqual(intro.cacheWritePerMillion, 2.50, accuracy: 0.0001)

        let standard = try XCTUnwrap(modelPrice(for: "claude-sonnet-5", at: Self.sonnet5StandardPricingStart))
        XCTAssertEqual(standard.inputPerMillion, 3.0, accuracy: 0.0001)
        XCTAssertEqual(standard.outputPerMillion, 15.0, accuracy: 0.0001)
        XCTAssertEqual(standard.cacheReadPerMillion, 0.30, accuracy: 0.0001)
        XCTAssertEqual(standard.cacheWritePerMillion, 3.75, accuracy: 0.0001)

        let standardLookup = modelPriceLookup(for: "claude-sonnet-5", at: Self.sonnet5StandardPricingStart)
        XCTAssertEqual(standardLookup.match, .exact(modelId: "claude-sonnet-5"))
    }

    func test_modelPrice_keepsUnscheduledModelsConstantAcrossTimestamps() throws {
        for modelID in ["claude-fable-5", "claude-opus-5", "gpt-5.5"] {
            let before = try XCTUnwrap(modelPrice(for: modelID, at: Self.sonnet5LastIntroductoryDate))
            let after = try XCTUnwrap(modelPrice(for: modelID, at: Self.sonnet5StandardPricingStart))

            XCTAssertEqual(before.inputPerMillion, after.inputPerMillion, accuracy: 0.0001)
            XCTAssertEqual(before.outputPerMillion, after.outputPerMillion, accuracy: 0.0001)
            XCTAssertEqual(before.cacheReadPerMillion, after.cacheReadPerMillion, accuracy: 0.0001)
            XCTAssertEqual(before.cacheWritePerMillion, after.cacheWritePerMillion, accuracy: 0.0001)
        }
    }

    func test_modelPrice_treatsClaude5KeysAsExactOnly() {
        // Claude 5 model IDs are fixed and carry no date suffixes, so the keys
        // are exact-only: a future tier such as claude-opus-5-1 or a suffixed
        // variant must stay unpriced instead of inheriting these rates.
        XCTAssertNil(modelPrice(for: "claude-fable-5-preview"))
        XCTAssertNil(modelPrice(for: "claude-opus-5-1"))
        XCTAssertNil(modelPrice(for: "claude-opus-5-mini"))
        XCTAssertNil(modelPrice(for: "claude-sonnet-5-1"))
    }

    func test_modelPrice_matchesClaudeOpus47And48() throws {
        for modelID in ["claude-opus-4-7", "claude-opus-4-8"] {
            let price = try XCTUnwrap(modelPrice(for: modelID))

            XCTAssertEqual(price.inputPerMillion, 5.0, accuracy: 0.0001)
            XCTAssertEqual(price.outputPerMillion, 25.0, accuracy: 0.0001)
            XCTAssertEqual(price.cacheReadPerMillion, 0.50, accuracy: 0.0001)
            XCTAssertEqual(price.cacheWritePerMillion, 6.25, accuracy: 0.0001)
        }
    }
}
