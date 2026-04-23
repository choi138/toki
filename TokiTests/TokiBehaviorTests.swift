import XCTest
@testable import Toki

final class UsageServiceBehaviorTests: XCTestCase {
    func test_usageService_skipsYesterdayFetchForPastSingleDay() async throws {
        let recorder = MockReaderRecorder()
        let today = Calendar.current.startOfDay(for: Date())
        let pastDay = try XCTUnwrap(Calendar.current.date(byAdding: .day, value: -7, to: today))
        let reader = MockReader(name: "Mock", recorder: recorder) { startDate, _ in
            mockUsage(totalTokens: startDate == pastDay ? 42 : 7)
        }

        let service = await MainActor.run { UsageService(readers: [reader]) }
        await MainActor.run { service.selectDay(pastDay) }
        await service.refresh()

        let calls = await recorder.snapshot()
        let yesterdayTotal = await MainActor.run { service.yesterdayTotalTokens }
        XCTAssertEqual(calls.count, 1)
        XCTAssertEqual(calls.first?.start, pastDay)
        XCTAssertNil(yesterdayTotal)
    }

    func test_usageService_preservesZeroYesterdayTotalForTodayComparison() async throws {
        let recorder = MockReaderRecorder()
        let today = Calendar.current.startOfDay(for: Date())
        let yesterday = try XCTUnwrap(Calendar.current.date(byAdding: .day, value: -1, to: today))
        let reader = MockReader(name: "Mock", recorder: recorder) { startDate, _ in
            switch startDate {
            case today:
                mockUsage(totalTokens: 120)
            case yesterday:
                mockUsage(totalTokens: 0)
            default:
                mockUsage(totalTokens: 5)
            }
        }

        let service = await MainActor.run { UsageService(readers: [reader]) }
        await service.refresh()

        let calls = await recorder.snapshot()
        let yesterdayTotal = await MainActor.run { service.yesterdayTotalTokens }
        let shouldCompare = await MainActor.run { service.shouldCompareAgainstYesterday }
        XCTAssertEqual(calls.count, 2)
        XCTAssertEqual(calls.first?.start, today)
        XCTAssertEqual(calls.last?.start, yesterday)
        XCTAssertEqual(yesterdayTotal, 0)
        XCTAssertTrue(shouldCompare)
    }

    func test_usageService_retriesRefreshAfterRangeChangesDuringLoad() async throws {
        let gate = BlockingReaderGate()
        let today = Calendar.current.startOfDay(for: Date())
        let firstDay = try XCTUnwrap(Calendar.current.date(byAdding: .day, value: -2, to: today))
        let secondDay = try XCTUnwrap(Calendar.current.date(byAdding: .day, value: -1, to: today))
        let reader = BlockingMockReader(name: "Mock", gate: gate) { startDate, _ in
            mockUsage(totalTokens: startDate == firstDay ? 100 : 200)
        }

        let service = await MainActor.run { UsageService(readers: [reader]) }
        await MainActor.run { service.selectDay(firstDay) }
        let initialRefresh = Task { await service.refresh() }

        await gate.waitForFirstRequest()
        await MainActor.run { service.selectDay(secondDay) }
        await service.refresh()
        await gate.release()
        await initialRefresh.value
        await gate.waitForRequestCount(2)

        var totalTokens = await MainActor.run { service.usageData.totalTokens }
        var date = await MainActor.run { service.usageData.date }

        for _ in 0..<20 where totalTokens != 200 {
            try? await Task.sleep(for: .milliseconds(10))
            totalTokens = await MainActor.run { service.usageData.totalTokens }
            date = await MainActor.run { service.usageData.date }
        }

        XCTAssertEqual(totalTokens, 200)
        XCTAssertEqual(date, secondDay)
    }

    func test_usageService_sortsModelsByActiveTime() async {
        let recorder = MockReaderRecorder()
        let reader = MockReader(name: "Mock", recorder: recorder) { _, _ in
            var usage = RawTokenUsage()
            usage.inputTokens = 300
            usage.activeSeconds = 540
            usage.perModel["gpt-5.4"] = PerModelUsage(
                totalTokens: 120,
                cost: 1.2,
                activeSeconds: 180,
                sources: ["Mock"])
            usage.perModel["claude-sonnet-4-6"] = PerModelUsage(
                totalTokens: 90,
                cost: 0.8,
                activeSeconds: 360,
                sources: ["Mock"])
            return usage
        }

        let service = await MainActor.run { UsageService(readers: [reader]) }
        await service.refresh()

        let models = await MainActor.run { service.usageData.perModel }
        let activeSeconds = await MainActor.run { service.usageData.activeSeconds }

        XCTAssertEqual(models.map(\.id), ["claude-sonnet-4-6", "gpt-5.4"])
        XCTAssertEqual(models.first?.activeSeconds ?? 0, 360, accuracy: 0.001)
        XCTAssertEqual(models.last?.activeSeconds ?? 0, 180, accuracy: 0.001)
        XCTAssertEqual(activeSeconds, 540, accuracy: 0.001)
    }

