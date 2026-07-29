import TokiUsageCore
import XCTest
@testable import Toki
@testable import TokiUsageReaders

class RemotePricingCatalogTestCase: XCTestCase {
    override func tearDown() {
        ModelPricingSupplement.install([:])
        super.tearDown()
    }

    func temporaryCatalogURL() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("toki-pricing-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent("RemotePricingCatalog.json")
    }

    func makeEntry(input: Double, output: Double) -> RemotePricingCatalogSnapshot.Entry {
        RemotePricingCatalogSnapshot.Entry(
            inputPerMillion: input,
            outputPerMillion: output,
            cacheReadPerMillion: input,
            cacheWritePerMillion: input)
    }

    func makePrice(input: Double, output: Double) -> ModelPrice {
        ModelPrice(
            inputPerMillion: input,
            outputPerMillion: output,
            cacheReadPerMillion: input,
            cacheWritePerMillion: input)
    }

    func makeEvent(at timestamp: Date, model: String) -> TokenUsageEvent {
        TokenUsageEvent(
            timestamp: timestamp,
            source: "Test",
            model: model,
            inputTokens: 10,
            outputTokens: 0,
            cacheReadTokens: 0,
            cacheWriteTokens: 0,
            reasoningTokens: 0,
            cost: 0)
    }
}

final class RemotePricingCatalogTests: RemotePricingCatalogTestCase {
    func test_supplement_isConsultedOnlyAfterCuratedTablesMiss() throws {
        ModelPricingSupplement.install([
            "claude-opus-4-6": ModelPrice(
                inputPerMillion: 999,
                outputPerMillion: 999,
                cacheReadPerMillion: 999,
                cacheWritePerMillion: 999),
            "brand-new-model": ModelPrice(
                inputPerMillion: 7.0,
                outputPerMillion: 21.0,
                cacheReadPerMillion: 0.7,
                cacheWritePerMillion: 8.75),
        ])

        // Curated static pricing wins over a conflicting supplement entry.
        let curated = try XCTUnwrap(modelPrice(for: "claude-opus-4-6"))
        XCTAssertEqual(curated.inputPerMillion, 5.0, accuracy: 0.0001)

        // A model unknown to the curated tables resolves from the supplement.
        let supplemented = modelPriceLookup(for: "brand-new-model")
        XCTAssertEqual(supplemented.match, .supplement(modelId: "brand-new-model"))
        let price = try XCTUnwrap(supplemented.price)
        XCTAssertEqual(price.inputPerMillion, 7.0, accuracy: 0.0001)
        XCTAssertEqual(price.outputPerMillion, 21.0, accuracy: 0.0001)

        // Uninstalling restores the missing state.
        ModelPricingSupplement.install([:])
        XCTAssertEqual(modelPriceLookup(for: "brand-new-model").match, .missing)
    }

    func test_parser_mapsCostsFiltersModesAndDerivesBareAliases() throws {
        let fixture = """
        {
            "sample_spec": {"input_cost_per_token": 0.0, "output_cost_per_token": 0.0, "mode": "chat"},
            "future-model": {
                "input_cost_per_token": 0.000004,
                "output_cost_per_token": 0.00002,
                "cache_read_input_token_cost": 0.0000004,
                "cache_creation_input_token_cost": 0.000005,
                "mode": "chat"
            },
            "provider/aliased-model": {
                "input_cost_per_token": 0.000001,
                "output_cost_per_token": 0.000002,
                "aliases": ["catalog-alias", "", 42],
                "mode": "chat"
            },
            "provider/future-model": {
                "input_cost_per_token": 0.000009,
                "output_cost_per_token": 0.00009,
                "mode": "chat"
            },
            "embedding-model": {"input_cost_per_token": 0.0000001, "output_cost_per_token": 0.0, "mode": "embedding"},
            "costless-model": {"mode": "chat"}
        }
        """
        let prices = RemotePricingCatalogParser.parse(Data(fixture.utf8))

        XCTAssertEqual(Set(prices.keys), [
            "future-model",
            "provider/future-model",
            "provider/aliased-model",
            "aliased-model",
            "catalog-alias",
        ])

        let futureModel = try XCTUnwrap(prices["future-model"])
        XCTAssertEqual(futureModel.inputPerMillion, 4.0, accuracy: 0.0001)
        XCTAssertEqual(futureModel.outputPerMillion, 20.0, accuracy: 0.0001)
        XCTAssertEqual(futureModel.cacheReadPerMillion, 0.40, accuracy: 0.0001)
        XCTAssertEqual(futureModel.cacheWritePerMillion, 5.0, accuracy: 0.0001)

        let aliased = try XCTUnwrap(prices["aliased-model"])
        XCTAssertEqual(aliased.inputPerMillion, 1.0, accuracy: 0.0001)
        XCTAssertEqual(aliased.cacheReadPerMillion, 1.0, accuracy: 0.0001)
        XCTAssertEqual(aliased.cacheWritePerMillion, 1.0, accuracy: 0.0001)
        XCTAssertEqual(prices["provider/aliased-model"], aliased)
        XCTAssertEqual(prices["catalog-alias"], aliased)

        let providerQualified = try XCTUnwrap(prices["provider/future-model"])
        XCTAssertEqual(providerQualified.inputPerMillion, 9.0, accuracy: 0.0001)
    }

