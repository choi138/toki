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
            "claude-fable-5-1": ModelPrice(
                inputPerMillion: 10.0,
                outputPerMillion: 50.0,
                cacheReadPerMillion: 0.25,
                cacheWritePerMillion: 12.5),
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

        let fable51 = try XCTUnwrap(modelPrice(for: "claude-fable-5-1"))
        XCTAssertEqual(fable51.cacheWriteOneHourPerMillion, 20.0, accuracy: 0.0001)
    }

    func test_modelPrice_calculatesClaude5CostWithCacheRates() throws {
        let expectedCosts: [(modelID: String, cost: Double)] = [
            ("claude-fable-5-1", 72.75),
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

    func test_claudeCodeReader_pricesFable51CacheWritesByTTL() {
        let usage = ClaudeCodeReader.usage(
            fromJSONLLines: [
                """
                {"type":"assistant","timestamp":"2026-07-28T00:00:00Z","requestId":"req-1",\
                "message":{"id":"msg-1","model":"claude-fable-5-1","usage":{\
                "input_tokens":0,"output_tokens":0,"cache_read_input_tokens":0,\
                "cache_creation_input_tokens":2000000,"cache_creation":{\
                "ephemeral_5m_input_tokens":1000000,"ephemeral_1h_input_tokens":1000000}}}}
                """,
            ],
            streamID: "fable-5-1-cache-write-test",
            from: Self.claude5IntroductoryDate,
            to: Self.claude5IntroductoryDate.addingTimeInterval(3600))

        XCTAssertEqual(usage.cacheWriteTokens, 2_000_000)
        XCTAssertEqual(usage.cost, 32.5, accuracy: 0.0001)
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
        for modelID in ["claude-fable-5-1", "claude-fable-5", "claude-opus-5", "gpt-5.5"] {
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
        XCTAssertNil(modelPrice(for: "claude-fable-5-1-preview"))
        XCTAssertNil(modelPrice(for: "claude-opus-5-1"))
        XCTAssertNil(modelPrice(for: "claude-opus-5-mini"))
        XCTAssertNil(modelPrice(for: "claude-sonnet-5-1"))
    }

    func test_modelPrice_matchesKoreaRoutedClaudeOpus5() throws {
        // kr/claude-opus-5 is the model ID reported by the custom billing
        // provider and bills at the same rates as claude-opus-5. It is a
        // distinct catalog entry rather than a provider prefix, so it carries
        // its own exact key instead of inheriting through a stripping rule.
        let lookup = modelPriceLookup(for: "kr/claude-opus-5", at: Self.claude5IntroductoryDate)
        let price = try XCTUnwrap(lookup.price)
        let base = try XCTUnwrap(modelPrice(for: "claude-opus-5", at: Self.claude5IntroductoryDate))

        XCTAssertEqual(lookup.match, .exact(modelId: "kr/claude-opus-5"))
        XCTAssertEqual(price.inputPerMillion, base.inputPerMillion, accuracy: 0.0001)
        XCTAssertEqual(price.outputPerMillion, base.outputPerMillion, accuracy: 0.0001)
        XCTAssertEqual(price.cacheReadPerMillion, base.cacheReadPerMillion, accuracy: 0.0001)
        XCTAssertEqual(price.cacheWritePerMillion, base.cacheWritePerMillion, accuracy: 0.0001)
    }

    func test_modelPriceIsKnown_reportsKoreaRoutedClaudeOpus5AsPriced() {
        let interval = DateInterval(start: Self.claude5IntroductoryDate, duration: 86400)

        XCTAssertTrue(modelPriceIsKnown(for: "kr/claude-opus-5", throughout: interval))
    }

    func test_modelPrice_treatsKoreaRoutedClaudeOpus5AsExactOnly() {
        // The kr/ entry must not become a prefix that lends its rates to
        // future tiers, matching how claude-opus-5 itself is exact-only.
        XCTAssertNil(modelPrice(for: "kr/claude-opus-5-1"))
        XCTAssertNil(modelPrice(for: "kr/claude-opus-5-mini"))
        // Other kr/-reported models stay unpriced until their own rates are known.
        XCTAssertNil(modelPrice(for: "kr/claude-fable-5"))
        XCTAssertNil(modelPrice(for: "kr/gpt-5.6-sol"))
    }

    func test_modelPrice_keepsSlashBearingModelKeysIndependent() throws {
        // zai-org/ is part of the model ID, not a provider prefix. Adding a
        // slash-bearing key must not turn the segment before the slash into
        // something strippable.
        XCTAssertNotNil(try XCTUnwrap(modelPrice(for: "zai-org/GLM-5.2")))
        XCTAssertNotNil(try XCTUnwrap(modelPrice(for: "zai-org/GLM-5.2-Batch")))
        XCTAssertNil(modelPrice(for: "GLM-5.2"))
        XCTAssertNil(modelPrice(for: "claude-opus-5-1"))
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
