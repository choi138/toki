import XCTest
@testable import Toki

@MainActor
final class UsagePanelSettingsTests: XCTestCase {
    func test_defaultsUseExpectedValues() {
        let (suiteName, defaults) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let settings = UsagePanelSettings(defaults: defaults, readerNames: ["Codex", "Cursor"])

        XCTAssertEqual(settings.refreshIntervalSeconds, 180)
        XCTAssertEqual(settings.enabledReaderNames, ["Codex": true, "Cursor": true])
        XCTAssertFalse(settings.showsZeroSourceRows)
    }

    func test_persistsChanges() {
        let (suiteName, defaults) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let settings = UsagePanelSettings(defaults: defaults, readerNames: ["Codex", "Cursor"])

        settings.refreshIntervalSeconds = 300
        settings.setReader("Cursor", isEnabled: false)
        settings.showsZeroSourceRows = true

        let reloaded = UsagePanelSettings(defaults: defaults, readerNames: ["Codex", "Cursor"])

        XCTAssertEqual(reloaded.refreshIntervalSeconds, 300)
        XCTAssertTrue(reloaded.isReaderEnabled("Codex"))
        XCTAssertFalse(reloaded.isReaderEnabled("Cursor"))
        XCTAssertTrue(reloaded.showsZeroSourceRows)
    }

    func test_normalizesUnsupportedRefreshInterval() {
        let (suiteName, defaults) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let settings = UsagePanelSettings(defaults: defaults, readerNames: ["Codex"])

        settings.refreshIntervalSeconds = 999

        XCTAssertEqual(settings.refreshIntervalSeconds, 180)
    }

    private func makeDefaults() -> (String, UserDefaults) {
        let suiteName = "UsagePanelSettingsTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        return (suiteName, defaults)
    }
}
