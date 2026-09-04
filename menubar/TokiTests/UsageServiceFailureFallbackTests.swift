import TokiUsageCore
import XCTest
@testable import Toki

@MainActor
final class UsageServiceFailureFallbackTests: XCTestCase {
    func test_usageServicePreservesFallbackWhenOnlyEnabledReaderFails() async throws {
        let suiteName = "UsageServiceFailureFallbackTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let healthyState = FailingUsageReaderState(totalTokens: 100)
        let failingState = FailingUsageReaderState(totalTokens: 300)
        let settings = UsagePanelSettings(defaults: defaults, readerNames: ["Disabled", "Flaky"])
        settings.setReader("Disabled", isEnabled: false)
        let service = UsageService(
            readers: [
                FailingUsageReader(name: "Disabled", state: healthyState),
                FailingUsageReader(name: "Flaky", state: failingState),
            ],
            settings: settings)
        let pastDay = try XCTUnwrap(Calendar.current.date(byAdding: .day, value: -2, to: Date()))

        service.selectDay(pastDay)
        await service.refresh()
        await failingState.setShouldFail(true)
        await service.refresh()

        XCTAssertEqual(service.presentationSnapshot.combinedUsageData.totalTokens, 300)
        XCTAssertEqual(service.readerStatuses.first(where: { $0.name == "Disabled" })?.state, .disabled)
        XCTAssertEqual(service.readerStatuses.first(where: { $0.name == "Flaky" })?.state, .failed)
    }

    func test_usageServicePreservesFetchedAtWhenReusingFallback() async throws {
        let state = FailingUsageReaderState(totalTokens: 300)
        let clock = FallbackTestClock(now: tokiTestISODate("2026-09-04T12:00:00Z"))
        let service = UsageService(
            readers: [FailingUsageReader(name: "Flaky", state: state)],
            now: { clock.now })
        let pastDay = try XCTUnwrap(Calendar.current.date(byAdding: .day, value: -2, to: clock.now))

        service.selectDay(pastDay)
        await service.refresh()
        let successfulFetchTime = service.presentationSnapshot.lastFetchedAt
        clock.now = clock.now.addingTimeInterval(300)
        await state.setShouldFail(true)
        await service.refresh()

        XCTAssertEqual(service.presentationSnapshot.combinedUsageData.totalTokens, 300)
        XCTAssertEqual(service.presentationSnapshot.lastFetchedAt, successfulFetchTime)
    }

    func test_usageServiceSeedsFallbackFromCachedWindow() async throws {
        let suiteName = "UsageServiceFailureFallbackTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let state = FailingUsageReaderState(totalTokens: 300)
        let settings = UsagePanelSettings(defaults: defaults, readerNames: ["Flaky"])
        let service = UsageService(
            readers: [FailingUsageReader(name: "Flaky", state: state)],
            settings: settings)

        await service.refresh()
        settings.setCurrentUsageWindow(.rolling24Hours)
        _ = service.handleCurrentUsageWindowChange()
        await service.refresh()
        settings.setCurrentUsageWindow(.calendarDay)
        _ = service.handleCurrentUsageWindowChange()
        await state.setShouldFail(true)
        await service.refresh(usesWindowResultCache: true)

        XCTAssertEqual(service.presentationSnapshot.combinedUsageData.totalTokens, 300)
        XCTAssertEqual(service.readerStatuses.first?.state, .failed)
    }

    func test_usageServiceRetainsFallbackAcrossPresentationScopeChange() async throws {
        let state = FailingUsageReaderState(totalTokens: 300)
        let service = UsageService(readers: [FailingUsageReader(name: "Flaky", state: state)])
        let pastDay = try XCTUnwrap(Calendar.current.date(byAdding: .day, value: -2, to: Date()))

        service.selectDay(pastDay)
        await service.refresh()
        service.selectModelScope(.model("unavailable-model"))
        await state.setShouldFail(true)
        await service.refresh()

        XCTAssertEqual(service.presentationSnapshot.combinedUsageData.totalTokens, 300)
        XCTAssertEqual(service.readerStatuses.first?.state, .failed)
    }

