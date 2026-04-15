import XCTest
@testable import Toki

final class TokiBehaviorTests: XCTestCase {

    func test_usageService_skipsYesterdayFetchForPastSingleDay() async {
        let recorder = MockReaderRecorder()
        let today = Calendar.current.startOfDay(for: Date())
        let pastDay = Calendar.current.date(byAdding: .day, value: -7, to: today)!
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

    func test_usageService_preservesZeroYesterdayTotalForTodayComparison() async {
        let recorder = MockReaderRecorder()
        let today = Calendar.current.startOfDay(for: Date())
        let yesterday = Calendar.current.date(byAdding: .day, value: -1, to: today)!
        let reader = MockReader(name: "Mock", recorder: recorder) { startDate, _ in
            switch startDate {
            case today:
                return mockUsage(totalTokens: 120)
            case yesterday:
                return mockUsage(totalTokens: 0)
            default:
                return mockUsage(totalTokens: 5)
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

    func test_usageService_retriesRefreshAfterRangeChangesDuringLoad() async {
        let gate = BlockingReaderGate()
        let today = Calendar.current.startOfDay(for: Date())
        let firstDay = Calendar.current.date(byAdding: .day, value: -2, to: today)!
        let secondDay = Calendar.current.date(byAdding: .day, value: -1, to: today)!
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

    func test_jsonLineStringValue_extractsISODateString() {
        let line = #"{"timestamp":"2026-04-10T12:34:56Z","type":"assistant"}"#
        XCTAssertEqual(jsonLineStringValue(line, forKey: "timestamp"), "2026-04-10T12:34:56Z")
    }

    func test_jsonlFileOverlapsRange_keepsFutureOnlyFileConservative() async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("jsonl")

        let content = """
        {"timestamp":"2026-04-04T09:00:00Z","type":"assistant"}
        {"timestamp":"2026-04-04T11:30:00Z","type":"assistant"}
        """
        try content.write(to: url, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: url) }

        let overlaps = await jsonlFileOverlapsRange(
            at: url,
            startDate: behaviorTestISODate("2026-04-02T00:00:00Z"),
            endDate: behaviorTestISODate("2026-04-03T00:00:00Z"),
            timestampKeys: ["timestamp"]
        )

        XCTAssertTrue(overlaps)
    }

    func test_jsonlFileOverlapsRange_keepsPotentiallyRelevantOutOfOrderFile() async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("jsonl")

        let content = """
        {"timestamp":"2026-04-01T09:00:00Z","type":"assistant"}
        {"timestamp":"2026-04-02T09:00:00Z","type":"assistant"}
        {"timestamp":"2026-04-01T11:30:00Z","type":"assistant"}
        """
        try content.write(to: url, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: url) }

        let overlaps = await jsonlFileOverlapsRange(
            at: url,
            startDate: behaviorTestISODate("2026-04-02T00:00:00Z"),
            endDate: behaviorTestISODate("2026-04-03T00:00:00Z"),
            timestampKeys: ["timestamp"]
        )

        XCTAssertTrue(overlaps)
    }

    func test_codexDayKey_changesAcrossTimeZones() {
        let date = behaviorTestISODate("2026-04-01T23:30:00Z")
        let utc = TimeZone(secondsFromGMT: 0)!
        let seoul = TimeZone(identifier: "Asia/Seoul")!

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
