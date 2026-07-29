import TokiUsageReaders
import XCTest
@testable import Toki

@MainActor
final class UsagePanelSettingsTests: XCTestCase {
    func test_defaultsUseExpectedValues() {
        let (suiteName, defaults) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let settings = UsagePanelSettings(
            defaults: defaults,
            readerNames: ["Codex", "Cursor"],
            refreshPricingCatalog: { _ in false })

        XCTAssertEqual(settings.refreshIntervalSeconds, 180)
        XCTAssertEqual(settings.enabledReaderNames, ["Codex": true, "Cursor": true])
        XCTAssertFalse(settings.showsZeroSourceRows)
        XCTAssertTrue(settings.autoUpdatesModelPricing)
        XCTAssertFalse(settings.showsMenuBarCost)
        XCTAssertTrue(UsagePanelSettings.isAutoUpdatePricingEnabled(defaults: defaults))
        XCTAssertFalse(UsagePanelSettings.isMenuBarCostEnabled(defaults: defaults))
    }

    func test_persistsChanges() {
        let (suiteName, defaults) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let settings = UsagePanelSettings(
            defaults: defaults,
            readerNames: ["Codex", "Cursor"],
            refreshPricingCatalog: { _ in false })

        settings.refreshIntervalSeconds = 300
        settings.setReader("Cursor", isEnabled: false)
        settings.showsZeroSourceRows = true
        settings.setAutoUpdatesModelPricing(false)
        settings.setShowsMenuBarCost(true)

        let reloaded = UsagePanelSettings(defaults: defaults, readerNames: ["Codex", "Cursor"])

        XCTAssertEqual(reloaded.refreshIntervalSeconds, 300)
        XCTAssertTrue(reloaded.isReaderEnabled("Codex"))
        XCTAssertFalse(reloaded.isReaderEnabled("Cursor"))
        XCTAssertTrue(reloaded.showsZeroSourceRows)
        XCTAssertFalse(reloaded.autoUpdatesModelPricing)
        XCTAssertTrue(reloaded.showsMenuBarCost)
        XCTAssertFalse(UsagePanelSettings.isAutoUpdatePricingEnabled(defaults: defaults))
        XCTAssertTrue(UsagePanelSettings.isMenuBarCostEnabled(defaults: defaults))
    }

    func test_normalizesUnsupportedRefreshInterval() {
        let (suiteName, defaults) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let settings = UsagePanelSettings(defaults: defaults, readerNames: ["Codex"])

        settings.refreshIntervalSeconds = 999

        XCTAssertEqual(settings.refreshIntervalSeconds, 180)
    }

    func test_refreshIntervalChangePostsNotificationAndUpdatesStaticValue() {
        let (suiteName, defaults) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        var notificationCount = 0
        let observer = NotificationCenter.default.addObserver(
            forName: .usagePanelRefreshIntervalDidChange,
            object: nil,
            queue: nil) { _ in
                notificationCount += 1
            }
        defer { NotificationCenter.default.removeObserver(observer) }
        let settings = UsagePanelSettings(defaults: defaults, readerNames: ["Codex"])

        settings.refreshIntervalSeconds = 60

        XCTAssertEqual(notificationCount, 1)
        XCTAssertEqual(UsagePanelSettings.currentRefreshIntervalSeconds(defaults: defaults), 60)
    }

    func test_readerChangePostsNotificationOnlyWhenValueChanges() {
        let (suiteName, defaults) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        var notificationCount = 0
        let observer = NotificationCenter.default.addObserver(
            forName: .usagePanelReaderSettingsDidChange,
            object: nil,
            queue: nil) { _ in
                notificationCount += 1
            }
        defer { NotificationCenter.default.removeObserver(observer) }
        let settings = UsagePanelSettings(defaults: defaults, readerNames: ["Codex"])

        settings.setReader("Codex", isEnabled: false)
        settings.setReader("Codex", isEnabled: false)

        XCTAssertEqual(notificationCount, 1)
    }