    func test_parser_preservesNestedModelIDWhenDerivingProviderAlias() {
        let fixture = """
        {
            "provider/org/nested-model": {
                "input_cost_per_token": 0.000003,
                "output_cost_per_token": 0.000012,
                "mode": "chat"
            }
        }
        """

        let prices = RemotePricingCatalogParser.parse(Data(fixture.utf8))

        XCTAssertEqual(Set(prices.keys), ["provider/org/nested-model", "org/nested-model"])
        XCTAssertNil(prices["nested-model"])
        XCTAssertEqual(prices["provider/org/nested-model"], prices["org/nested-model"])
    }

    func test_parser_omitsAmbiguousAliasesButPreservesCanonicalKeys() throws {
        let fixture = """
        {
            "alpha/shared": {
                "input_cost_per_token": 0.000001,
                "output_cost_per_token": 0.000002,
                "aliases": ["catalog-alias"],
                "mode": "chat"
            },
            "beta/shared": {
                "input_cost_per_token": 0.000001,
                "output_cost_per_token": 0.000002,
                "aliases": ["catalog-alias"],
                "mode": "chat"
            },
            "shared": {
                "input_cost_per_token": 0.000005,
                "output_cost_per_token": 0.000006,
                "mode": "chat"
            }
        }
        """

        let prices = RemotePricingCatalogParser.parse(Data(fixture.utf8))

        XCTAssertEqual(Set(prices.keys), ["alpha/shared", "beta/shared", "shared"])
        XCTAssertEqual(try XCTUnwrap(prices["shared"]).inputPerMillion, 5.0, accuracy: 0.0001)
        XCTAssertNil(prices["catalog-alias"])
    }

    func test_parser_rejectsNonFiniteScaledPricesAndInvalidCacheRates() {
        let fixture = """
        {
            "valid-model": {
                "input_cost_per_token": 0.000001,
                "output_cost_per_token": 0.000002,
                "mode": "chat"
            },
            "overflow-model": {
                "input_cost_per_token": 1e308,
                "output_cost_per_token": 0.000002,
                "mode": "chat"
            },
            "negative-cache-model": {
                "input_cost_per_token": 0.000001,
                "output_cost_per_token": 0.000002,
                "cache_read_input_token_cost": -0.1,
                "mode": "chat"
            },
            "malformed-cache-model": {
                "input_cost_per_token": 0.000001,
                "output_cost_per_token": 0.000002,
                "cache_read_input_token_cost": "unknown",
                "mode": "chat"
            }
        }
        """

        let prices = RemotePricingCatalogParser.parse(Data(fixture.utf8))

        XCTAssertEqual(Set(prices.keys), ["valid-model"])
        XCTAssertEqual(prices["valid-model"]?.cacheReadPerMillion, 1.0)
        XCTAssertEqual(prices["valid-model"]?.cacheWritePerMillion, 1.0)
    }
}

