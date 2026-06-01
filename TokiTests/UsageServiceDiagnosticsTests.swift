import XCTest
@testable import Toki

@MainActor
final class UsageServiceDiagnosticsTests: XCTestCase {
    func test_usageService_buildsSourceStatsAndReaderStatuses() async {
        let reader = MockReader(name: "Codex", recorder: MockReaderRecorder()) { _, _ in
            var usage = RawTokenUsage()
            usage.inputTokens = 100
            usage.outputTokens = 20
            usage.cost = 0.42
            usage.activeSeconds = 90
            return usage
        }

        let service = UsageService(readers: [reader])
        await service.refresh()

        XCTAssertEqual(service.readerStatuses.map(\.name), ["Codex"])
        XCTAssertEqual(service.readerStatuses.first?.state, .loaded)
        XCTAssertEqual(service.readerStatuses.first?.totalTokens, 120)
        XCTAssertEqual(service.usageData.sourceStats.first?.source, "Codex")
        XCTAssertEqual(service.usageData.sourceStats.first?.totalTokens, 120)
        XCTAssertEqual(service.usageData.sourceStats.first?.cost ?? 0, 0.42, accuracy: 0.000001)
    }

    func test_usageService_skipsDisabledReaders() async {
        let (suiteName, defaults) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let enabledRecorder = MockReaderRecorder()
        let disabledRecorder = MockReaderRecorder()
        let enabled = MockReader(name: "Enabled", recorder: enabledRecorder) { _, _ in
            mockUsage(totalTokens: 10)
        }
        let disabled = MockReader(name: "Disabled", recorder: disabledRecorder) { _, _ in
            mockUsage(totalTokens: 999)
        }
        let settings = UsagePanelSettings(
            defaults: defaults,
            readerNames: ["Enabled", "Disabled"])
        settings.setReader("Disabled", isEnabled: false)

        let service = UsageService(readers: [enabled, disabled], settings: settings)
        await service.refresh()

        let enabledCalls = await enabledRecorder.snapshot()
        let disabledCalls = await disabledRecorder.snapshot()

        XCTAssertEqual(enabledCalls.count, 1)
        XCTAssertEqual(disabledCalls.count, 0)
        XCTAssertEqual(service.usageData.totalTokens, 10)
        XCTAssertEqual(service.readerStatuses.map(\.state), [.loaded, .disabled])
    }

    func test_usageService_reloadsWhenReaderSettingsChangeDuringSameRangeLoad() async throws {
        let (suiteName, defaults) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let gate = BlockingReaderGate()
        let today = Calendar.current.startOfDay(for: Date())
        let pastDay = try XCTUnwrap(Calendar.current.date(byAdding: .day, value: -3, to: today))
        let enabled = BlockingMockReader(name: "Enabled", gate: gate) { _, _ in
            mockUsage(totalTokens: 10)
        }
        let disabled = BlockingMockReader(name: "Disabled", gate: gate) { _, _ in
            mockUsage(totalTokens: 999)
        }
        let settings = UsagePanelSettings(
            defaults: defaults,
            readerNames: ["Enabled", "Disabled"])

        let service = UsageService(readers: [enabled, disabled], settings: settings)
        service.selectDay(pastDay)
        let initialRefresh = Task { await service.refresh() }

        await gate.waitForRequestCount(2)
        settings.setReader("Disabled", isEnabled: false)
        await service.refresh()
        await gate.release()
        await initialRefresh.value

        var totalTokens = service.usageData.totalTokens
        let deadline = Date().addingTimeInterval(2)
        while totalTokens != 10, Date() < deadline {
            try? await Task.sleep(for: .milliseconds(20))
            totalTokens = service.usageData.totalTokens
        }

        let requestCount = await gate.requestCountSnapshot()

        XCTAssertEqual(requestCount, 3)
        XCTAssertEqual(totalTokens, 10)
        XCTAssertEqual(service.readerStatuses.map(\.state), [.loaded, .disabled])
    }

