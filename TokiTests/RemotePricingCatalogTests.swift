import XCTest
@testable import Toki
@testable import TokiUsageReaders

final class RemotePricingCatalogTests: XCTestCase {
    override func tearDown() {
        ModelPricingSupplement.install([:])
        super.tearDown()
    }

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

        XCTAssertEqual(Set(prices.keys), ["future-model", "aliased-model"])

        let futureModel = try XCTUnwrap(prices["future-model"])
        XCTAssertEqual(futureModel.inputPerMillion, 4.0, accuracy: 0.0001)
        XCTAssertEqual(futureModel.outputPerMillion, 20.0, accuracy: 0.0001)
        XCTAssertEqual(futureModel.cacheReadPerMillion, 0.40, accuracy: 0.0001)
        XCTAssertEqual(futureModel.cacheWritePerMillion, 5.0, accuracy: 0.0001)

        let aliased = try XCTUnwrap(prices["aliased-model"])
        XCTAssertEqual(aliased.inputPerMillion, 1.0, accuracy: 0.0001)
        XCTAssertEqual(aliased.cacheReadPerMillion, 0.0, accuracy: 0.0001)
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

    private func temporaryCatalogURL() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("toki-pricing-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent("RemotePricingCatalog.json")
    }
}

private actor RemotePricingFetchCounter {
    private(set) var count = 0

    func increment() {
        count += 1
    }
}
