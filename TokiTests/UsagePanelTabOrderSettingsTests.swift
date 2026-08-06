import XCTest
@testable import Toki

@MainActor
final class UsagePanelTabOrderSettingsTests: XCTestCase {
    func test_tabOrderDefaultsToDeclaredOrder() {
        let (suiteName, defaults) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let settings = UsagePanelSettings(
            defaults: defaults,
            readerNames: ["Codex"],
            refreshPricingCatalog: { _ in false })

        XCTAssertEqual(settings.tabOrder, PanelTab.allCases)
        XCTAssertTrue(settings.isUsingDefaultTabOrder)
    }

    func test_tabOrderPersistsAcrossReload() {
        let (suiteName, defaults) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let settings = UsagePanelSettings(
            defaults: defaults,
            readerNames: ["Codex"],
            refreshPricingCatalog: { _ in false })
        let customOrder: [PanelTab] = [.hourly, .sources, .overview, .workTime, .byModel, .projects]
        settings.setTabOrder(customOrder)

        let reloaded = UsagePanelSettings(defaults: defaults, readerNames: ["Codex"])

        XCTAssertEqual(reloaded.tabOrder, customOrder)
        XCTAssertFalse(reloaded.isUsingDefaultTabOrder)
    }

    func test_tabOrderDropsUnknownAndDuplicateStoredValues() {
        let (suiteName, defaults) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        defaults.set(
            ["hourly", "retired-tab", "hourly", "sources"],
            forKey: "usagePanel.tabOrder")

        let settings = UsagePanelSettings(
            defaults: defaults,
            readerNames: ["Codex"],
            refreshPricingCatalog: { _ in false })

        XCTAssertEqual(Array(settings.tabOrder.prefix(2)), [.hourly, .sources])
        XCTAssertEqual(Set(settings.tabOrder), Set(PanelTab.allCases))
        XCTAssertEqual(settings.tabOrder.count, PanelTab.allCases.count)
    }

    func test_tabOrderAppendsTabsMissingFromStoredOrder() {
        let (suiteName, defaults) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        defaults.set(["sources", "overview"], forKey: "usagePanel.tabOrder")

        let settings = UsagePanelSettings(
            defaults: defaults,
            readerNames: ["Codex"],
            refreshPricingCatalog: { _ in false })

        let expectedTail = PanelTab.allCases.filter { tab in
            tab != .sources && tab != .overview
        }
        XCTAssertEqual(settings.tabOrder, [.sources, .overview] + expectedTail)
    }

    func test_resetTabOrderRestoresDeclaredOrder() {
        let (suiteName, defaults) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let settings = UsagePanelSettings(
            defaults: defaults,
            readerNames: ["Codex"],
            refreshPricingCatalog: { _ in false })
        settings.setTabOrder([.hourly, .sources, .overview, .workTime, .byModel, .projects])
        settings.resetTabOrder()

        XCTAssertEqual(settings.tabOrder, PanelTab.allCases)
        let reloaded = UsagePanelSettings(defaults: defaults, readerNames: ["Codex"])
        XCTAssertEqual(reloaded.tabOrder, PanelTab.allCases)
    }

    private func makeDefaults() -> (String, UserDefaults) {
        let suiteName = "UsagePanelTabOrderSettingsTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        return (suiteName, defaults)
    }
}