final class ModelPricingSupplementHistoryTests: RemotePricingCatalogTestCase {
    func test_supplement_resolvesPriceVersionByUsageTimestamp() throws {
        let firstFetch = Date(timeIntervalSince1970: 1_700_000_000)
        let secondFetch = firstFetch.addingTimeInterval(86400)
        ModelPricingSupplement.install(priceHistories: [
            "versioned-model": [
                ModelPricingSupplement.PriceVersion(
                    effectiveFrom: firstFetch,
                    price: makePrice(input: 1, output: 2)),
                ModelPricingSupplement.PriceVersion(
                    effectiveFrom: secondFetch,
                    price: makePrice(input: 3, output: 4)),
            ],
            "removed-model": [
                ModelPricingSupplement.PriceVersion(
                    effectiveFrom: firstFetch,
                    price: makePrice(input: 5, output: 6)),
                ModelPricingSupplement.PriceVersion(
                    effectiveFrom: secondFetch,
                    price: nil),
            ],
        ])

        XCTAssertNil(modelPrice(for: "versioned-model", at: firstFetch.addingTimeInterval(-1)))
        let firstPrice = try XCTUnwrap(modelPrice(for: "versioned-model", at: firstFetch))
        let secondPrice = try XCTUnwrap(modelPrice(for: "versioned-model", at: secondFetch))
        XCTAssertEqual(firstPrice.inputPerMillion, 1, accuracy: 0.0001)
        XCTAssertEqual(secondPrice.inputPerMillion, 3, accuracy: 0.0001)
        XCTAssertNotNil(modelPrice(for: "removed-model", at: firstFetch))
        XCTAssertNil(modelPrice(for: "removed-model", at: secondFetch))
        XCTAssertTrue(modelPriceIsKnown(
            for: "versioned-model",
            throughout: DateInterval(start: firstFetch, end: secondFetch.addingTimeInterval(1))))
        XCTAssertFalse(modelPriceIsKnown(
            for: "removed-model",
            throughout: DateInterval(start: firstFetch, end: secondFetch.addingTimeInterval(1))))
        XCTAssertFalse(modelPriceIsKnown(
            for: "versioned-model",
            throughout: DateInterval(
                start: firstFetch.addingTimeInterval(-1),
                end: firstFetch.addingTimeInterval(1))))
    }

    func test_modelStatsUseEventTimestampsAndConservativeAggregateCoverage() throws {
        let firstFetch = Date(timeIntervalSince1970: 1_700_000_000)
        let periodStart = firstFetch.addingTimeInterval(-3600)
        let periodEnd = firstFetch.addingTimeInterval(3600)
        ModelPricingSupplement.install(priceHistories: [
            "versioned-model": [
                ModelPricingSupplement.PriceVersion(
                    effectiveFrom: firstFetch,
                    price: makePrice(input: 1, output: 2)),
            ],
        ])

        let beforeFetchUsage = RawTokenUsage(tokenEvents: [
            makeEvent(at: firstFetch.addingTimeInterval(-1), model: "versioned-model"),
        ])
        let afterFetchUsage = RawTokenUsage(tokenEvents: [
            makeEvent(at: firstFetch.addingTimeInterval(1), model: "versioned-model"),
        ])
        let aggregateOnlyUsage = RawTokenUsage(perModel: [
            "versioned-model": PerModelUsage(totalTokens: 10, cost: 0, sources: ["Test"]),
        ])

        let beforeFetchStat = try XCTUnwrap(UsageReportBuilder.buildModelStats(
            from: beforeFetchUsage,
            startDate: periodStart,
            endDate: periodEnd).first)
        let afterFetchStat = try XCTUnwrap(UsageReportBuilder.buildModelStats(
            from: afterFetchUsage,
            startDate: periodStart,
            endDate: periodEnd).first)
        let aggregateOnlyStat = try XCTUnwrap(UsageReportBuilder.buildModelStats(
            from: aggregateOnlyUsage,
            startDate: periodStart,
            endDate: periodEnd).first)

        XCTAssertFalse(beforeFetchStat.isPriceKnown)
        XCTAssertTrue(afterFetchStat.isPriceKnown)
        XCTAssertFalse(aggregateOnlyStat.isPriceKnown)
    }

