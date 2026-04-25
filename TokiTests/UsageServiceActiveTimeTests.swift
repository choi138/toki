import XCTest
@testable import Toki

final class UsageServiceActiveTimeTests: XCTestCase {
    @MainActor
    func test_usageService_mergesOverlappingActiveTimeAcrossReaders() async {
        let firstRecorder = MockReaderRecorder()
        let secondRecorder = MockReaderRecorder()
        let firstReader = MockReader(name: "First", recorder: firstRecorder) { _, _ in
            mockActivityUsage(
                totalTokens: 100,
                modelID: "gpt-5.4",
                source: "First",
                events: [
                    ActivityTimeEvent(
                        streamID: "codex",
                        timestamp: usageServiceActiveTimeISODate("2026-04-10T00:00:00Z"),
                        key: "gpt-5.4"),
                    ActivityTimeEvent(
                        streamID: "codex",
                        timestamp: usageServiceActiveTimeISODate("2026-04-10T00:02:00Z"),
                        key: "gpt-5.4"),
                ])
        }
        let secondReader = MockReader(name: "Second", recorder: secondRecorder) { _, _ in
            mockActivityUsage(
                totalTokens: 80,
                modelID: "gpt-5.4",
                source: "Second",
                events: [
                    ActivityTimeEvent(
                        streamID: "claude",
                        timestamp: usageServiceActiveTimeISODate("2026-04-10T00:01:00Z"),
                        key: "gpt-5.4"),
                    ActivityTimeEvent(
                        streamID: "claude",
                        timestamp: usageServiceActiveTimeISODate("2026-04-10T00:03:00Z"),
                        key: "gpt-5.4"),
                ])
        }

        let service = UsageService(readers: [firstReader, secondReader])
        await service.refresh()

        let totalActiveSeconds = service.usageData.activeSeconds
        let models = service.usageData.perModel

        XCTAssertEqual(totalActiveSeconds, 300, accuracy: 0.001)
        XCTAssertEqual(models.first?.id, "gpt-5.4")
        XCTAssertEqual(models.first?.activeSeconds ?? 0, 300, accuracy: 0.001)
    }

    @MainActor
    func test_usageService_preservesFallbackActiveTimeFromReadersWithoutEvents() async {
        let eventReader = MockReader(name: "Event", recorder: MockReaderRecorder()) { _, _ in
            mockActivityUsage(
                totalTokens: 100,
                modelID: "gpt-5.4",
                source: "Event",
                events: [
                    ActivityTimeEvent(
                        streamID: "event",
                        timestamp: usageServiceActiveTimeISODate("2026-04-10T00:00:00Z"),
                        key: "gpt-5.4"),
                    ActivityTimeEvent(
                        streamID: "event",
                        timestamp: usageServiceActiveTimeISODate("2026-04-10T00:02:00Z"),
                        key: "gpt-5.4"),
                ])
        }
        let aggregateReader = MockReader(name: "Aggregate", recorder: MockReaderRecorder()) { _, _ in
            var usage = RawTokenUsage()
            usage.inputTokens = 40
            usage.activeSeconds = 60
            usage.perModel["claude-sonnet-4-6"] = PerModelUsage(
                totalTokens: 40,
                cost: 0.4,
                activeSeconds: 60,
                sources: ["Aggregate"])
            return usage
        }

        let service = UsageService(readers: [eventReader, aggregateReader])
        await service.refresh()

        XCTAssertEqual(service.usageData.activeSeconds, 210, accuracy: 0.001)
        XCTAssertEqual(
            service.usageData.perModel.first(where: { $0.id == "gpt-5.4" })?.activeSeconds ?? 0,
            150,
            accuracy: 0.001)
        XCTAssertEqual(
            service.usageData.perModel.first(where: { $0.id == "claude-sonnet-4-6" })?.activeSeconds ?? 0,
            60,
            accuracy: 0.001)
    }
}

private func usageServiceActiveTimeISODate(_ value: String) -> Date {
    guard let date = DateParser.parse(value) else {
        XCTFail("Failed to parse ISO date: \(value)")
        return Date.distantPast
    }
    return date
}
