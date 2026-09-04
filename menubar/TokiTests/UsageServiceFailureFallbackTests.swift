import TokiUsageCore
import XCTest
@testable import Toki

@MainActor
final class UsageServiceFailureFallbackTests: XCTestCase {
    func test_usageServicePreservesLastSuccessfulUsageWhenReaderFails() async throws {
        let state = FailingUsageReaderState(totalTokens: 300)
        let reader = FailingUsageReader(name: "Flaky", state: state)
        let service = UsageService(readers: [reader])
        let pastDay = try XCTUnwrap(Calendar.current.date(byAdding: .day, value: -2, to: Date()))

        service.selectDay(pastDay)
        await service.refresh()
        await state.setShouldFail(true)
        await service.refresh()

        XCTAssertEqual(service.usageData.totalTokens, 300)
        XCTAssertEqual(service.readerStatuses.first?.state, .failed)
        XCTAssertEqual(service.readerStatuses.first?.totalTokens, 0)
    }

    func test_usageServicePreservesPeriodTotalsWhenReaderFails() async throws {
        let suiteName = "UsageServiceFailureFallbackTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let state = FailingUsageReaderState(totalTokens: 300)
        let reader = FailingUsageReader(name: "Flaky", state: state)
        let service = UsageService(
            readers: [reader],
            periodTokenTotalsCache: PeriodTokenTotalsCache(defaults: defaults))

        await service.refreshPeriodTokenTotals()
        await state.setShouldFail(true)
        await service.refreshPeriodTokenTotals()

        XCTAssertEqual(service.periodTokenTotals.map(\.totalTokens), [300, 300, 300])
    }
}

private actor FailingUsageReaderState {
    private let totalTokens: Int
    private var shouldFail = false

    init(totalTokens: Int) {
        self.totalTokens = totalTokens
    }

    func readTotalTokens() throws -> Int {
        if shouldFail {
            throw FailingUsageReaderError.unavailable
        }
        return totalTokens
    }

    func setShouldFail(_ shouldFail: Bool) {
        self.shouldFail = shouldFail
    }
}

private struct FailingUsageReader: TokenReader {
    let name: String
    let state: FailingUsageReaderState

    func readUsage(from startDate: Date, to endDate: Date) async throws -> RawTokenUsage {
        try await mockUsage(totalTokens: state.readTotalTokens())
    }
}

private enum FailingUsageReaderError: LocalizedError {
    case unavailable

    var errorDescription: String? {
        "Fixture reader unavailable"
    }
}
