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
        XCTAssertTrue(UsagePanelSettings.isAutoUpdatePricingEnabled(defaults: defaults))
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

        let reloaded = UsagePanelSettings(defaults: defaults, readerNames: ["Codex", "Cursor"])

        XCTAssertEqual(reloaded.refreshIntervalSeconds, 300)
        XCTAssertTrue(reloaded.isReaderEnabled("Codex"))
        XCTAssertFalse(reloaded.isReaderEnabled("Cursor"))
        XCTAssertTrue(reloaded.showsZeroSourceRows)
        XCTAssertFalse(reloaded.autoUpdatesModelPricing)
        XCTAssertFalse(UsagePanelSettings.isAutoUpdatePricingEnabled(defaults: defaults))
    }

    func test_normalizesUnsupportedRefreshInterval() {
        let (suiteName, defaults) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let settings = UsagePanelSettings(defaults: defaults, readerNames: ["Codex"])

        settings.refreshIntervalSeconds = 999

        XCTAssertEqual(settings.refreshIntervalSeconds, 180)
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