    func test_usageServicePublishesFreshPartialUsageWhenOneReaderFails() async throws {
        let healthy = FailingUsageReader(name: "Healthy", state: FailingUsageReaderState(totalTokens: 300))
        let failingState = FailingUsageReaderState(totalTokens: 100)
        let failing = FailingUsageReader(name: "Flaky", state: failingState)
        let service = UsageService(readers: [healthy, failing])
        let pastDay = try XCTUnwrap(Calendar.current.date(byAdding: .day, value: -2, to: Date()))

        service.selectDay(pastDay)
        await service.refresh()
        await failingState.setShouldFail(true)
        await service.refresh()

        XCTAssertEqual(service.usageData.totalTokens, 300)
        XCTAssertEqual(service.readerStatuses.first(where: { $0.name == "Flaky" })?.state, .failed)
    }

    func test_usageServicePreservesPeriodTotalsWhenReaderFails() async throws {
        let suiteName = "UsageServiceFailureFallbackTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let state = FailingUsageReaderState(totalTokens: 300)
        let reader = FailingUsageReader(name: "Flaky", state: state)
        let cache = PeriodTokenTotalsCache(defaults: defaults)
        let service = UsageService(
            readers: [reader],
            periodTokenTotalsCache: cache)

        await service.refreshPeriodTokenTotals()
        let successfulSummaries = service.periodTokenTotals
        let successfulFetchedAt = try XCTUnwrap(service.lastPeriodTokenTotalsFetchedAt)
        let requestKey = try XCTUnwrap(service.lastPeriodTokenTotalsRequest?.cacheKey)
        let successfulCacheEntry = try XCTUnwrap(cache.entry(for: requestKey))
        await state.setShouldFail(true)
        await service.refreshPeriodTokenTotals()

        XCTAssertEqual(service.periodTokenTotals, successfulSummaries)
        XCTAssertEqual(service.periodTokenTotals.map(\.totalTokens), [300, 300, 300])
        XCTAssertEqual(service.lastPeriodTokenTotalsFetchedAt, successfulFetchedAt)
        XCTAssertEqual(cache.entry(for: requestKey), successfulCacheEntry)
        XCTAssertFalse(service.isLoadingPeriodTokenTotals)
    }

    func test_usageServicePublishesFreshPartialPeriodTotalsWhenOneReaderFails() async {
        let healthy = FailingUsageReader(name: "Healthy", state: FailingUsageReaderState(totalTokens: 300))
        let failingState = FailingUsageReaderState(totalTokens: 100)
        let service = UsageService(
            readers: [
                healthy,
                FailingUsageReader(name: "Flaky", state: failingState),
            ])

        await service.refreshPeriodTokenTotals()
        XCTAssertEqual(service.periodTokenTotals.map(\.totalTokens), [400, 400, 400])

        await failingState.setShouldFail(true)
        await service.refreshPeriodTokenTotals()

        XCTAssertEqual(service.periodTokenTotals.map(\.totalTokens), [300, 300, 300])
    }

    func test_usageServicePreservesRollingComparisonWhenClockAdvancesAndReadersFail() async throws {
        let suiteName = "UsageServiceFailureFallbackTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let clock = FallbackTestClock(now: tokiTestISODate("2026-09-04T12:00:00Z"))
        let state = FailingUsageReaderState(totalTokens: 300)
        let settings = UsagePanelSettings(defaults: defaults, readerNames: ["Flaky"])
        settings.setCurrentUsageWindow(.rolling24Hours)
        let service = UsageService(
            readers: [FailingUsageReader(name: "Flaky", state: state)],
            settings: settings,
            comparisonDebounce: .zero,
            now: { clock.now })

        await service.refresh()
        await waitForYesterdayTotal(300, in: service)
        let successfulFetchedAt = service.lastFetchedAt
        XCTAssertEqual(service.yesterdayTotalTokens, 300)

        clock.now = clock.now.addingTimeInterval(30)
        await state.setShouldFail(true)
        await service.refresh()
        await waitForRequestCount(4, state: state)

        XCTAssertEqual(service.usageData.totalTokens, 300)
        XCTAssertEqual(service.lastFetchedAt, successfulFetchedAt)
        XCTAssertEqual(service.yesterdayTotalTokens, 300)
        XCTAssertEqual(service.readerStatuses.first?.state, .failed)
    }

