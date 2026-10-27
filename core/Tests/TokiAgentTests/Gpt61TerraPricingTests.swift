import Foundation
import XCTest
@testable import TokiUsageReaders

final class Gpt61TerraPricingTests: XCTestCase {
    private let date = Date(timeIntervalSince1970: 1_790_553_600)
    private lazy var interval = DateInterval(start: date, duration: 86400)

    override func setUp() {
        super.setUp()
        ModelPricingSupplement.install([:])
    }

    override func tearDown() {
        ModelPricingSupplement.install([:])
        super.tearDown()
    }

    func test_gpt61TerraUsesStandardRatesAndExactMatching() throws {
        let lookup = modelPriceLookup(for: "gpt-6.1-terra", at: date)
        let price = try XCTUnwrap(lookup.price)

        XCTAssertEqual(lookup.match, .exact(modelId: "gpt-6.1-terra"))
        XCTAssertTrue(lookup.isPriced)
        XCTAssertEqual(price.inputPerMillion, 1.0)
        XCTAssertEqual(price.outputPerMillion, 5.0)
        XCTAssertEqual(price.cacheReadPerMillion, 0.05)
        XCTAssertEqual(price.cacheWritePerMillion, 1.25)
        XCTAssertTrue(modelPriceIsKnown(for: "gpt-6.1-terra", throughout: interval))
    }

    func test_gpt61TerraCostIncludesEveryStandardTokenBucket() throws {
        let price = try XCTUnwrap(modelPrice(for: "gpt-6.1-terra", at: date))

        XCTAssertEqual(
            price.cost(input: 1000, output: 1000, cacheRead: 1000, cacheWrite: 1000),
            0.0073,
            accuracy: 0.000_001)
    }

    func test_unpublishedTerraVariantsStayUnpriced() {
        for modelID in [
            "gpt-6.1-terra-mini", "gpt-6.1-terra-preview", "gpt-6.1-terra-fast",
            "gpt-6.1-terra-2026-10-27", "gpt-6.1-terra-extra", "gpt-6.1",
        ] {
            XCTAssertEqual(modelPriceLookup(for: modelID, at: date).match, .missing)
            XCTAssertNil(modelPrice(for: modelID, at: date), modelID)
            XCTAssertFalse(modelPriceIsKnown(for: modelID, throughout: interval), modelID)
        }
    }

    func test_supplementCannotOverrideCuratedTerraButCanPriceExplicitVariants() throws {
        let supplement = ModelPrice(
            inputPerMillion: 99, outputPerMillion: 99, cacheReadPerMillion: 99, cacheWritePerMillion: 99)
        let variant = "gpt-6.1-terra-preview"
        ModelPricingSupplement.install(["gpt-6.1-terra": supplement, variant: supplement])

        XCTAssertEqual(modelPriceLookup(for: "gpt-6.1-terra", at: date).match, .exact(modelId: "gpt-6.1-terra"))
        XCTAssertEqual(try XCTUnwrap(modelPrice(for: "gpt-6.1-terra", at: date)).inputPerMillion, 1.0)
        XCTAssertEqual(modelPriceLookup(for: variant, at: date).match, .supplement(modelId: variant))
        XCTAssertEqual(try XCTUnwrap(modelPrice(for: variant, at: date)).inputPerMillion, 99)
    }
}
