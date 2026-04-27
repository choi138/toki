import XCTest
@testable import Toki

final class ActivityTimeEstimatorTests: XCTestCase {
    func test_activityTimeEstimator_usesObservedGapWithinCutoff() {
        let events = [
            ActivityTimeEvent<String>(streamID: "main", timestamp: isoDate("2026-04-10T00:00:00Z"), key: "gpt-5.4"),
            ActivityTimeEvent<String>(streamID: "main", timestamp: isoDate("2026-04-10T00:03:00Z"), key: "gpt-5.4"),
        ]

        let estimate = ActivityTimeEstimator.estimate(events: events)

        XCTAssertEqual(estimate.totalSeconds, 210, accuracy: 0.001)
        XCTAssertEqual(estimate.wallClockSeconds, 210, accuracy: 0.001)
        XCTAssertEqual(estimate.activeStreamCount, 1)
        XCTAssertEqual(estimate.maxConcurrentStreams, 1)
        XCTAssertEqual(estimate.secondsByKey["gpt-5.4"] ?? 0, 210, accuracy: 0.001)
    }

    func test_activityTimeEstimator_capsIdleGapsToMinimumSlice() {
        let events = [
            ActivityTimeEvent<String>(streamID: "main", timestamp: isoDate("2026-04-10T00:00:00Z"), key: "gpt-5.4"),
            ActivityTimeEvent<String>(streamID: "main", timestamp: isoDate("2026-04-10T00:12:00Z"), key: "gpt-5.4"),
        ]

        let estimate = ActivityTimeEstimator.estimate(events: events, minimumSlice: 30)

        XCTAssertEqual(estimate.totalSeconds, 60, accuracy: 0.001)
        XCTAssertEqual(estimate.wallClockSeconds, 60, accuracy: 0.001)
        XCTAssertEqual(estimate.secondsByKey["gpt-5.4"] ?? 0, 60, accuracy: 0.001)
    }

    func test_activityTimeEstimator_assignsTimeToCurrentEventModel() {
        let events = [
            ActivityTimeEvent<String>(
                streamID: "main",
                timestamp: isoDate("2026-04-10T00:00:00Z"),
                key: "gpt-5.4"),
            ActivityTimeEvent<String>(
                streamID: "main",
                timestamp: isoDate("2026-04-10T00:02:00Z"),
                key: "claude-sonnet-4-6"),
            ActivityTimeEvent<String>(
                streamID: "main",
                timestamp: isoDate("2026-04-10T00:06:00Z"),
                key: "claude-sonnet-4-6"),
        ]

        let estimate = ActivityTimeEstimator.estimate(events: events)

        XCTAssertEqual(estimate.totalSeconds, 390, accuracy: 0.001)
        XCTAssertEqual(estimate.wallClockSeconds, 390, accuracy: 0.001)
        XCTAssertEqual(estimate.secondsByKey["gpt-5.4"] ?? 0, 120, accuracy: 0.001)
        XCTAssertEqual(estimate.secondsByKey["claude-sonnet-4-6"] ?? 0, 270, accuracy: 0.001)
    }

    func test_activityTimeEstimator_sumsOverlappingStreamsAsAgentWorkTime() {
        let events = [
            ActivityTimeEvent<String>(streamID: "thread-a", timestamp: isoDate("2026-04-10T00:00:00Z"), key: "gpt-5.4"),
            ActivityTimeEvent<String>(streamID: "thread-a", timestamp: isoDate("2026-04-10T00:02:00Z"), key: "gpt-5.4"),
            ActivityTimeEvent<String>(streamID: "thread-b", timestamp: isoDate("2026-04-10T00:01:00Z"), key: "gpt-5.4"),
            ActivityTimeEvent<String>(streamID: "thread-b", timestamp: isoDate("2026-04-10T00:03:00Z"), key: "gpt-5.4"),
        ]

        let estimate = ActivityTimeEstimator.estimate(events: events)

        XCTAssertEqual(estimate.totalSeconds, 300, accuracy: 0.001)
        XCTAssertEqual(estimate.wallClockSeconds, 210, accuracy: 0.001)
        XCTAssertEqual(estimate.activeStreamCount, 2)
        XCTAssertEqual(estimate.maxConcurrentStreams, 2)
        XCTAssertEqual(estimate.secondsByKey["gpt-5.4"] ?? 0, 300, accuracy: 0.001)
    }

    func test_activityTimeEstimator_splitsMainAndSubagentWorkTime() {
        let events = [
            ActivityTimeEvent<String>(
                streamID: "main",
                timestamp: isoDate("2026-04-10T00:00:00Z"),
                key: "gpt-5.4"),
            ActivityTimeEvent<String>(
                streamID: "main",
                timestamp: isoDate("2026-04-10T00:02:00Z"),
                key: "gpt-5.4"),
            ActivityTimeEvent<String>(
                streamID: "subagent",
                timestamp: isoDate("2026-04-10T00:01:00Z"),
                key: "gpt-5.4",
                agentKind: .subagent),
            ActivityTimeEvent<String>(
                streamID: "subagent",
                timestamp: isoDate("2026-04-10T00:03:00Z"),
                key: "gpt-5.4",
                agentKind: .subagent),
        ]

        let estimate = ActivityTimeEstimator.estimate(events: events)

        XCTAssertEqual(estimate.totalSeconds, 300, accuracy: 0.001)
        XCTAssertEqual(estimate.mainAgentSeconds, 150, accuracy: 0.001)
        XCTAssertEqual(estimate.subagentSeconds, 150, accuracy: 0.001)
        XCTAssertEqual(estimate.wallClockSeconds, 210, accuracy: 0.001)
    }

    func test_activityTimeEstimator_clampsMinimumSliceToRangeEnd() {
        let events = [
            ActivityTimeEvent<String>(
                streamID: "main",
                timestamp: isoDate("2026-04-10T23:59:50Z"),
                key: "gpt-5.4"),
        ]

        let estimate = ActivityTimeEstimator.estimate(
            events: events,
            clippingEndDate: isoDate("2026-04-11T00:00:00Z"))

        XCTAssertEqual(estimate.totalSeconds, 10, accuracy: 0.001)
        XCTAssertEqual(estimate.wallClockSeconds, 10, accuracy: 0.001)
        XCTAssertEqual(estimate.secondsByKey["gpt-5.4"] ?? 0, 10, accuracy: 0.001)
    }

    func test_activityTimeEstimator_treatsTouchingStreamIntervalsAsNonOverlapping() {
        let events = [
            ActivityTimeEvent<String>(
                streamID: "thread-a",
                timestamp: isoDate("2026-04-10T00:00:00Z"),
                key: "gpt-5.4"),
            ActivityTimeEvent<String>(
                streamID: "thread-b",
                timestamp: isoDate("2026-04-10T00:00:30Z"),
                key: "gpt-5.4"),
        ]

        let estimate = ActivityTimeEstimator.estimate(events: events, minimumSlice: 30)

        XCTAssertEqual(estimate.totalSeconds, 60, accuracy: 0.001)
        XCTAssertEqual(estimate.wallClockSeconds, 60, accuracy: 0.001)
        XCTAssertEqual(estimate.activeStreamCount, 2)
        XCTAssertEqual(estimate.maxConcurrentStreams, 1)
    }

    private func isoDate(_ value: String) -> Date {
        guard let date = DateParser.parse(value) else {
            XCTFail("Failed to parse ISO date: \(value)")
            return Date.distantPast
        }
        return date
    }
}