    func test_usageServicePreservesCachedRollingComparisonWhenClockAdvancesAndReadersFail() async throws {
        let suiteName = "UsageServiceFailureFallbackTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let clock = FallbackTestClock(now: tokiTestISODate("2026-09-04T12:00:00Z"))
        let state = FailingUsageReaderState(totalTokens: 300)
        let settings = UsagePanelSettings(defaults: defaults, readerNames: ["Flaky"])
        settings.setCurrentUsageWindow(.rolling24Hours)
        let cache = UsageWindowResultCache()
        let initialService = UsageService(
            readers: [FailingUsageReader(name: "Flaky", state: state)],
            settings: settings,
            usageWindowResultCache: cache,
            comparisonDebounce: .zero,
            now: { clock.now })

        await initialService.refresh()
        await waitForYesterdayTotal(300, in: initialService)
        let successfulFetchedAt = initialService.lastFetchedAt
        XCTAssertEqual(initialService.yesterdayTotalTokens, 300)

        clock.now = clock.now.addingTimeInterval(30)
        await state.setShouldFail(true)
        let restoredService = UsageService(
            readers: [FailingUsageReader(name: "Flaky", state: state)],
            settings: settings,
            usageWindowResultCache: cache,
            comparisonDebounce: .zero,
            now: { clock.now })
        await restoredService.refresh(usesWindowResultCache: true)
        await waitForRequestCount(4, state: state)

        XCTAssertEqual(restoredService.usageData.totalTokens, 300)
        XCTAssertEqual(restoredService.lastFetchedAt, successfulFetchedAt)
        XCTAssertEqual(restoredService.yesterdayTotalTokens, 300)
        XCTAssertEqual(restoredService.readerStatuses.first?.state, .failed)
    }

    private func waitForYesterdayTotal(_ expected: Int, in service: UsageService) async {
        let deadline = Date().addingTimeInterval(2)
        while service.yesterdayTotalTokens != expected, Date() < deadline {
            try? await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(service.yesterdayTotalTokens, expected)
    }

    private func waitForRequestCount(_ target: Int, state: FailingUsageReaderState) async {
        let deadline = Date().addingTimeInterval(2)
        while await state.requestCount() < target, Date() < deadline {
            try? await Task.sleep(for: .milliseconds(10))
        }
        let requestCount = await state.requestCount()
        XCTAssertGreaterThanOrEqual(requestCount, target)
    }
}

@MainActor
final class UsageScopedFailureFallbackTests: XCTestCase {
    func test_usageServicePreservesSelectedRemoteUsageWhenRemoteReaderFails() async throws {
        let suiteName = "UsageScopedFailureFallbackTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let remoteID = UsageOriginID.remote(deviceID: "remote-a")
        let remoteState = FailingOriginUsageReaderState(totalTokens: 300)
        let service = UsageService(
            readers: [
                FailingUsageReader(
                    name: "Local",
                    state: FailingUsageReaderState(totalTokens: 500)),
                FailingOriginUsageReader(name: "Remote Devices", state: remoteState),
            ],
            settings: UsagePanelSettings(
                defaults: defaults,
                readerNames: ["Local", "Remote Devices"]))
        let pastDay = try XCTUnwrap(Calendar.current.date(byAdding: .day, value: -2, to: Date()))

        service.selectDay(pastDay)
        await service.refresh()
        service.selectUsageScope(.origin(remoteID))
        let successfulFetchedAt = service.lastFetchedAt
        XCTAssertEqual(service.usageData.totalTokens, 300)

        await remoteState.setShouldFail(true)
        await service.refresh()

        XCTAssertEqual(service.selectedUsageScope, .origin(remoteID))
        XCTAssertEqual(service.usageData.totalTokens, 300)
        XCTAssertEqual(service.lastFetchedAt, successfulFetchedAt)
        XCTAssertEqual(service.readerStatuses.first(where: { $0.name == "Remote Devices" })?.state, .failed)
    }