    func test_store_roundTripsSnapshot() throws {
        let fixture = try temporaryCatalogURL()
        defer { try? FileManager.default.removeItem(at: fixture.deletingLastPathComponent()) }
        let store = RemotePricingCatalogStore(fileURL: fixture)
        let snapshot = RemotePricingCatalogSnapshot(
            fetchedAt: Date(timeIntervalSince1970: 1_785_000_000),
            prices: ["future-model": RemotePricingCatalogSnapshot.Entry(
                inputPerMillion: 4.0,
                outputPerMillion: 20.0,
                cacheReadPerMillion: 0.4,
                cacheWritePerMillion: 5.0)])

        store.save(snapshot)

        XCTAssertEqual(store.load(), snapshot)
    }

    func test_snapshot_preservesOnlyPerModelChangesAndTombstones() {
        let firstFetch = Date(timeIntervalSince1970: 1_785_000_000)
        let secondFetch = firstFetch.addingTimeInterval(86400)
        let thirdFetch = secondFetch.addingTimeInterval(86400)
        let firstPrices = [
            "stable-model": makeEntry(input: 1, output: 2),
            "changed-model": makeEntry(input: 4, output: 20),
            "removed-model": makeEntry(input: 7, output: 14),
        ]
        let secondPrices = [
            "stable-model": makeEntry(input: 1, output: 2),
            "changed-model": makeEntry(input: 5, output: 25),
            "added-model": makeEntry(input: 8, output: 16),
        ]

        let initial = RemotePricingCatalogSnapshot(fetchedAt: firstFetch, prices: firstPrices)
        let unchanged = initial.updating(fetchedAt: secondFetch, prices: firstPrices)
        let changed = unchanged.updating(fetchedAt: thirdFetch, prices: secondPrices)

        XCTAssertEqual(unchanged.fetchedAt, secondFetch)
        XCTAssertEqual(unchanged.priceHistories.values.map(\.count), [1, 1, 1])
        XCTAssertEqual(changed.priceHistories["stable-model"]?.count, 1)
        XCTAssertEqual(changed.priceHistories["changed-model"]?.count, 2)
        XCTAssertEqual(changed.priceHistories["removed-model"]?.count, 2)
        XCTAssertNil(changed.priceHistories["removed-model"]?.last?.price)
        XCTAssertEqual(changed.priceHistories["added-model"]?.count, 1)
        XCTAssertEqual(changed.priceHistories["added-model"]?.first?.effectiveFrom, thirdFetch)
        XCTAssertEqual(changed.prices, secondPrices)
    }

    func test_snapshot_decodesLegacySingleVersionCache() throws {
        let fixture = """
        {
            "fetchedAt": "2026-07-28T00:00:00Z",
            "prices": {
                "legacy-model": {
                    "inputPerMillion": 1,
                    "outputPerMillion": 2,
                    "cacheReadPerMillion": 1,
                    "cacheWritePerMillion": 1
                }
            }
        }
        """
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        let snapshot = try decoder.decode(RemotePricingCatalogSnapshot.self, from: Data(fixture.utf8))

        XCTAssertEqual(snapshot.priceHistories["legacy-model"]?.count, 1)
        XCTAssertEqual(snapshot.priceHistories["legacy-model"]?.first?.effectiveFrom, snapshot.fetchedAt)
        XCTAssertNotNil(snapshot.prices["legacy-model"])
    }

