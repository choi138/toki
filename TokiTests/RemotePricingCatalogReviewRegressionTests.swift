import Foundation
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

    func test_parser_reservesRejectedCanonicalIDBeforeDerivingProviderAlias() {
        let fixture = """
        {
            "reserved-model": {
                "input_cost_per_token": 0.000001,
                "input_cost_per_token_above_128k_tokens": 0.000002,
                "output_cost_per_token": 0.000002,
                "mode": "chat"
            },
            "provider/reserved-model": {
                "input_cost_per_token": 0.000003,
                "output_cost_per_token": 0.000006,
                "aliases": ["reserved-model"],
                "mode": "chat"
            }
        }
        """

        let prices = RemotePricingCatalogParser.parse(Data(fixture.utf8))

        XCTAssertEqual(Set(prices.keys), ["provider/reserved-model"])
        XCTAssertNil(prices["reserved-model"])
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

final class RemotePricingCatalogTransportLimitTests: RemotePricingCatalogTestCase {
    func test_updater_rejectsCatalogResponseThatExceedsByteLimit() async throws {
        let fixture = try temporaryCatalogURL()
        defer { try? FileManager.default.removeItem(at: fixture.deletingLastPathComponent()) }
        let payload = Data(
            """
            {
                "oversized-model": {
                    "input_cost_per_token": 0.000004,
                    "output_cost_per_token": 0.00002,
                    "mode": "chat"
                }
            }
            """.utf8)
        let sessionConfiguration = URLSessionConfiguration.ephemeral
        sessionConfiguration.protocolClasses = [RemoteHubURLProtocolStub.self]
        RemoteHubURLProtocolStub.install { request in
            let response = try XCTUnwrap(HTTPURLResponse(
                url: XCTUnwrap(request.url),
                statusCode: 200,
                httpVersion: nil,
                headerFields: nil))
            return (response, payload)
        }
        defer { RemoteHubURLProtocolStub.reset() }
        let store = RemotePricingCatalogStore(fileURL: fixture)
        let updater = RemotePricingCatalogUpdater(
            store: store,
            sessionConfiguration: sessionConfiguration,
            maximumResponseBytes: payload.count - 1,
            now: { Date(timeIntervalSince1970: 1_785_000_000) })

        let didChangePricing = await updater.refreshIfNeeded(isEnabled: true)

        XCTAssertFalse(didChangePricing)
        XCTAssertNil(store.load())
        XCTAssertNil(modelPrice(for: "oversized-model"))
    }
}

final class PricingCatalogReplacementSafetyTests: RemotePricingCatalogTestCase {
    func test_updater_rejectsImplausiblySmallReplacementForStaleCache() async throws {
        let fixture = try temporaryCatalogURL()
        defer { try? FileManager.default.removeItem(at: fixture.deletingLastPathComponent()) }
        let cachedAt = Date(timeIntervalSince1970: 1_785_000_000)
        let cachedPrices = [
            "cached-model-a": makeEntry(input: 1, output: 2),
            "cached-model-b": makeEntry(input: 2, output: 4),
            "cached-model-c": makeEntry(input: 3, output: 6),
            "cached-model-d": makeEntry(input: 4, output: 8),
        ]
        let cachedSnapshot = RemotePricingCatalogSnapshot(fetchedAt: cachedAt, prices: cachedPrices)
        let store = RemotePricingCatalogStore(fileURL: fixture)
        XCTAssertTrue(store.save(cachedSnapshot))
        let updater = RemotePricingCatalogUpdater(
            store: store,
            fetch: { _ in
                Data(
                    """
                    {
                        "partial-only-model": {
                            "input_cost_per_token": 0.000004,
                            "output_cost_per_token": 0.00002,
                            "mode": "chat"
                        }
                    }
                    """.utf8)
            },
            now: { cachedAt.addingTimeInterval(RemotePricingCatalogUpdater.refreshInterval + 1) })

        let didChangePricing = await updater.refreshIfNeeded(isEnabled: true)

        XCTAssertTrue(didChangePricing)
        XCTAssertEqual(store.load(), cachedSnapshot)
        XCTAssertEqual(ModelPricingSupplement.installedCount, cachedPrices.count)
        XCTAssertNil(modelPrice(for: "partial-only-model"))
    }
}

final class PricingCatalogPersistenceTests: RemotePricingCatalogTestCase {
    func test_updater_throttlesAcceptedFetchWhenCacheCannotBeSaved() async throws {
        let fixture = try temporaryCatalogURL()
        let blockingParent = fixture.deletingLastPathComponent()
        try FileManager.default.removeItem(at: blockingParent)
        try Data("not-a-directory".utf8).write(to: blockingParent)
        defer { try? FileManager.default.removeItem(at: blockingParent) }
        let fetchCounter = FutureCacheFetchCounter()
        let store = RemotePricingCatalogStore(fileURL: fixture)
        let updater = RemotePricingCatalogUpdater(
            store: store,
            fetch: { _ in
                await fetchCounter.increment()
                return Data(
                    """
                    {
                        "memory-only-model": {
                            "input_cost_per_token": 0.000004,
                            "output_cost_per_token": 0.00002,
                            "mode": "chat"
                        }
                    }
                    """.utf8)
            },
            now: { Date(timeIntervalSince1970: 1_785_000_000) })

        let firstRefreshChangedPricing = await updater.refreshIfNeeded(isEnabled: true)
        let secondRefreshChangedPricing = await updater.refreshIfNeeded(isEnabled: true)
        let fetchCount = await fetchCounter.count

        XCTAssertTrue(firstRefreshChangedPricing)
        XCTAssertFalse(secondRefreshChangedPricing)
        XCTAssertEqual(fetchCount, 1)
        XCTAssertNil(store.load())
        XCTAssertNotNil(modelPrice(for: "memory-only-model"))

        _ = await updater.refreshIfNeeded(isEnabled: false)
        let reenabledRefreshChangedPricing = await updater.refreshIfNeeded(isEnabled: true)
        let reenabledFetchCount = await fetchCounter.count

        XCTAssertTrue(reenabledRefreshChangedPricing)
        XCTAssertEqual(reenabledFetchCount, 2)
    }
}

private actor FutureCacheFetchCounter {
    private(set) var count = 0

    func increment() {
        count += 1
    }
}
