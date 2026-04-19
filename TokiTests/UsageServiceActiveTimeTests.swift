import XCTest
@testable import Toki

final class UsageServiceActiveTimeTests: XCTestCase {
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
                        key: "gpt-5.4"
                    ),
                    ActivityTimeEvent(
                        streamID: "codex",
                        timestamp: usageServiceActiveTimeISODate("2026-04-10T00:02:00Z"),
                        key: "gpt-5.4"
                    ),
                ]
            )
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
                        key: "gpt-5.4"
                    ),
                    ActivityTimeEvent(
                        streamID: "claude",
                        timestamp: usageServiceActiveTimeISODate("2026-04-10T00:03:00Z"),
                        key: "gpt-5.4"
                    ),
                ]
            )
        }

        let service = await MainActor.run {
            UsageService(readers: [firstReader, secondReader])
        }
        await service.refresh()

        let totalActiveSeconds = await MainActor.run { service.usageData.activeSeconds }
        let models = await MainActor.run { service.usageData.perModel }

        XCTAssertEqual(totalActiveSeconds, 210, accuracy: 0.001)
        XCTAssertEqual(models.first?.id, "gpt-5.4")
        XCTAssertEqual(models.first?.activeSeconds ?? 0, 210, accuracy: 0.001)
    }
}

private func usageServiceActiveTimeISODate(_ value: String) -> Date {
    guard let date = DateParser.parse(value) else {
        XCTFail("Failed to parse ISO date: \(value)")
        return Date.distantPast
    }
    return date
}
