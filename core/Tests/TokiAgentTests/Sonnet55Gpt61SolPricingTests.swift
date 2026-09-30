import Foundation
import XCTest
@testable import TokiUsageReaders

final class Sonnet55Gpt61SolPricingTests: XCTestCase {
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

    func test_sonnet55UsesStandardRatesAndExactMatching() throws {
        let lookup = modelPriceLookup(for: "claude-sonnet-5-5", at: date)
        let price = try XCTUnwrap(lookup.price)

        XCTAssertEqual(lookup.match, .exact(modelId: "claude-sonnet-5-5"))
        XCTAssertEqual(price.inputPerMillion, 2.0)
        XCTAssertEqual(price.outputPerMillion, 10.0)
        XCTAssertEqual(price.cacheReadPerMillion, 0.20)
        XCTAssertEqual(price.cacheWritePerMillion, 2.50)
        XCTAssertEqual(price.cacheWriteOneHourPerMillion, 4.0)
        XCTAssertTrue(modelPriceIsKnown(for: "claude-sonnet-5-5", throughout: interval))
    }

    func test_gpt61SolUsesStandardRatesAndExactMatching() throws {
        let lookup = modelPriceLookup(for: "gpt-6.1-sol", at: date)
        let price = try XCTUnwrap(lookup.price)

        XCTAssertEqual(lookup.match, .exact(modelId: "gpt-6.1-sol"))
        XCTAssertEqual(price.inputPerMillion, 2.0)
        XCTAssertEqual(price.outputPerMillion, 10.0)
        XCTAssertEqual(price.cacheReadPerMillion, 0.10)
        XCTAssertEqual(price.cacheWritePerMillion, 2.50)
        XCTAssertTrue(modelPriceIsKnown(for: "gpt-6.1-sol", throughout: interval))
    }

    func test_derivativesStayUnpriced() {
        let ids = ["-mini", "-preview", "-fast", "-2026-09-28"].flatMap {
            ["claude-sonnet-5-5\($0)", "gpt-6.1-sol\($0)"]
        } + ["kr/claude-sonnet-5-5", "gpt-6.1"]
        for modelID in ids {
            XCTAssertNil(modelPrice(for: modelID, at: date), "\(modelID) must stay unpriced")
            XCTAssertFalse(modelPriceIsKnown(for: modelID, throughout: interval))
        }
    }

    func test_existingSiblingsUnchanged() throws {
        XCTAssertEqual(try XCTUnwrap(modelPrice(for: "gpt-6-sol", at: date)).cacheReadPerMillion, 0.20)
    }
}