    func test_snapshot_decodesFullCatalogVersionsIntoPerModelHistory() throws {
        let fixture = """
        {
            "fetchedAt": "2026-07-29T00:00:00Z",
            "versions": [
                {
                    "effectiveFrom": "2026-07-28T00:00:00Z",
                    "prices": {
                        "stable-model": {
                            "inputPerMillion": 1,
                            "outputPerMillion": 2,
                            "cacheReadPerMillion": 1,
                            "cacheWritePerMillion": 1
                        },
                        "removed-model": {
                            "inputPerMillion": 3,
                            "outputPerMillion": 4,
                            "cacheReadPerMillion": 3,
                            "cacheWritePerMillion": 3
                        }
                    }
                },
                {
                    "effectiveFrom": "2026-07-29T00:00:00Z",
                    "prices": {
                        "stable-model": {
                            "inputPerMillion": 1,
                            "outputPerMillion": 2,
                            "cacheReadPerMillion": 1,
                            "cacheWritePerMillion": 1
                        },
                        "added-model": {
                            "inputPerMillion": 5,
                            "outputPerMillion": 6,
                            "cacheReadPerMillion": 5,
                            "cacheWritePerMillion": 5
                        }
                    }
                }
            ]
        }
        """
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        let snapshot = try decoder.decode(RemotePricingCatalogSnapshot.self, from: Data(fixture.utf8))

        XCTAssertEqual(snapshot.priceHistories["stable-model"]?.count, 1)
        XCTAssertEqual(snapshot.priceHistories["removed-model"]?.count, 2)
        XCTAssertNil(snapshot.priceHistories["removed-model"]?.last?.price)
        XCTAssertEqual(snapshot.priceHistories["added-model"]?.count, 1)
        XCTAssertEqual(Set(snapshot.prices.keys), ["stable-model", "added-model"])
    }
}

final class RemotePricingCatalogUpdaterTests: RemotePricingCatalogTestCase {
    func test_updater_fetchesInstallsAndHonorsDailyInterval() async throws {
        let fixture = try temporaryCatalogURL()
        defer { try? FileManager.default.removeItem(at: fixture.deletingLastPathComponent()) }
        let fetchCounter = RemotePricingFetchCounter()
        let updater = RemotePricingCatalogUpdater(
            store: RemotePricingCatalogStore(fileURL: fixture),
            fetch: { _ in
                await fetchCounter.increment()
                let payload = """
                {"future-model": {"input_cost_per_token": 0.000004, "output_cost_per_token": 0.00002, "mode": "chat"}}
                """
                return Data(payload.utf8)
            },
            now: { Date(timeIntervalSince1970: 1_785_000_000) })

        await updater.refreshIfNeeded(isEnabled: true)

        let fetchCount = await fetchCounter.count
        XCTAssertEqual(fetchCount, 1)
        XCTAssertEqual(ModelPricingSupplement.installedCount, 1)
        XCTAssertNotNil(modelPrice(for: "future-model"))

        // A fresh cache suppresses further fetches within the interval.
        await updater.refreshIfNeeded(isEnabled: true)
        let secondFetchCount = await fetchCounter.count
        XCTAssertEqual(secondFetchCount, 1)

        // Disabling clears the supplement without fetching.
        await updater.refreshIfNeeded(isEnabled: false)
        let disabledFetchCount = await fetchCounter.count
        XCTAssertEqual(disabledFetchCount, 1)
        XCTAssertEqual(ModelPricingSupplement.installedCount, 0)
        XCTAssertNil(modelPrice(for: "future-model"))
    }

    func test_updater_installsCachedCatalogWithoutRefetching() async throws {
        let fixture = try temporaryCatalogURL()
        defer { try? FileManager.default.removeItem(at: fixture.deletingLastPathComponent()) }
        let store = RemotePricingCatalogStore(fileURL: fixture)
        let cachedAt = Date(timeIntervalSince1970: 1_785_000_000)
        store.save(RemotePricingCatalogSnapshot(
            fetchedAt: cachedAt,
            prices: ["cached-model": RemotePricingCatalogSnapshot.Entry(
                inputPerMillion: 2.0,
                outputPerMillion: 6.0,
                cacheReadPerMillion: 0.2,
                cacheWritePerMillion: 2.5)]))
        let updater = RemotePricingCatalogUpdater(
            store: store,
            fetch: { _ in
                XCTFail("A fresh cache must not trigger a network fetch")
                return Data()
            },
            now: { cachedAt.addingTimeInterval(60) })

        await updater.refreshIfNeeded(isEnabled: true)

        XCTAssertEqual(ModelPricingSupplement.installedCount, 1)
        XCTAssertNotNil(modelPrice(for: "cached-model"))
    }