    func test_usageService_keepsContextOnlyMetricsOutOfTotalTokens() async {
        let recorder = MockReaderRecorder()
        let reader = MockReader(name: "Mock", recorder: recorder) { _, _ in
            var usage = RawTokenUsage()
            usage.inputTokens = 100
            usage.supplemental = [
                SupplementalUsage(
                    id: "cursor-context-a",
                    label: "Cursor Context",
                    value: 3000,
                    unit: .tokens,
                    source: "Cursor",
                    model: "gpt-5.4-xhigh",
                    includedInTotals: false,
                    quality: .contextOnly),
                SupplementalUsage(
                    id: "cursor-context-b",
                    label: "Cursor Context",
                    value: 2000,
                    unit: .tokens,
                    source: "Cursor",
                    model: "gpt-5.4-medium",
                    includedInTotals: false,
                    quality: .contextOnly),
                SupplementalUsage(
                    id: "cursor-session-a",
                    label: "Cursor Sessions",
                    value: 1,
                    unit: .count,
                    source: "Cursor",
                    model: nil,
                    includedInTotals: false,
                    quality: .contextOnly),
                SupplementalUsage(
                    id: "cursor-session-b",
                    label: "Cursor Sessions",
                    value: 1,
                    unit: .count,
                    source: "Cursor",
                    model: nil,
                    includedInTotals: false,
                    quality: .contextOnly),
            ]
            return usage
        }

        let service = await MainActor.run { UsageService(readers: [reader]) }
        await service.refresh()

        let usageData = await MainActor.run { service.usageData }

        XCTAssertEqual(usageData.totalTokens, 100)
        XCTAssertEqual(
            usageData.supplementalStats.first(where: { $0.label == "Cursor Context" })?.value,
            5000)
        XCTAssertEqual(
            usageData.supplementalStats.first(where: { $0.label == "Cursor Sessions" })?.value,
            2)
        XCTAssertEqual(usageData.contextOnlyModels.count, 2)
        XCTAssertEqual(usageData.contextOnlyModels.first?.model, "gpt-5.4-xhigh")
        XCTAssertTrue(usageData.hasExcludedSupplementalStats)
    }

    func test_usageService_keepsCostOnlyModelsInByModelBreakdown() async {
        let recorder = MockReaderRecorder()
        let reader = MockReader(name: "Mock", recorder: recorder) { _, _ in
            var usage = RawTokenUsage()
            usage.cost = 0.38
            usage.perModel["claude-4.5-sonnet-thinking"] = PerModelUsage(
                totalTokens: 0,
                cost: 0.38,
                activeSeconds: 0,
                sources: ["Cursor"])
            return usage
        }

        let service = await MainActor.run { UsageService(readers: [reader]) }
        await service.refresh()

        let usageData = await MainActor.run { service.usageData }

        XCTAssertEqual(usageData.cost, 0.38, accuracy: 0.000001)
        XCTAssertEqual(usageData.perModel.count, 1)
        XCTAssertEqual(usageData.perModel.first?.id, "claude-4.5-sonnet-thinking")
        XCTAssertEqual(usageData.perModel.first?.totalTokens, 0)
        XCTAssertEqual(usageData.perModel.first?.cost ?? 0, 0.38, accuracy: 0.000001)
    }

    func test_usageService_selectRangeEnd_movesStartWhenEndWouldPrecedeIt() async {
        let service = await MainActor.run { UsageService(readers: []) }

        await MainActor.run {
            service.selectRange(
                from: behaviorTestISODate("2026-04-10T12:00:00Z"),
                to: behaviorTestISODate("2026-04-12T12:00:00Z"))
            service.selectRangeEnd(behaviorTestISODate("2026-04-08T12:00:00Z"))
        }

        let startDate = await MainActor.run { service.startDate }
        let endDate = await MainActor.run { service.endDate }

        XCTAssertEqual(startDate, behaviorLocalStartOfDay("2026-04-08T12:00:00Z"))
        XCTAssertEqual(endDate, behaviorLocalExclusiveEnd("2026-04-08T12:00:00Z"))
    }

    func test_usageService_selectRange_normalizesReversedDates() async {
        let service = await MainActor.run { UsageService(readers: []) }

        await MainActor.run {
            service.selectRange(
                from: behaviorTestISODate("2026-04-12T18:00:00Z"),
                to: behaviorTestISODate("2026-04-10T09:00:00Z"))
        }

        let startDate = await MainActor.run { service.startDate }
        let endDate = await MainActor.run { service.endDate }

        XCTAssertEqual(startDate, behaviorLocalStartOfDay("2026-04-10T09:00:00Z"))
        XCTAssertEqual(endDate, behaviorLocalExclusiveEnd("2026-04-12T18:00:00Z"))
    }
}

