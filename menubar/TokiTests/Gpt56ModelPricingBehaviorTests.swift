import XCTest
@testable import Toki
@testable import TokiUsageReaders

final class Gpt56ModelPricingBehaviorTests: XCTestCase {
    // 2026-07-20T00:00:00Z — before any GPT-5.6 price cut.
    private static let launchPricingDate = Date(timeIntervalSince1970: 1_784_505_600)
    // 2026-07-29T23:59:59Z — the last instant of the Terra/Luna launch rates.
    private static let lastTerraLunaLaunchDate = Date(timeIntervalSince1970: 1_785_369_599)
    // 2026-07-30T00:00:00Z — the first instant of the Terra/Luna reduced rates.
    private static let terraLunaCutDate = Date(timeIntervalSince1970: 1_785_369_600)
    // 2026-08-20T23:59:59Z — the last instant of the Sol launch rate.
    private static let lastSolLaunchDate = Date(timeIntervalSince1970: 1_787_270_399)
    // 2026-08-21T00:00:00Z — the first instant of Sol's reduced rate.
    private static let solCutDate = Date(timeIntervalSince1970: 1_787_270_400)

    private static let launchPrices: [String: ModelPrice] = [
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

    private static let reducedPrices: [String: ModelPrice] = [
        "gpt-5.6-sol": ModelPrice(
            inputPerMillion: 4.0,
            outputPerMillion: 20.0,
            cacheReadPerMillion: 0.40,
            cacheWritePerMillion: 5.0),
        "gpt-5.6-terra": ModelPrice(
            inputPerMillion: 2.0,
            outputPerMillion: 12.0,
            cacheReadPerMillion: 0.20,
            cacheWritePerMillion: 2.50),
        "gpt-5.6-luna": ModelPrice(
            inputPerMillion: 0.20,
            outputPerMillion: 1.20,
            cacheReadPerMillion: 0.02,
            cacheWritePerMillion: 0.25),
    ]

    func test_modelPrice_matchesGpt56LaunchPrices() throws {
        for (modelID, expected) in Self.launchPrices {
            let price = try XCTUnwrap(modelPrice(for: modelID, at: Self.launchPricingDate))

            assertRates(price, match: expected)
        }
    }

    func test_modelPrice_matchesGpt56ReducedPrices() throws {
        for (modelID, expected) in Self.reducedPrices {
            let price = try XCTUnwrap(modelPrice(for: modelID, at: Self.solCutDate))

            assertRates(price, match: expected)
        }
    }

    func test_modelPrice_selectsGpt56RateByUsageTimestamp() throws {
        for modelID in ["gpt-5.6-terra", "gpt-5.6-luna"] {
            let launch = try XCTUnwrap(modelPrice(for: modelID, at: Self.lastTerraLunaLaunchDate))
            try assertRates(launch, match: XCTUnwrap(Self.launchPrices[modelID]))

            let reduced = try XCTUnwrap(modelPrice(for: modelID, at: Self.terraLunaCutDate))
            try assertRates(reduced, match: XCTUnwrap(Self.reducedPrices[modelID]))
        }

        let solLaunch = try XCTUnwrap(modelPrice(for: "gpt-5.6-sol", at: Self.lastSolLaunchDate))
        try assertRates(solLaunch, match: XCTUnwrap(Self.launchPrices["gpt-5.6-sol"]))

        let solReduced = try XCTUnwrap(modelPrice(for: "gpt-5.6-sol", at: Self.solCutDate))
        try assertRates(solReduced, match: XCTUnwrap(Self.reducedPrices["gpt-5.6-sol"]))

        // Sol was cut three weeks after Terra and Luna, so it still bills at
        // its launch rate on their cut date.
        let solOnTerraLunaCut = try XCTUnwrap(modelPrice(for: "gpt-5.6-sol", at: Self.terraLunaCutDate))
        try assertRates(solOnTerraLunaCut, match: XCTUnwrap(Self.launchPrices["gpt-5.6-sol"]))
    }

    func test_modelPriceLookup_matchesGpt56SnapshotPrefixes() throws {
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

        // Dated snapshots resolve through the prefix key, so they must pick up
        // the scheduled cut instead of staying on the launch rate.
        for (prefix, modelID) in expectedPrefixes {
            let snapshot = try XCTUnwrap(modelPrice(for: modelID, at: Self.solCutDate))
            try assertRates(snapshot, match: XCTUnwrap(Self.reducedPrices[prefix]))
        }
    }

    func test_modelPrice_calculatesGpt56CostWithCacheRates() throws {
        let expectedCosts: [String: (launch: Double, reduced: Double)] = [
            "gpt-5.6-sol": (41.75, 29.40),
            "gpt-5.6-terra": (20.875, 16.70),
            "gpt-5.6-luna": (8.35, 1.67),
        ]

        for (modelID, expected) in expectedCosts {
            let launchPrice = try XCTUnwrap(modelPrice(for: modelID, at: Self.launchPricingDate))
            XCTAssertEqual(millionOfEachTokenCost(launchPrice), expected.launch, accuracy: 0.0001)

            let reducedPrice = try XCTUnwrap(modelPrice(for: modelID, at: Self.solCutDate))
            XCTAssertEqual(millionOfEachTokenCost(reducedPrice), expected.reduced, accuracy: 0.0001)
        }
    }

    private func assertRates(
        _ price: ModelPrice,
        match expected: ModelPrice,
        file: StaticString = #filePath,
        line: UInt = #line) {
        XCTAssertEqual(price.inputPerMillion, expected.inputPerMillion, accuracy: 0.0001, file: file, line: line)
        XCTAssertEqual(price.outputPerMillion, expected.outputPerMillion, accuracy: 0.0001, file: file, line: line)
        XCTAssertEqual(
            price.cacheReadPerMillion,
            expected.cacheReadPerMillion,
            accuracy: 0.0001,
            file: file,
            line: line)
        XCTAssertEqual(
            price.cacheWritePerMillion,
            expected.cacheWritePerMillion,
            accuracy: 0.0001,
            file: file,
            line: line)
    }

    private func millionOfEachTokenCost(_ price: ModelPrice) -> Double {
        price.cost(
            input: 1_000_000,
            output: 1_000_000,
            cacheRead: 1_000_000,
            cacheWrite: 1_000_000)
    }
}
