import XCTest
@testable import Toki

final class TokenVelocityMonitorTests: XCTestCase {
    func test_concurrentSamplesShareOneReaderCall() async {
        let gate = TokenOutputGate(outputTokens: 120)
        let secondRequest = expectation(description: "second sample request entered monitor")
        let requests = TokenVelocityRequestCounter(secondRequest: secondRequest)
        let monitor = TokenVelocityMonitor(
            readDailyOutputTokens: { _, _ in
                await gate.read()
            },
            sampleRequestObserver: {
                requests.recordRequest()
            })

        let first = Task {
            await monitor.sample(at: tokiTestISODate("2026-04-10T10:00:00Z"))
        }
        await gate.waitUntilStarted()
        let second = Task {
            await monitor.sample(at: tokiTestISODate("2026-04-10T10:00:01Z"))
        }
        await fulfillment(of: [secondRequest], timeout: 1)

        let readCount = await gate.readCount
        XCTAssertEqual(readCount, 1)
        await gate.release()
        let firstSample = await first.value
        let secondSample = await second.value

        XCTAssertEqual([firstSample.outputTokens, secondSample.outputTokens], [120, 120])
    }

    func test_concurrentSamplesAcrossDaysReadEachDay() async {
        let firstRead = expectation(description: "first day read started")
        let secondRead = expectation(description: "second day read started")
        let gate = TokenOutputDayGate(
            outputs: [120, 20],
            readExpectations: [firstRead, secondRead])
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0) ?? calendar.timeZone
        let monitor = TokenVelocityMonitor(
            calendar: calendar,
            readDailyOutputTokens: { start, _ in
                await gate.read(start: start)
            })

        let first = Task {
            await monitor.sample(at: tokiTestISODate("2026-04-10T23:59:59Z"))
        }
        await fulfillment(of: [firstRead], timeout: 1)
        let second = Task {
            await monitor.sample(at: tokiTestISODate("2026-04-11T00:00:01Z"))
        }

        await gate.releaseRead(at: 0)
        await fulfillment(of: [secondRead], timeout: 1)
        await gate.releaseRead(at: 1)
        let firstSample = await first.value
        let secondSample = await second.value
        let readDays = await gate.readDays

        XCTAssertEqual(firstSample.outputTokens, 120)
        XCTAssertEqual(secondSample.outputTokens, 20)
        XCTAssertEqual(readDays, [
            tokiTestISODate("2026-04-10T00:00:00Z"),
            tokiTestISODate("2026-04-11T00:00:00Z"),
        ])
    }

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

private actor TokenOutputGate {
    let outputTokens: Int
    private(set) var readCount = 0
    private var isStarted = false
    private var startWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseWaiters: [CheckedContinuation<Void, Never>] = []

    init(outputTokens: Int) {
        self.outputTokens = outputTokens
    }

    func read() async -> Int {
        readCount += 1
        isStarted = true
        let waiters = startWaiters
        startWaiters.removeAll()
        for waiter in waiters {
            waiter.resume()
        }
        await withCheckedContinuation { continuation in
            releaseWaiters.append(continuation)
        }
        return outputTokens
    }

    func waitUntilStarted() async {
        if isStarted { return }
        await withCheckedContinuation { continuation in
            startWaiters.append(continuation)
        }
    }

    func release() {
        let waiters = releaseWaiters
        releaseWaiters.removeAll()
        for waiter in waiters {
            waiter.resume()
        }
    }
}

private actor TokenOutputDayGate {
    private let outputs: [Int]
    private let readExpectations: [XCTestExpectation]
    private(set) var readDays: [Date] = []
    private var releaseWaiters: [Int: CheckedContinuation<Void, Never>] = [:]

    init(outputs: [Int], readExpectations: [XCTestExpectation]) {
        self.outputs = outputs
        self.readExpectations = readExpectations
    }

    func read(start: Date) async -> Int {
        let index = readDays.count
        readDays.append(start)
        readExpectations[index].fulfill()
        await withCheckedContinuation { continuation in
            releaseWaiters[index] = continuation
        }
        return outputs[index]
    }

    func releaseRead(at index: Int) {
        releaseWaiters.removeValue(forKey: index)?.resume()
    }
}

private final class TokenVelocityRequestCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    private let secondRequest: XCTestExpectation

    init(secondRequest: XCTestExpectation) {
        self.secondRequest = secondRequest
    }

    func recordRequest() {
        lock.lock()
        count += 1
        let shouldFulfill = count == 2
        lock.unlock()
        if shouldFulfill {
            secondRequest.fulfill()
        }
    }
}
