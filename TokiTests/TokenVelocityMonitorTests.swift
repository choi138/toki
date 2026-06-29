import XCTest
@testable import Toki

final class TokenVelocityMonitorTests: XCTestCase {
    func test_firstSampleStartsAtZeroVelocity() async {
        let reader = TokenOutputSequence([120])
        let monitor = TokenVelocityMonitor(readDailyOutputTokens: { _, _ in
            await reader.next()
        })

        let sample = await monitor.sample(at: tokiTestISODate("2026-04-10T10:00:00Z"))

        XCTAssertEqual(sample.outputTokens, 120)
        XCTAssertEqual(sample.tokensPerSecond, 0)
    }

    func test_calculatesTokenVelocityFromDailyOutputTokenDelta() async {
        let reader = TokenOutputSequence([120, 180])
        let monitor = TokenVelocityMonitor(
            smoothingWeight: 1,
            readDailyOutputTokens: { _, _ in
                await reader.next()
            })

        _ = await monitor.sample(at: tokiTestISODate("2026-04-10T10:00:00Z"))
        let sample = await monitor.sample(at: tokiTestISODate("2026-04-10T10:00:05Z"))

        XCTAssertEqual(sample.outputTokens, 180)
        XCTAssertEqual(sample.tokensPerSecond, 12, accuracy: 0.000_001)
    }

    func test_clampsNegativeOutputTokenDeltasToZero() async {
        let reader = TokenOutputSequence([180, 120])
        let monitor = TokenVelocityMonitor(readDailyOutputTokens: { _, _ in
            await reader.next()
        })

        _ = await monitor.sample(at: tokiTestISODate("2026-04-10T10:00:00Z"))
        let sample = await monitor.sample(at: tokiTestISODate("2026-04-10T10:00:05Z"))

        XCTAssertEqual(sample.outputTokens, 120)
        XCTAssertEqual(sample.tokensPerSecond, 0)
    }

    func test_decaysVelocityWhenOutputTokenTotalIsUnchanged() async {
        let reader = TokenOutputSequence([100, 200, 200])
        let monitor = TokenVelocityMonitor(
            smoothingWeight: 0.5,
            readDailyOutputTokens: { _, _ in
                await reader.next()
            })

        _ = await monitor.sample(at: tokiTestISODate("2026-04-10T10:00:00Z"))
        let activeSample = await monitor.sample(at: tokiTestISODate("2026-04-10T10:00:05Z"))
        let quietSample = await monitor.sample(at: tokiTestISODate("2026-04-10T10:00:10Z"))

        XCTAssertEqual(activeSample.tokensPerSecond, 20, accuracy: 0.000_001)
        XCTAssertEqual(quietSample.tokensPerSecond, 10, accuracy: 0.000_001)
    }

    func test_keepsPreviousPointUntilMinimumElapsedTimePasses() async {
        let reader = TokenOutputSequence([100, 130, 160])
        let monitor = TokenVelocityMonitor(
            smoothingWeight: 1,
            minimumElapsedSeconds: 5,
            readDailyOutputTokens: { _, _ in
                await reader.next()
            })

        _ = await monitor.sample(at: tokiTestISODate("2026-04-10T10:00:00Z"))
        let earlySample = await monitor.sample(at: tokiTestISODate("2026-04-10T10:00:02Z"))
        let elapsedSample = await monitor.sample(at: tokiTestISODate("2026-04-10T10:00:05Z"))

        XCTAssertEqual(earlySample.outputTokens, 130)
        XCTAssertEqual(earlySample.tokensPerSecond, 0)
        XCTAssertEqual(elapsedSample.outputTokens, 160)
        XCTAssertEqual(elapsedSample.tokensPerSecond, 12, accuracy: 0.000_001)
    }

    func test_resetsVelocityAcrossCalendarDays() async {
        let reader = TokenOutputSequence([1000, 20])
        let monitor = TokenVelocityMonitor(readDailyOutputTokens: { _, _ in
            await reader.next()
        })

        _ = await monitor.sample(at: tokiTestISODate("2026-04-10T23:59:58Z"))
        let sample = await monitor.sample(at: tokiTestISODate("2026-04-11T00:00:03Z"))

        XCTAssertEqual(sample.outputTokens, 20)
        XCTAssertEqual(sample.tokensPerSecond, 0)
    }

    func test_resetDropsPreviousSample() async {
        let reader = TokenOutputSequence([100, 140])
        let monitor = TokenVelocityMonitor(readDailyOutputTokens: { _, _ in
            await reader.next()
        })

        _ = await monitor.sample(at: tokiTestISODate("2026-04-10T10:00:00Z"))
        await monitor.reset()
        let sample = await monitor.sample(at: tokiTestISODate("2026-04-10T10:00:05Z"))

        XCTAssertEqual(sample.outputTokens, 140)
        XCTAssertEqual(sample.tokensPerSecond, 0)
    }

    func test_rabbitRunAnimationSpeedAcceleratesAsVelocityIncreases() {
        let idle = RabbitRunAnimationSpeed.frameInterval(tokensPerSecond: 0)
        let fast = RabbitRunAnimationSpeed.frameInterval(tokensPerSecond: 20)
        let veryFast = RabbitRunAnimationSpeed.frameInterval(tokensPerSecond: 40)
        let flood = RabbitRunAnimationSpeed.frameInterval(tokensPerSecond: 60)
        let burst = RabbitRunAnimationSpeed.frameInterval(tokensPerSecond: 80)
        let clampedBurst = RabbitRunAnimationSpeed.frameInterval(tokensPerSecond: 160)

        XCTAssertEqual(idle, RabbitRunAnimationSpeed.defaultFrameInterval)
        XCTAssertEqual(fast, 0.055, accuracy: 0.000_001)
        XCTAssertEqual(veryFast, 0.035, accuracy: 0.000_001)
        XCTAssertEqual(flood, 0.023, accuracy: 0.000_001)
        XCTAssertEqual(burst, 0.016, accuracy: 0.000_001)
        XCTAssertLessThan(fast, idle)
        XCTAssertLessThan(veryFast, fast)
        XCTAssertLessThan(flood, veryFast)
        XCTAssertLessThan(burst, flood)
        XCTAssertEqual(clampedBurst, burst)
    }
}

private actor TokenOutputSequence {
    private var values: [Int]

    init(_ values: [Int]) {
        self.values = values
    }

    func next() -> Int {
        guard !values.isEmpty else { return 0 }
        return values.removeFirst()
    }
}
