import TokiUsageCore
import XCTest
@testable import Toki
@testable import TokiUsageReaders

final class RemotePricingCatalogBooleanTests: RemotePricingCatalogTestCase {
    func test_parser_rejectsBooleanCosts() {
        let fixture = """
        {
            "valid-model": {
                "input_cost_per_token": 0.000001,
                "output_cost_per_token": 0.000002,
                "mode": "chat"
            },
            "boolean-input": {
                "input_cost_per_token": true,
                "output_cost_per_token": 0.000002,
                "mode": "chat"
            },
            "boolean-output": {
                "input_cost_per_token": 0.000001,
                "output_cost_per_token": false,
                "mode": "chat"
            },
            "boolean-cache-read": {
                "input_cost_per_token": 0.000001,
                "output_cost_per_token": 0.000002,
                "cache_read_input_token_cost": true,
                "mode": "chat"
            },
            "boolean-cache-write": {
                "input_cost_per_token": 0.000001,
                "output_cost_per_token": 0.000002,
                "cache_creation_input_token_cost": false,
                "mode": "chat"
            }
        }
        """

        let prices = RemotePricingCatalogParser.parse(Data(fixture.utf8))

        XCTAssertEqual(Set(prices.keys), ["valid-model"])
    }
}

final class RemotePricingCatalogCostSafetyTests: RemotePricingCatalogTestCase {
    func test_parser_rejectsRatesThatCanOverflowLaterCostMultiplication() throws {
        let fixture = """
        {
            "valid-model": {
                "input_cost_per_token": 0.000001,
                "output_cost_per_token": 0.000002,
                "mode": "chat"
            },
            "maximum-model": {
                "input_cost_per_token": 1,
                "output_cost_per_token": 1,
                "mode": "chat"
            },
            "excessive-model": {
                "input_cost_per_token": 1e300,
                "output_cost_per_token": 0.000002,
                "mode": "chat"
            }
        }
        """

        let prices = RemotePricingCatalogParser.parse(Data(fixture.utf8))

        XCTAssertEqual(Set(prices.keys), ["maximum-model", "valid-model"])
        let maximum = try XCTUnwrap(prices["maximum-model"])
        let cost = ModelPrice(
            inputPerMillion: maximum.inputPerMillion,
            outputPerMillion: maximum.outputPerMillion,
            cacheReadPerMillion: maximum.cacheReadPerMillion,
            cacheWritePerMillion: maximum.cacheWritePerMillion)
            .cost(input: 1000, output: 1000, cacheRead: 1000, cacheWrite: 1000)
        XCTAssertTrue(cost.isFinite)
    }

    func test_parser_rejectsContextTieredTokenRates() {
        let fixture = """
        {
            "valid-model": {
                "input_cost_per_token": 0.000001,
                "output_cost_per_token": 0.000002,
                "mode": "chat"
            },
            "tiered-input": {
                "input_cost_per_token": 0.000001,
                "input_cost_per_token_above_128k_tokens": 0.000002,
                "output_cost_per_token": 0.000002,
                "mode": "chat"
            },
            "tiered-output": {
                "input_cost_per_token": 0.000001,
                "output_cost_per_token": 0.000002,
                "output_cost_per_token_above_272k_tokens": 0.000004,
                "mode": "responses"
            },
            "tiered-cache-read": {
                "input_cost_per_token": 0.000001,
                "output_cost_per_token": 0.000002,
                "cache_read_input_token_cost_above_200k_tokens": 0.0000002,
                "mode": "chat"
            },
            "tiered-cache-write": {
                "input_cost_per_token": 0.000001,
                "output_cost_per_token": 0.000002,
                "cache_creation_input_token_cost_above_512k_tokens": 0.000003,
                "mode": "completion"
            }
        }
        """

        let prices = RemotePricingCatalogParser.parse(Data(fixture.utf8))

        XCTAssertEqual(Set(prices.keys), ["valid-model"])
    }
}

final class RemotePricingCatalogFutureCacheTests: RemotePricingCatalogTestCase {
    func test_updater_refetchesAndRebasesFutureDatedCache() async throws {
        let fixture = try temporaryCatalogURL()
        defer { try? FileManager.default.removeItem(at: fixture.deletingLastPathComponent()) }
        let now = Date(timeIntervalSince1970: 1_785_000_000)
        let futureFetch = now.addingTimeInterval(3600)
        let store = RemotePricingCatalogStore(fileURL: fixture)
        store.save(RemotePricingCatalogSnapshot(
            fetchedAt: futureFetch,
            prices: ["future-cache-model": makeEntry(input: 4, output: 20)]))
        let fetchCounter = FutureCacheFetchCounter()
        let updater = RemotePricingCatalogUpdater(
            store: store,
            fetch: { _ in
                await fetchCounter.increment()
                return Data(
                    """
                    {
                        "future-cache-model": {
                            "input_cost_per_token": 0.000004,
                            "output_cost_per_token": 0.00002,
                            "mode": "chat"
                        }
                    }
                    """.utf8)
            },
            now: { now })

        let didChangePricing = await updater.refreshIfNeeded(isEnabled: true)
        let fetchCount = await fetchCounter.count

        XCTAssertTrue(didChangePricing)
        XCTAssertEqual(fetchCount, 1)
        XCTAssertNotNil(modelPrice(for: "future-cache-model", at: now))
        let recovered = try XCTUnwrap(store.load())
        XCTAssertEqual(recovered.fetchedAt, now)
        XCTAssertEqual(
            recovered.priceHistories["future-cache-model"]?.map(\.effectiveFrom),
            [now])
    }
}

private actor FutureCacheFetchCounter {
    private(set) var count = 0

    func increment() {
        count += 1
    }
}