    func test_usageServicePublishesLocalComparisonWhenRemoteReaderFails() async throws {
        let suiteName = "UsageScopedFailureFallbackTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let remoteState = FailingOriginUsageReaderState(totalTokens: 500)
        let service = UsageService(
            readers: [
                FailingUsageReader(
                    name: "Local",
                    state: FailingUsageReaderState(totalTokens: 300)),
                FailingOriginUsageReader(name: "Remote Devices", state: remoteState),
            ],
            settings: UsagePanelSettings(
                defaults: defaults,
                readerNames: ["Local", "Remote Devices"]),
            comparisonDebounce: .zero)

        await service.refresh()
        await waitForYesterdayTotal(800, in: service)
        await remoteState.setShouldFail(true)
        service.selectUsageScope(.origin(.local))
        await waitForYesterdayTotal(300, in: service)

        XCTAssertEqual(service.selectedUsageScope, .origin(.local))
        XCTAssertEqual(service.yesterdayTotalTokens, 300)
    }

    private func waitForYesterdayTotal(_ expected: Int, in service: UsageService) async {
        let deadline = Date().addingTimeInterval(2)
        while service.yesterdayTotalTokens != expected, Date() < deadline {
            try? await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(service.yesterdayTotalTokens, expected)
    }
}

@MainActor
final class UsageScopedPeriodFallbackTests: XCTestCase {
    func test_usageServiceClearsPeriodTotalsWhenDifferentReaderRequestFails() async throws {
        let suiteName = "UsageScopedPeriodFallbackTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let failingState = FailingUsageReaderState(totalTokens: 100)
        let settings = UsagePanelSettings(defaults: defaults, readerNames: ["Healthy", "Flaky"])
        let service = UsageService(
            readers: [
                FailingUsageReader(
                    name: "Healthy",
                    state: FailingUsageReaderState(totalTokens: 300)),
                FailingUsageReader(name: "Flaky", state: failingState),
            ],
            settings: settings,
            periodTokenTotalsCache: PeriodTokenTotalsCache(defaults: defaults))

        await service.refreshPeriodTokenTotals()
        XCTAssertEqual(service.periodTokenTotals.map(\.totalTokens), [400, 400, 400])

        settings.setReader("Healthy", isEnabled: false)
        await failingState.setShouldFail(true)
        await service.refreshPeriodTokenTotalsIfNeeded()

        XCTAssertTrue(service.periodTokenTotals.isEmpty)
        XCTAssertNil(service.lastPeriodTokenTotalsRequest)
        XCTAssertNil(service.lastPeriodTokenTotalsFetchedAt)
        XCTAssertFalse(service.isLoadingPeriodTokenTotals)
    }

    func test_usageServicePreservesRemotePeriodTotalsWhenRemoteReaderFails() async throws {
        let suiteName = "UsageScopedPeriodFallbackTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let remoteID = UsageOriginID.remote(deviceID: "remote-a")
        let remoteState = FailingOriginUsageReaderState(totalTokens: 300)
        let service = UsageService(
            readers: [
                FailingUsageReader(
                    name: "Local",
                    state: FailingUsageReaderState(totalTokens: 500)),
                FailingOriginUsageReader(name: "Remote Devices", state: remoteState),
            ],
            settings: UsagePanelSettings(
                defaults: defaults,
                readerNames: ["Local", "Remote Devices"]),
            periodTokenTotalsCache: PeriodTokenTotalsCache(defaults: defaults))
        let pastDay = try XCTUnwrap(Calendar.current.date(byAdding: .day, value: -2, to: Date()))

        service.selectDay(pastDay)
        await service.refresh()
        service.selectUsageScope(.origin(remoteID))
        await waitForPeriodTotals([300, 300, 300], in: service)
        let successfulFetchedAt = service.lastPeriodTokenTotalsFetchedAt

        await remoteState.setShouldFail(true)
        await service.refreshPeriodTokenTotals()

        XCTAssertEqual(service.periodTokenTotals.map(\.totalTokens), [300, 300, 300])
        XCTAssertEqual(service.lastPeriodTokenTotalsFetchedAt, successfulFetchedAt)
    }

