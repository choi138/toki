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
        rawUsage.recordTokenEvent(
            timestamp: try XCTUnwrap(calendar.date(byAdding: .minute, value: 5, to: firstHour)),
            source: "Mock",
            model: "gpt-5.4",
            inputTokens: 100,
            outputTokens: 20,
            cost: 0.1)
        rawUsage.recordTokenEvent(
            timestamp: try XCTUnwrap(calendar.date(byAdding: .minute, value: 35, to: firstHour)),
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

    private func makeDefaults() -> (String, UserDefaults) {
        let suiteName = "UsageServiceDiagnosticsTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        return (suiteName, defaults)
    }
}
