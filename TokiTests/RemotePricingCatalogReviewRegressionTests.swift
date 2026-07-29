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