    func test_updater_discardsFetchThatFinishesAfterCatalogIsDisabled() async throws {
        let fixture = try temporaryCatalogURL()
        defer { try? FileManager.default.removeItem(at: fixture.deletingLastPathComponent()) }
        ModelPricingSupplement.install(["existing-model": makePrice(input: 1, output: 2)])
        let response = Data(
            """
            {"stale-model": {"input_cost_per_token": 0.000004, "output_cost_per_token": 0.00002, "mode": "chat"}}
            """.utf8)
        let gate = RemotePricingFetchGate(subsequentResponse: response)
        let store = RemotePricingCatalogStore(fileURL: fixture)
        let updater = RemotePricingCatalogUpdater(
            store: store,
            fetch: { _ in await gate.fetch() },
            now: { Date(timeIntervalSince1970: 1_785_000_000) })

        let refresh = Task { await updater.refreshIfNeeded(isEnabled: true) }
        await gate.waitUntilFirstRequestStarts()
        let didClearPricing = await updater.refreshIfNeeded(isEnabled: false)
        await gate.releaseFirstRequest(with: response)
        _ = await refresh.value

        XCTAssertTrue(didClearPricing)
        XCTAssertEqual(ModelPricingSupplement.installedCount, 0)
        XCTAssertNil(store.load())
        XCTAssertNil(modelPrice(for: "stale-model"))
    }

    func test_updater_refetchesAfterCatalogIsReenabledDuringInflightRequest() async throws {
        let fixture = try temporaryCatalogURL()
        defer { try? FileManager.default.removeItem(at: fixture.deletingLastPathComponent()) }
        let staleResponse = Data(
            """
            {"stale-model": {"input_cost_per_token": 0.000004, "output_cost_per_token": 0.00002, "mode": "chat"}}
            """.utf8)
        let freshResponse = Data(
            """
            {"fresh-model": {"input_cost_per_token": 0.000005, "output_cost_per_token": 0.000025, "mode": "chat"}}
            """.utf8)
        let gate = RemotePricingFetchGate(subsequentResponse: freshResponse)
        let updater = RemotePricingCatalogUpdater(
            store: RemotePricingCatalogStore(fileURL: fixture),
            fetch: { _ in await gate.fetch() },
            now: { Date(timeIntervalSince1970: 1_785_000_000) })

        let refresh = Task { await updater.refreshIfNeeded(isEnabled: true) }
        await gate.waitUntilFirstRequestStarts()
        _ = await updater.refreshIfNeeded(isEnabled: false)
        _ = await updater.refreshIfNeeded(isEnabled: true)
        await gate.releaseFirstRequest(with: staleResponse)
        _ = await refresh.value
        let requestCount = await gate.requestCount

        XCTAssertEqual(requestCount, 2)
        XCTAssertNil(modelPrice(for: "stale-model"))
        XCTAssertNotNil(modelPrice(for: "fresh-model"))
    }
}

private actor RemotePricingFetchCounter {
    private(set) var count = 0

    func increment() {
        count += 1
    }
}

private actor RemotePricingFetchGate {
    private let subsequentResponse: Data
    private var firstRequestContinuation: CheckedContinuation<Data, Never>?
    private var firstRequestWaiters: [CheckedContinuation<Void, Never>] = []
    private(set) var requestCount = 0

    init(subsequentResponse: Data) {
        self.subsequentResponse = subsequentResponse
    }

    func fetch() async -> Data {
        requestCount += 1
        guard requestCount == 1 else { return subsequentResponse }
        return await withCheckedContinuation { continuation in
            firstRequestContinuation = continuation
            firstRequestWaiters.forEach { $0.resume() }
            firstRequestWaiters.removeAll()
        }
    }

    func waitUntilFirstRequestStarts() async {
        guard firstRequestContinuation == nil else { return }
        await withCheckedContinuation { continuation in
            firstRequestWaiters.append(continuation)
        }
    }

    func releaseFirstRequest(with data: Data) {
        firstRequestContinuation?.resume(returning: data)
        firstRequestContinuation = nil
    }
}
