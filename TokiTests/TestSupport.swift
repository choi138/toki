import XCTest
@testable import Toki

func mockUsage(totalTokens: Int) -> RawTokenUsage {
    var usage = RawTokenUsage()
    usage.inputTokens = totalTokens
    return usage
}

actor MockReaderRecorder {
    private var calls: [(start: Date, end: Date)] = []

    func record(start: Date, end: Date) {
        calls.append((start: start, end: end))
    }

    func snapshot() -> [(start: Date, end: Date)] {
        calls
    }
}

struct MockReader: TokenReader {
    let name: String
    let recorder: MockReaderRecorder
    let handler: @Sendable (Date, Date) -> RawTokenUsage

    func readUsage(from startDate: Date, to endDate: Date) async throws -> RawTokenUsage {
        await recorder.record(start: startDate, end: endDate)
        return handler(startDate, endDate)
    }
}

actor BlockingReaderGate {
    private var requestCount = 0
    private var firstRequestContinuation: CheckedContinuation<Void, Never>?
    private var releaseContinuation: CheckedContinuation<Void, Never>?
    private var requestWaiters: [(target: Int, continuation: CheckedContinuation<Void, Never>)] = []
    private var isReleased = false

    func enter() async {
        requestCount += 1

        if requestCount == 1 {
            firstRequestContinuation?.resume()
            firstRequestContinuation = nil
        }

        resumeSatisfiedWaiters()

        if !isReleased {
            await withCheckedContinuation { continuation in
                releaseContinuation = continuation
            }
        }
    }

    func waitForFirstRequest() async {
        if requestCount >= 1 { return }

        await withCheckedContinuation { continuation in
            firstRequestContinuation = continuation
        }
    }

    func waitForRequestCount(_ target: Int) async {
        if requestCount >= target { return }

        await withCheckedContinuation { continuation in
            requestWaiters.append((target: target, continuation: continuation))
        }
    }

    func release() {
        guard !isReleased else { return }
        isReleased = true
        releaseContinuation?.resume()
        releaseContinuation = nil
    }

    private func resumeSatisfiedWaiters() {
        let ready = requestWaiters.filter { requestCount >= $0.target }
        requestWaiters.removeAll { requestCount >= $0.target }
        ready.forEach { $0.continuation.resume() }
    }
}

struct BlockingMockReader: TokenReader {
    let name: String
    let gate: BlockingReaderGate
    let handler: @Sendable (Date, Date) -> RawTokenUsage

    func readUsage(from startDate: Date, to endDate: Date) async throws -> RawTokenUsage {
        await gate.enter()
        return handler(startDate, endDate)
    }
}
