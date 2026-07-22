import TokiUsageCore
import XCTest
@testable import Toki

func behaviorTestISODate(_ value: String) -> Date {
    guard let date = DateParser.parse(value) else {
        XCTFail("Failed to parse ISO date: \(value)")
        return Date.distantPast
    }
    return date
}

func behaviorLocalStartOfDay(_ value: String) -> Date {
    Calendar.current.startOfDay(for: behaviorTestISODate(value))
}

func behaviorLocalExclusiveEnd(_ value: String) -> Date {
    Calendar.current.date(byAdding: .day, value: 1, to: behaviorLocalStartOfDay(value)) ?? Date.distantPast
}

struct ConditionalBlockingMockReader: TokenReader {
    let name: String
    let blockedStart: Date
    let gate: BlockingReaderGate
    let handler: @Sendable (Date, Date) -> RawTokenUsage

    func readUsage(from startDate: Date, to endDate: Date) async throws -> RawTokenUsage {
        if startDate == blockedStart {
            await gate.enter()
        }
        return handler(startDate, endDate)
    }
}

actor YesterdayRequestTracker {
    private var requestCount = 0

    func record() -> Int {
        requestCount += 1
        return requestCount
    }

    func snapshot() -> Int {
        requestCount
    }
}

struct DelayedSecondYesterdayReader: TokenReader {
    let name = "Mock"
    let today: Date
    let yesterday: Date
    let tracker: YesterdayRequestTracker

    func readUsage(from startDate: Date, to endDate: Date) async throws -> RawTokenUsage {
        switch startDate {
        case today:
            return mockUsage(totalTokens: 120)
        case yesterday:
            let requestCount = await tracker.record()
            if requestCount == 2 {
                try? await Task.sleep(for: .milliseconds(100))
            }
            return mockUsage(totalTokens: requestCount)
        default:
            return mockUsage(totalTokens: 5)
        }
    }
}

struct LightweightUsageSnapshot {
    let usageStarts: [Date]
    let totalStarts: [Date]
    let outputStarts: [Date]
}

actor LightweightUsageRecorder {
    private var usageStarts: [Date] = []
    private var totalStarts: [Date] = []
    private var outputStarts: [Date] = []

    func recordUsage(start: Date) {
        usageStarts.append(start)
    }

    func recordTotal(start: Date) {
        totalStarts.append(start)
    }

    func recordOutput(start: Date) {
        outputStarts.append(start)
    }

    func snapshot() -> LightweightUsageSnapshot {
        LightweightUsageSnapshot(
            usageStarts: usageStarts,
            totalStarts: totalStarts,
            outputStarts: outputStarts)
    }
}

struct LightweightComparisonReader: TokenReader {
    let name = "Mock"
    let today: Date
    let yesterday: Date
    let recorder: LightweightUsageRecorder

    func readUsage(from startDate: Date, to endDate: Date) async throws -> RawTokenUsage {
        await recorder.recordUsage(start: startDate)
        return mockUsage(totalTokens: startDate == today ? 120 : 999)
    }

    func readTotalTokens(from startDate: Date, to endDate: Date) async throws -> Int {
        await recorder.recordTotal(start: startDate)
        return startDate == yesterday ? 77 : 999
    }
}

struct RecordingTotalReader: TokenReader {
    let name: String
    let totalTokens: Int
    let recorder: LightweightUsageRecorder

    func readUsage(from startDate: Date, to endDate: Date) async throws -> RawTokenUsage {
        await recorder.recordUsage(start: startDate)
        return mockUsage(totalTokens: 999)
    }

    func readTotalTokens(from startDate: Date, to endDate: Date) async throws -> Int {
        await recorder.recordTotal(start: startDate)
        return totalTokens
    }
}

struct RecordingOutputReader: TokenReader {
    let name: String
    let outputTokens: Int
    let recorder: LightweightUsageRecorder

    func readUsage(from startDate: Date, to endDate: Date) async throws -> RawTokenUsage {
        await recorder.recordUsage(start: startDate)
        return mockOutputUsage(outputTokens: 999)
    }

    func readOutputTokens(from startDate: Date, to endDate: Date) async throws -> Int {
        await recorder.recordOutput(start: startDate)
        return outputTokens
    }
}

actor SupersededPeriodTokenTotalsReaderState {
    private var requestCount = 0
    private var releasedRequests: Set<Int> = []
    private var releaseContinuations: [Int: CheckedContinuation<Void, Never>] = [:]
    private var requestWaiters: [(target: Int, continuation: CheckedContinuation<Void, Never>)] = []

    func readTotalTokens() async -> Int {
        requestCount += 1
        let requestNumber = requestCount
        resumeSatisfiedWaiters()

        if requestNumber <= 2, !releasedRequests.contains(requestNumber) {
            await withCheckedContinuation { continuation in
                releaseContinuations[requestNumber] = continuation
            }
        }

        switch requestNumber {
        case 1, 3, 4:
            return 42
        default:
            return 999
        }
    }

    func waitForRequestCount(_ target: Int) async {
        if requestCount >= target { return }
        await withCheckedContinuation { continuation in
            requestWaiters.append((target: target, continuation: continuation))
        }
    }

    func releaseRequest(_ requestNumber: Int) {
        releasedRequests.insert(requestNumber)
        releaseContinuations.removeValue(forKey: requestNumber)?.resume()
    }

    private func resumeSatisfiedWaiters() {
        let ready = requestWaiters.filter { requestCount >= $0.target }
        requestWaiters.removeAll { requestCount >= $0.target }
        ready.forEach { $0.continuation.resume() }
    }
}

struct SupersededPeriodTokenTotalsReader: TokenReader {
    let name = "Superseded"
    let state: SupersededPeriodTokenTotalsReaderState

    func readUsage(from startDate: Date, to endDate: Date) async throws -> RawTokenUsage {
        mockUsage(totalTokens: 0)
    }

    func readTotalTokens(from startDate: Date, to endDate: Date) async throws -> Int {
        await state.readTotalTokens()
    }
}

func mockOutputUsage(outputTokens: Int) -> RawTokenUsage {
    var usage = RawTokenUsage()
    usage.outputTokens = outputTokens
    return usage
}