final class UsageServiceDateSyncBehaviorTests: XCTestCase {
    func test_usageService_syncSelectionWithTodayIfNeeded_advancesPinnedTodaySelection() async throws {
        let calendar = Calendar.current
        let service = await MainActor.run { UsageService(readers: []) }
        let initialToday = await MainActor.run { service.startDate }
        let nextDay = try XCTUnwrap(calendar.date(byAdding: .day, value: 1, to: initialToday))
        let nextDayNoon = try XCTUnwrap(calendar.date(byAdding: .hour, value: 12, to: nextDay))
        let followingDay = try XCTUnwrap(calendar.date(byAdding: .day, value: 1, to: nextDay))

        let changed = await MainActor.run {
            service.syncSelectionWithTodayIfNeeded(now: nextDayNoon)
        }

        let startDate = await MainActor.run { service.startDate }
        let endDate = await MainActor.run { service.endDate }

        XCTAssertTrue(changed)
        XCTAssertEqual(startDate, nextDay)
        XCTAssertEqual(endDate, followingDay)
    }

    func test_usageService_syncSelectionWithTodayIfNeeded_preservesManualPastSelection() async throws {
        let calendar = Calendar.current
        let service = await MainActor.run { UsageService(readers: []) }
        let initialToday = await MainActor.run { service.startDate }
        let yesterday = try XCTUnwrap(calendar.date(byAdding: .day, value: -1, to: initialToday))
        let nextDay = try XCTUnwrap(calendar.date(byAdding: .day, value: 1, to: initialToday))
        let nextDayNoon = try XCTUnwrap(calendar.date(byAdding: .hour, value: 12, to: nextDay))
        let expectedEnd = try XCTUnwrap(calendar.date(byAdding: .day, value: 1, to: yesterday))

        await MainActor.run {
            service.selectDay(yesterday)
        }

        let changed = await MainActor.run {
            service.syncSelectionWithTodayIfNeeded(now: nextDayNoon)
        }

        let startDate = await MainActor.run { service.startDate }
        let endDate = await MainActor.run { service.endDate }

        XCTAssertFalse(changed)
        XCTAssertEqual(startDate, yesterday)
        XCTAssertEqual(endDate, expectedEnd)
    }
}

final class TokiBehaviorTests: XCTestCase {
    func test_blockingReaderGate_resumesAllFirstRequestWaiters() async {
        let gate = BlockingReaderGate()
        let waiter1 = Task {
            await gate.waitForFirstRequest()
            return 1
        }
        let waiter2 = Task {
            await gate.waitForFirstRequest()
            return 2
        }
        let enterTask = Task {
            await gate.enter()
        }

        let waiter1Result = await waiter1.value
        let waiter2Result = await waiter2.value
        await gate.release()
        await enterTask.value

        XCTAssertEqual(Set([waiter1Result, waiter2Result]), Set([1, 2]))
    }

    func test_blockingReaderGate_releasesAllBlockedReaders() async {
        let gate = BlockingReaderGate()
        let reader1 = Task {
            await gate.enter()
            return 1
        }
        let reader2 = Task {
            await gate.enter()
            return 2
        }

        await gate.waitForRequestCount(2)
        await gate.release()

        let reader1Result = await reader1.value
        let reader2Result = await reader2.value

        XCTAssertEqual(Set([reader1Result, reader2Result]), Set([1, 2]))
    }

    func test_jsonLineStringValue_extractsISODateString() {
        let line = #"{"timestamp":"2026-04-10T12:34:56Z","type":"assistant"}"#
        XCTAssertEqual(jsonLineStringValue(line, forKey: "timestamp"), "2026-04-10T12:34:56Z")
    }

    func test_codexDayKey_changesAcrossTimeZones() throws {
        let date = behaviorTestISODate("2026-04-01T23:30:00Z")
        let utc = try XCTUnwrap(TimeZone(secondsFromGMT: 0))
        let seoul = try XCTUnwrap(TimeZone(identifier: "Asia/Seoul"))

        XCTAssertEqual(codexDayKey(for: date, timeZone: utc), "2026-04-01")
        XCTAssertEqual(codexDayKey(for: date, timeZone: seoul), "2026-04-02")
    }
}

private func behaviorTestISODate(_ value: String) -> Date {
    guard let date = DateParser.parse(value) else {
        XCTFail("Failed to parse ISO date: \(value)")
        return Date.distantPast
    }
    return date
}

private func behaviorLocalStartOfDay(_ value: String) -> Date {
    Calendar.current.startOfDay(for: behaviorTestISODate(value))
}

private func behaviorLocalExclusiveEnd(_ value: String) -> Date {
    Calendar.current.date(byAdding: .day, value: 1, to: behaviorLocalStartOfDay(value)) ?? Date.distantPast
}