    func test_usageServicePreservesLocalPeriodTotalsWhenLocalReaderFails() async throws {
        let suiteName = "UsageScopedPeriodFallbackTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let localState = FailingUsageReaderState(totalTokens: 300)
        let service = UsageService(
            readers: [
                FailingUsageReader(name: "Local", state: localState),
                FailingOriginUsageReader(
                    name: "Remote Devices",
                    state: FailingOriginUsageReaderState(totalTokens: 500)),
            ],
            settings: UsagePanelSettings(
                defaults: defaults,
                readerNames: ["Local", "Remote Devices"]),
            periodTokenTotalsCache: PeriodTokenTotalsCache(defaults: defaults))
        let pastDay = try XCTUnwrap(Calendar.current.date(byAdding: .day, value: -2, to: Date()))

        service.selectDay(pastDay)
        await service.refresh()
        service.selectUsageScope(.origin(.local))
        await waitForPeriodTotals([300, 300, 300], in: service)
        let successfulFetchedAt = service.lastPeriodTokenTotalsFetchedAt

        await localState.setShouldFail(true)
        await service.refreshPeriodTokenTotals()

        XCTAssertEqual(service.periodTokenTotals.map(\.totalTokens), [300, 300, 300])
        XCTAssertEqual(service.lastPeriodTokenTotalsFetchedAt, successfulFetchedAt)
    }

    private func waitForPeriodTotals(_ totals: [Int], in service: UsageService) async {
        let deadline = Date().addingTimeInterval(2)
        while service.periodTokenTotals.map(\.totalTokens) != totals
            || service.isLoadingPeriodTokenTotals, Date() < deadline {
            try? await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(service.periodTokenTotals.map(\.totalTokens), totals)
        XCTAssertFalse(service.isLoadingPeriodTokenTotals)
    }
}

@MainActor
private final class FallbackTestClock {
    var now: Date

    init(now: Date) {
        self.now = now
    }
}

private actor FailingUsageReaderState {
    private let totalTokens: Int
    private var shouldFail = false
    private var readCount = 0

    init(totalTokens: Int) {
        self.totalTokens = totalTokens
    }

    func readTotalTokens() throws -> Int {
        readCount += 1
        if shouldFail {
            throw FailingUsageReaderError.unavailable
        }
        return totalTokens
    }

    func requestCount() -> Int {
        readCount
    }

    func setShouldFail(_ shouldFail: Bool) {
        self.shouldFail = shouldFail
    }
}

private actor FailingOriginUsageReaderState {
    private let slices: [UsageOriginSlice]
    private var shouldFail = false

    init(totalTokens: Int) {
        slices = [
            UsageOriginSlice(
                origin: .remote(
                    deviceID: "remote-a",
                    name: "worker",
                    platform: "linux",
                    lastUpdatedAt: nil),
                usage: mockUsage(totalTokens: totalTokens),
                sourceStats: []),
        ]
    }

    func readUsageByOrigin() throws -> [UsageOriginSlice] {
        if shouldFail {
            throw FailingUsageReaderError.unavailable
        }
        return slices
    }

    func setShouldFail(_ shouldFail: Bool) {
        self.shouldFail = shouldFail
    }
}

private struct FailingUsageReader: TokenReader {
    let name: String
    let state: FailingUsageReaderState

    func readUsage(from startDate: Date, to endDate: Date) async throws -> RawTokenUsage {
        try await mockUsage(totalTokens: state.readTotalTokens())
    }
}

private struct FailingOriginUsageReader: OriginPartitionedTokenReader {
    let name: String
    let state: FailingOriginUsageReaderState

    func readUsageByOrigin(from _: Date, to _: Date) async throws -> [UsageOriginSlice] {
        try await state.readUsageByOrigin()
    }
}

private enum FailingUsageReaderError: LocalizedError {
    case unavailable

    var errorDescription: String? {
        "Fixture reader unavailable"
    }
}
