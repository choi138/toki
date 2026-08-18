import Foundation
import XCTest
@testable import Toki

/// Bumping the cache key leaves the previous entry unreachable but still stored, so historical
/// token totals and origin metadata would outlive the app's own cache cleanup.
final class PeriodTokenTotalsCacheTests: XCTestCase {
    private let legacyKey = "usagePanel.periodTokenTotalsCache.v2"

    func test_initializationRemovesTheSupersededEntry() throws {
        let suiteName = "PeriodTokenTotalsCacheTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set(Data("legacy-token-totals".utf8), forKey: legacyKey)

        _ = PeriodTokenTotalsCache(defaults: defaults)

        XCTAssertNil(defaults.data(forKey: legacyKey))
    }

    func test_clearRemovesBothCurrentAndSupersededEntries() throws {
        let suiteName = "PeriodTokenTotalsCacheTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let cache = PeriodTokenTotalsCache(defaults: defaults)
        // Re-seed after initialization to prove clear() also removes it.
        defaults.set(Data("legacy-token-totals".utf8), forKey: legacyKey)
        cache.store(
            [],
            for: PeriodTokenTotalsCacheKey(
                endDate: Date(timeIntervalSince1970: 1_780_000_000),
                enabledReaderNames: [:],
                scope: .all,
                modelScope: .all))
        XCTAssertNotNil(defaults.data(forKey: "usagePanel.periodTokenTotalsCache.v3"))

        cache.clear()

        XCTAssertNil(defaults.data(forKey: "usagePanel.periodTokenTotalsCache.v3"))
        XCTAssertNil(defaults.data(forKey: legacyKey))
    }
}