    func test_usageReportBuildsHourlyTokenBucketsAndPeak() throws {
        let calendar = Calendar.current
        let startDate = calendar.startOfDay(for: tokiTestISODate("2026-04-10T12:00:00Z"))
        let endDate = try XCTUnwrap(calendar.date(byAdding: .day, value: 1, to: startDate))
        let firstHour = try XCTUnwrap(calendar.date(byAdding: .hour, value: 2, to: startDate))
        let secondHour = try XCTUnwrap(calendar.date(byAdding: .hour, value: 3, to: startDate))

        var rawUsage = RawTokenUsage()
        rawUsage.inputTokens = 460
        rawUsage.outputTokens = 65
        try rawUsage.recordTokenEvent(
            timestamp: XCTUnwrap(calendar.date(byAdding: .minute, value: 5, to: firstHour)),
            source: "Mock",
            model: "gpt-5.4",
            inputTokens: 100,
            outputTokens: 20,
            cost: 0.1)
        try rawUsage.recordTokenEvent(
            timestamp: XCTUnwrap(calendar.date(byAdding: .minute, value: 35, to: firstHour)),
            source: "Mock",
            model: "gpt-5.4",
            inputTokens: 50,
            outputTokens: 10,
            cost: 0.05)
        rawUsage.recordTokenEvent(
            timestamp: secondHour,
            source: "Mock",
            model: "gpt-5.4",
            inputTokens: 310,
            outputTokens: 35,
            cost: 0.2)

        let report = UsageReportBuilder.report(
            from: rawUsage,
            date: startDate,
            endDate: endDate,
            sourceStats: [])

        XCTAssertEqual(report.timeBuckets.count, 24)
        XCTAssertEqual(
            report.timeBuckets.first(where: { $0.startDate == firstHour })?.totalTokens,
            180)
        XCTAssertEqual(
            report.timeBuckets.first(where: { $0.startDate == secondHour })?.totalTokens,
            345)
        XCTAssertEqual(report.peakTokenBucket?.startDate, secondHour)
        XCTAssertEqual(report.peakTokenBucket?.totalTokens, 345)
    }

    func test_usageReportSkipsHourlyBucketsForLongRanges() throws {
        let calendar = Calendar.current
        let startDate = calendar.startOfDay(for: tokiTestISODate("2026-04-10T12:00:00Z"))
        let endDate = try XCTUnwrap(calendar.date(byAdding: .day, value: 30, to: startDate))

        var rawUsage = RawTokenUsage()
        rawUsage.inputTokens = 100
        rawUsage.recordTokenEvent(
            timestamp: startDate,
            source: "Mock",
            model: "gpt-5.4",
            inputTokens: 100,
            outputTokens: 0)

        let report = UsageReportBuilder.report(
            from: rawUsage,
            date: startDate,
            endDate: endDate,
            sourceStats: [])

        XCTAssertTrue(report.timeBuckets.isEmpty)
        XCTAssertNil(report.peakTokenBucket)
    }

    private func makeDefaults() -> (String, UserDefaults) {
        let suiteName = "UsageServiceDiagnosticsTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        return (suiteName, defaults)
    }
}

@MainActor
final class UsageServicePeriodTotalsTests: XCTestCase {
    func test_usageService_loadsPeriodTokenTotalsWithLightweightRequests() async throws {
        let (suiteName, defaults) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let recorder = PeriodTokenRangeRecorder()
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        let tomorrow = try XCTUnwrap(calendar.date(byAdding: .day, value: 1, to: today))
        let pastDay = try XCTUnwrap(calendar.date(byAdding: .day, value: -3, to: today))
        let last7Start = try XCTUnwrap(calendar.date(byAdding: .day, value: -7, to: tomorrow))
        let last30Start = try XCTUnwrap(calendar.date(byAdding: .day, value: -30, to: tomorrow))
        let allTimeStart = calendar.startOfDay(for: Date(timeIntervalSince1970: 0))
        let reader = PeriodTokenTotalsReader(name: "Mock", recorder: recorder) { startDate, _ in
            if startDate == last7Start { return 700 }
            if startDate == last30Start { return 3000 }
            if startDate == allTimeStart { return 9000 }
            return -1
        }

        let service = UsageService(
            readers: [reader],
            periodTokenTotalsCache: PeriodTokenTotalsCache(defaults: defaults))
        service.selectDay(pastDay)
        await service.refresh()
        await service.refreshPeriodTokenTotals()

        let summariesByPeriod = Dictionary(
            uniqueKeysWithValues: service.periodTokenTotals.map { ($0.period, $0) })
        let calls = await recorder.snapshot()

        XCTAssertEqual(service.usageData.totalTokens, 55)
        XCTAssertEqual(summariesByPeriod[.last7Days]?.totalTokens, 700)
        XCTAssertEqual(summariesByPeriod[.last30Days]?.totalTokens, 3000)
        XCTAssertEqual(summariesByPeriod[.allTime]?.totalTokens, 9000)
        XCTAssertEqual(calls.usage.map(\.start), [pastDay])
        XCTAssertEqual(calls.total.map(\.start), [last7Start, last30Start, allTimeStart])
        XCTAssertEqual(calls.total.map(\.end), [tomorrow, tomorrow, tomorrow])
    }

