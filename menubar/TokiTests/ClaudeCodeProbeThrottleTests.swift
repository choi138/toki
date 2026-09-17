import XCTest
@testable import Toki

final class ClaudeCodeProbeThrottleTests: XCTestCase {
    private let start = tokiTestISODate("2026-04-10T10:00:00Z")

    func test_probesOnFirstPollAndAgainAfterOneWindow() {
        var throttle = ClaudeCodeProbeThrottle()

        XCTAssertTrue(throttle.shouldProbeAlongsideOtherSources(now: start))
        throttle.record(
            ActivityMonitorState(activeSources: [.codex], probedClaudeCode: true),
            at: start)

        XCTAssertFalse(throttle.shouldProbeAlongsideOtherSources(now: start.addingTimeInterval(10)))
        XCTAssertFalse(throttle.shouldProbeAlongsideOtherSources(now: start.addingTimeInterval(29)))
        XCTAssertTrue(throttle.shouldProbeAlongsideOtherSources(now: start.addingTimeInterval(30)))
    }

    func test_keepsProbingWhileClaudeCodeIsActive() {
        var throttle = ClaudeCodeProbeThrottle()
        throttle.record(
            ActivityMonitorState(activeSources: [.codex, .claudeCode], probedClaudeCode: true),
            at: start)

        XCTAssertTrue(throttle.shouldProbeAlongsideOtherSources(now: start.addingTimeInterval(10)))
    }

    func test_skippedProbeDoesNotRestartTheWindow() {
        var throttle = ClaudeCodeProbeThrottle()
        throttle.record(
            ActivityMonitorState(activeSources: [.codex], probedClaudeCode: true),
            at: start)
        throttle.record(
            ActivityMonitorState(activeSources: [.codex], probedClaudeCode: false),
            at: start.addingTimeInterval(20))

        XCTAssertTrue(throttle.shouldProbeAlongsideOtherSources(now: start.addingTimeInterval(30)))
    }
}
