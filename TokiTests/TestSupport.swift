import XCTest
@testable import Toki

func mockUsage(totalTokens: Int, activeSeconds: TimeInterval = 0) -> RawTokenUsage {
    var usage = RawTokenUsage()
    usage.inputTokens = totalTokens
    usage.activeSeconds = activeSeconds
    return usage
}

func mockActivityUsage(
    totalTokens: Int,
    modelID: String,
    source: String,
    events: [ActivityTimeEvent<String>]) -> RawTokenUsage {
    var usage = RawTokenUsage()
    usage.inputTokens = totalTokens
    var model = usage.perModel[modelID] ?? PerModelUsage()
    model.totalTokens = totalTokens
    model.sources.insert(source)
    usage.perModel[modelID] = model
    usage.mergeActivityEvents(events, source: source)
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
    private var firstRequestContinuations: [CheckedContinuation<Void, Never>] = []
    private var releaseContinuations: [CheckedContinuation<Void, Never>] = []
    private var requestWaiters: [(target: Int, continuation: CheckedContinuation<Void, Never>)] = []
    private var isReleased = false

    func enter() async {
        requestCount += 1

        if requestCount == 1 {
            firstRequestContinuations.forEach { $0.resume() }
            firstRequestContinuations.removeAll()
        }

        resumeSatisfiedWaiters()

        if !isReleased {
            await withCheckedContinuation { continuation in
                releaseContinuations.append(continuation)
            }
        }
    }

    func waitForFirstRequest() async {
        if requestCount >= 1 { return }

        await withCheckedContinuation { continuation in
            firstRequestContinuations.append(continuation)
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
        releaseContinuations.forEach { $0.resume() }
        releaseContinuations.removeAll()
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