    func test_autoPricingSetterRefreshesCatalogAndPostsChangeNotification() async {
        let (suiteName, defaults) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let pricingChanged = expectation(description: "Pricing change notification")
        let observer = NotificationCenter.default.addObserver(
            forName: .usagePanelModelPricingDidChange,
            object: nil,
            queue: nil) { _ in
                pricingChanged.fulfill()
            }
        defer { NotificationCenter.default.removeObserver(observer) }
        let settings = UsagePanelSettings(
            defaults: defaults,
            readerNames: ["Codex"],
            refreshPricingCatalog: { isEnabled in
                XCTAssertFalse(isEnabled)
                return true
            })

        settings.setAutoUpdatesModelPricing(false)

        await fulfillment(of: [pricingChanged], timeout: 1)
        XCTAssertFalse(settings.autoUpdatesModelPricing)
    }

    func test_reenabledAutoPricingOwnsQueuedRefreshAndPostsChangeNotification() async {
        let (suiteName, defaults) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set(false, forKey: "usagePanel.autoUpdatesModelPricing")

        let fixture = FileManager.default.temporaryDirectory
            .appendingPathComponent("toki-settings-pricing-tests-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("RemotePricingCatalog.json")
        defer {
            ModelPricingSupplement.install([:])
            try? FileManager.default.removeItem(at: fixture.deletingLastPathComponent())
        }

        let staleResponse = Data(
            """
            {"stale-model": {"input_cost_per_token": 0.000004, "output_cost_per_token": 0.00002, "mode": "chat"}}
            """.utf8)
        let freshResponse = Data(
            """
            {"fresh-model": {"input_cost_per_token": 0.000005, "output_cost_per_token": 0.000025, "mode": "chat"}}
            """.utf8)
        let gate = SettingsPricingFetchGate(subsequentResponse: freshResponse)
        let updater = RemotePricingCatalogUpdater(
            store: RemotePricingCatalogStore(fileURL: fixture),
            fetch: { _ in await gate.fetch() },
            now: { Date(timeIntervalSince1970: 1_785_000_000) })

        let disabledRefreshFinished = expectation(description: "Disabled pricing refresh finished")
        let pricingChanged = expectation(description: "Re-enabled pricing change notification")
        let observer = NotificationCenter.default.addObserver(
            forName: .usagePanelModelPricingDidChange,
            object: nil,
            queue: nil) { _ in
                pricingChanged.fulfill()
            }
        defer { NotificationCenter.default.removeObserver(observer) }

        let settings = UsagePanelSettings(
            defaults: defaults,
            readerNames: ["Codex"],
            refreshPricingCatalog: { isEnabled in
                let didChangePricing = await updater.refreshIfNeeded(isEnabled: isEnabled)
                if !isEnabled {
                    disabledRefreshFinished.fulfill()
                }
                return didChangePricing
            })

        settings.setAutoUpdatesModelPricing(true)
        await gate.waitUntilFirstRequestStarts()
        settings.setAutoUpdatesModelPricing(false)
        await fulfillment(of: [disabledRefreshFinished], timeout: 1)
        settings.setAutoUpdatesModelPricing(true)
        await gate.releaseFirstRequest(with: staleResponse)

        await fulfillment(of: [pricingChanged], timeout: 1)
        let requestCount = await gate.requestCount
        XCTAssertEqual(requestCount, 2)
        XCTAssertNil(modelPrice(for: "stale-model"))
        XCTAssertNotNil(modelPrice(for: "fresh-model"))
    }

    func test_defaultReaderNamesMatchAggregatorReaders() {
        let settingsReaderNames = UsagePanelSettings.defaultReaderNames
        XCTAssertEqual(settingsReaderNames, UsageAggregator.defaultReaders.map(\.name))
        XCTAssertTrue(settingsReaderNames.contains("GJC"))
        XCTAssertTrue(settingsReaderNames.contains("Hermes"))
        XCTAssertTrue(settingsReaderNames.contains("Remote Devices"))
    }

    private func makeDefaults() -> (String, UserDefaults) {
        let suiteName = "UsagePanelSettingsTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        return (suiteName, defaults)
    }
}

private actor SettingsPricingFetchGate {
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
