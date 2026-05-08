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

    private func makeDefaults() -> (String, UserDefaults) {
        let suiteName = "UsageServiceDiagnosticsTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        return (suiteName, defaults)
    }
}
