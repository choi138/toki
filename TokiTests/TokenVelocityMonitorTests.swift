import XCTest
@testable import Toki

final class TokenVelocityMonitorTests: XCTestCase {
    func test_firstSampleStartsAtZeroVelocity() async {
        let reader = TokenTotalSequence([120])
        let monitor = TokenVelocityMonitor(readDailyTokenTotal: { _, _ in
            await reader.next()
        })

        let sample = await monitor.sample(at: tokiTestISODate("2026-04-10T10:00:00Z"))

        XCTAssertEqual(sample.totalTokens, 120)
        XCTAssertEqual(sample.tokensPerSecond, 0)
    }

    func test_calculatesTokenVelocityFromDailyTotalDelta() async {
        let reader = TokenTotalSequence([120, 180])
        let monitor = TokenVelocityMonitor(
            smoothingWeight: 1,
            readDailyTokenTotal: { _, _ in
                await reader.next()
            })

        _ = await monitor.sample(at: tokiTestISODate("2026-04-10T10:00:00Z"))
        let sample = await monitor.sample(at: tokiTestISODate("2026-04-10T10:00:05Z"))

        XCTAssertEqual(sample.totalTokens, 180)
        XCTAssertEqual(sample.tokensPerSecond, 12, accuracy: 0.000_001)
    }

    func test_clampsNegativeTokenDeltasToZero() async {
        let reader = TokenTotalSequence([180, 120])
        let monitor = TokenVelocityMonitor(readDailyTokenTotal: { _, _ in
            await reader.next()
        })

        _ = await monitor.sample(at: tokiTestISODate("2026-04-10T10:00:00Z"))
        let sample = await monitor.sample(at: tokiTestISODate("2026-04-10T10:00:05Z"))

        XCTAssertEqual(sample.totalTokens, 120)
        XCTAssertEqual(sample.tokensPerSecond, 0)
    }

    func test_decaysVelocityWhenTokenTotalIsUnchanged() async {
        let reader = TokenTotalSequence([100, 200, 200])
        let monitor = TokenVelocityMonitor(
            smoothingWeight: 0.5,
            readDailyTokenTotal: { _, _ in
                await reader.next()
            })

        _ = await monitor.sample(at: tokiTestISODate("2026-04-10T10:00:00Z"))
        let activeSample = await monitor.sample(at: tokiTestISODate("2026-04-10T10:00:05Z"))
        let quietSample = await monitor.sample(at: tokiTestISODate("2026-04-10T10:00:10Z"))

        XCTAssertEqual(activeSample.tokensPerSecond, 20, accuracy: 0.000_001)
        XCTAssertEqual(quietSample.tokensPerSecond, 10, accuracy: 0.000_001)
    }

    func test_keepsPreviousPointUntilMinimumElapsedTimePasses() async {
        let reader = TokenTotalSequence([100, 130, 160])
        let monitor = TokenVelocityMonitor(
            smoothingWeight: 1,
            minimumElapsedSeconds: 5,
            readDailyTokenTotal: { _, _ in
                await reader.next()
            })

        _ = await monitor.sample(at: tokiTestISODate("2026-04-10T10:00:00Z"))
        let earlySample = await monitor.sample(at: tokiTestISODate("2026-04-10T10:00:02Z"))
        let elapsedSample = await monitor.sample(at: tokiTestISODate("2026-04-10T10:00:05Z"))

        XCTAssertEqual(earlySample.totalTokens, 130)
        XCTAssertEqual(earlySample.tokensPerSecond, 0)
        XCTAssertEqual(elapsedSample.totalTokens, 160)
        XCTAssertEqual(elapsedSample.tokensPerSecond, 12, accuracy: 0.000_001)
    }

    func test_resetsVelocityAcrossCalendarDays() async {
        let reader = TokenTotalSequence([1000, 20])
        let monitor = TokenVelocityMonitor(readDailyTokenTotal: { _, _ in
            await reader.next()
        })

        _ = await monitor.sample(at: tokiTestISODate("2026-04-10T23:59:58Z"))
        let sample = await monitor.sample(at: tokiTestISODate("2026-04-11T00:00:03Z"))

        XCTAssertEqual(sample.totalTokens, 20)
        XCTAssertEqual(sample.tokensPerSecond, 0)
    }

    func test_resetDropsPreviousSample() async {
        let reader = TokenTotalSequence([100, 140])
        let monitor = TokenVelocityMonitor(readDailyTokenTotal: { _, _ in
            await reader.next()
        })

        _ = await monitor.sample(at: tokiTestISODate("2026-04-10T10:00:00Z"))
        await monitor.reset()
        let sample = await monitor.sample(at: tokiTestISODate("2026-04-10T10:00:05Z"))

        XCTAssertEqual(sample.totalTokens, 140)
        XCTAssertEqual(sample.tokensPerSecond, 0)
    }

    func test_rabbitRunAnimationSpeedAcceleratesAsVelocityIncreases() {
        let idle = RabbitRunAnimationSpeed.frameInterval(tokensPerSecond: 0)
        let medium = RabbitRunAnimationSpeed.frameInterval(tokensPerSecond: 20)
        let fast = RabbitRunAnimationSpeed.frameInterval(tokensPerSecond: 200)
        let veryFast = RabbitRunAnimationSpeed.frameInterval(tokensPerSecond: 1000)
        let flood = RabbitRunAnimationSpeed.frameInterval(tokensPerSecond: 5000)
        let burst = RabbitRunAnimationSpeed.frameInterval(tokensPerSecond: 10000)
        let clampedBurst = RabbitRunAnimationSpeed.frameInterval(tokensPerSecond: 20000)

        XCTAssertEqual(idle, RabbitRunAnimationSpeed.defaultFrameInterval)
        XCTAssertLessThan(medium, idle)
        XCTAssertLessThan(fast, medium)
        XCTAssertLessThan(veryFast, fast)
        XCTAssertLessThan(flood, veryFast)
        XCTAssertLessThan(burst, flood)
        XCTAssertEqual(clampedBurst, burst)
    }
}

private actor TokenTotalSequence {
    private var values: [Int]

    init(_ values: [Int]) {
        self.values = values
    }

    func next() -> Int {
        guard !values.isEmpty else { return 0 }
        return values.removeFirst()
    }
}
