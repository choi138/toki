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
