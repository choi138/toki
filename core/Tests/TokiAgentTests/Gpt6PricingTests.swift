import Foundation
import XCTest
@testable import TokiUsageReaders

final class Gpt6PricingTests: XCTestCase {
    private let interval = DateInterval(
        start: Date(timeIntervalSince1970: 0),
        duration: 86400)

    func test_gpt6CuratedModelsPriceExactAndCalendarDatedIDs() throws {
        let expectations: [String: ModelPrice] = [
            "gpt-6-astra": ModelPrice(
                inputPerMillion: 10,
                outputPerMillion: 50,
                cacheReadPerMillion: 1,
                cacheWritePerMillion: 12.5),
            "gpt-6-sol": ModelPrice(
                inputPerMillion: 2,
                outputPerMillion: 10,
                cacheReadPerMillion: 0.2,
                cacheWritePerMillion: 2.5),
            "gpt-6-luna": ModelPrice(
                inputPerMillion: 0.1,
                outputPerMillion: 0.5,
                cacheReadPerMillion: 0.01,
                cacheWritePerMillion: 0.125),
        ]

        for (model, expected) in expectations {
            // Synthetic dates exercise matching, not a catalog of released snapshots.
            for modelID in [
                model,
                "\(model)-2024-02-29",
                "\(model)-2000-02-29",
                "\(model)-0001-01-01",
                "\(model)-9999-12-31",
            ] {
                let lookup = modelPriceLookup(for: modelID, at: interval.start)
                let price = try XCTUnwrap(lookup.price, "\(modelID) should be priced")

                XCTAssertEqual(
                    lookup.match,
                    modelID == model ? .exact(modelId: model) : .prefix(prefix: model))
                XCTAssertEqual(price.inputPerMillion, expected.inputPerMillion, accuracy: 0.000_001)
                XCTAssertEqual(price.outputPerMillion, expected.outputPerMillion, accuracy: 0.000_001)
                XCTAssertEqual(price.cacheReadPerMillion, expected.cacheReadPerMillion, accuracy: 0.000_001)
                XCTAssertEqual(price.cacheWritePerMillion, expected.cacheWritePerMillion, accuracy: 0.000_001)
                XCTAssertEqual(price.cacheWriteOneHourPerMillion, expected.cacheWritePerMillion, accuracy: 0.000_001)
                XCTAssertTrue(modelPriceIsKnown(for: modelID, throughout: interval))
            }
        }
    }

    func test_gpt6DoesNotInheritUnknownOrMalformedDerivatives() {
        let invalidSuffixes = [
            "-mini", "-pro", "-preview", "-fast", "-experimental", "junk", " ", "\n",
            "-2024-02-30", "-2023-02-29", "-1900-02-29", "-0000-01-01",
            "-2024-00-01", "-2024-13-01", "-2024-01-00", "-2024-04-31",
            "-２０２４-０２-２９", "-2024-02-29-extra", "-2024-02-29\n",
            "-2024-2-29", "-2024-02-9", "-10000-01-01", "-2024/02/29",
        ]
        let invalidIDs = ["gpt-6-astra", "gpt-6-sol", "gpt-6-luna"].flatMap { model in
            invalidSuffixes.map { model + $0 }
        } + ["gpt-6", "gpt-6-pro", "gpt-6-terra", "GPT-6-SOL"]

        for modelID in invalidIDs {
            XCTAssertNil(modelPrice(for: modelID, at: interval.start), "\(modelID) must not inherit pricing")
            XCTAssertFalse(modelPriceIsKnown(for: modelID, throughout: interval), "\(modelID) must be unpriced")
        }
    }

    func test_gpt6RateCalculatorComponents() throws {
        let expectedCosts = ["gpt-6-astra": 73.5, "gpt-6-sol": 14.7, "gpt-6-luna": 0.735]

        for (modelID, expectedCost) in expectedCosts {
            let price = try XCTUnwrap(modelPrice(for: modelID, at: interval.start))
            XCTAssertEqual(
                price.cost(input: 1_000_000, output: 1_000_000, cacheRead: 1_000_000, cacheWrite: 1_000_000),
                expectedCost,
                accuracy: 0.000_001)
        }
    }

    func test_gpt6SupplementPricesExplicitDerivativesButCannotOverrideCuratedModels() throws {
        defer { ModelPricingSupplement.install([:]) }
        let supplement = ModelPrice(
            inputPerMillion: 999,
            outputPerMillion: 999,
            cacheReadPerMillion: 999,
            cacheWritePerMillion: 999)
        for (model, inputRate) in [("gpt-6-astra", 10.0), ("gpt-6-sol", 2.0), ("gpt-6-luna", 0.1)] {
            let snapshot = model + "-2024-02-29"
            let derivative = model + "-mini"
            ModelPricingSupplement.install([model: supplement, snapshot: supplement, derivative: supplement])
            for curated in [model, snapshot] {
                XCTAssertEqual(try XCTUnwrap(modelPrice(for: curated)).inputPerMillion, inputRate, accuracy: 0.000_001)
            }
            XCTAssertEqual(modelPriceLookup(for: derivative).match, .supplement(modelId: derivative))
            XCTAssertEqual(try XCTUnwrap(modelPrice(for: derivative)).inputPerMillion, 999)
            XCTAssertTrue(modelPriceIsKnown(for: derivative, throughout: interval))
            ModelPricingSupplement.install([:])
            XCTAssertNil(modelPrice(for: derivative))
            XCTAssertFalse(modelPriceIsKnown(for: derivative, throughout: interval))
        }
    }
}