    func test_usageService_periodTokenTotalsSkipDisabledReaders() async {
        let (suiteName, defaults) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let enabledRecorder = PeriodTokenRangeRecorder()
        let disabledRecorder = PeriodTokenRangeRecorder()
        let enabled = PeriodTokenTotalsReader(name: "Enabled", recorder: enabledRecorder) { _, _ in
            10
        }
        let disabled = PeriodTokenTotalsReader(name: "Disabled", recorder: disabledRecorder) { _, _ in
            999
        }
        let settings = UsagePanelSettings(
            defaults: defaults,
            readerNames: ["Enabled", "Disabled"])
        settings.setReader("Disabled", isEnabled: false)
        let cache = PeriodTokenTotalsCache(defaults: defaults)

        let service = UsageService(
            readers: [enabled, disabled],
            settings: settings,
            periodTokenTotalsCache: cache)
        await service.refreshPeriodTokenTotals()

        let enabledCalls = await enabledRecorder.snapshot()
        let disabledCalls = await disabledRecorder.snapshot()

        XCTAssertEqual(service.periodTokenTotals.map(\.totalTokens), [10, 10, 10])
        XCTAssertEqual(enabledCalls.total.count, 3)
        XCTAssertTrue(enabledCalls.usage.isEmpty)
        XCTAssertTrue(disabledCalls.total.isEmpty)
        XCTAssertTrue(disabledCalls.usage.isEmpty)
    }

    func test_usageService_periodTokenTotalsUsesFreshCacheWithoutReaderCalls() async {
        let (suiteName, defaults) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let cache = PeriodTokenTotalsCache(defaults: defaults)
        let seedRecorder = PeriodTokenRangeRecorder()
        let seedReader = PeriodTokenTotalsReader(name: "Mock", recorder: seedRecorder) { _, _ in
            42
        }
        let seedService = UsageService(
            readers: [seedReader],
            periodTokenTotalsCache: cache)
        await seedService.refreshPeriodTokenTotals()

        let cachedRecorder = PeriodTokenRangeRecorder()
        let cachedReader = PeriodTokenTotalsReader(name: "Mock", recorder: cachedRecorder) { _, _ in
            999
        }
        let cachedService = UsageService(
            readers: [cachedReader],
            periodTokenTotalsCache: cache)
        await cachedService.refreshPeriodTokenTotalsIfNeeded()

        let cachedCalls = await cachedRecorder.snapshot()

        XCTAssertEqual(cachedService.periodTokenTotals.map(\.totalTokens), [42, 42, 42])
        XCTAssertTrue(cachedCalls.total.isEmpty)
        XCTAssertTrue(cachedCalls.usage.isEmpty)
    }

    func test_usageService_discardsStalePeriodTokenTotalsWhenReaderSettingsChangeDuringLoad() async {
        let (suiteName, defaults) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let gate = BlockingReaderGate()
        let enabled = BlockingPeriodTokenTotalsReader(name: "Enabled", gate: gate) { _, _ in
            10
        }
        let disabled = BlockingPeriodTokenTotalsReader(name: "Disabled", gate: gate) { _, _ in
            999
        }
        let settings = UsagePanelSettings(
            defaults: defaults,
            readerNames: ["Enabled", "Disabled"])

        let service = UsageService(readers: [enabled, disabled], settings: settings)
        let initialRefresh = Task {
            await service.refreshPeriodTokenTotals()
        }

        await gate.waitForRequestCount(2)
        settings.setReader("Disabled", isEnabled: false)
        await gate.release()
        await initialRefresh.value

        XCTAssertEqual(service.periodTokenTotals.map(\.totalTokens), [10, 10, 10])
        XCTAssertFalse(service.isLoadingPeriodTokenTotals)
    }

    private func makeDefaults() -> (String, UserDefaults) {
        let suiteName = "UsageServicePeriodTotalsTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        return (suiteName, defaults)
    }
}

private actor PeriodTokenRangeRecorder {
    private var usageRanges: [(start: Date, end: Date)] = []
    private var totalRanges: [(start: Date, end: Date)] = []

    func recordUsage(start: Date, end: Date) {
        usageRanges.append((start: start, end: end))
    }

    func recordTotal(start: Date, end: Date) {
        totalRanges.append((start: start, end: end))
    }

    func snapshot() -> (usage: [(start: Date, end: Date)], total: [(start: Date, end: Date)]) {
        (usageRanges, totalRanges)
    }
}

private struct PeriodTokenTotalsReader: TokenReader {
    let name: String
    let recorder: PeriodTokenRangeRecorder
    let totalTokenHandler: @Sendable (Date, Date) -> Int

    func readUsage(from startDate: Date, to endDate: Date) async throws -> RawTokenUsage {
        await recorder.recordUsage(start: startDate, end: endDate)
        return mockUsage(totalTokens: 55)
    }

    func readTotalTokens(from startDate: Date, to endDate: Date) async throws -> Int {
        await recorder.recordTotal(start: startDate, end: endDate)
        return totalTokenHandler(startDate, endDate)
    }
}

private struct BlockingPeriodTokenTotalsReader: TokenReader {
    let name: String
    let gate: BlockingReaderGate
    let totalTokenHandler: @Sendable (Date, Date) -> Int

    func readUsage(from startDate: Date, to endDate: Date) async throws -> RawTokenUsage {
        mockUsage(totalTokens: totalTokenHandler(startDate, endDate))
    }

    func readTotalTokens(from startDate: Date, to endDate: Date) async throws -> Int {
        await gate.enter()
        return totalTokenHandler(startDate, endDate)
    }
}
