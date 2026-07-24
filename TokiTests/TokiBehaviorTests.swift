import XCTest
@testable import Toki
@testable import TokiUsageReaders

final class TokiBehaviorTests: XCTestCase {
    func test_blockingReaderGate_resumesAllFirstRequestWaiters() async {
        let gate = BlockingReaderGate()
        let waiter1 = Task {
            await gate.waitForFirstRequest()
            return 1
        }
        let waiter2 = Task {
            await gate.waitForFirstRequest()
            return 2
        }
        let enterTask = Task {
            await gate.enter()
        }

        let waiter1Result = await waiter1.value
        let waiter2Result = await waiter2.value
        await gate.release()
        await enterTask.value

        XCTAssertEqual(Set([waiter1Result, waiter2Result]), Set([1, 2]))
    }

    func test_blockingReaderGate_releasesAllBlockedReaders() async {
        let gate = BlockingReaderGate()
        let reader1 = Task {
            await gate.enter()
            return 1
        }
        let reader2 = Task {
            await gate.enter()
            return 2
        }

        await gate.waitForRequestCount(2)
        await gate.release()

        let reader1Result = await reader1.value
        let reader2Result = await reader2.value

        XCTAssertEqual(Set([reader1Result, reader2Result]), Set([1, 2]))
    }

    func test_jsonLineStringValue_extractsISODateString() {
        let line = #"{"timestamp":"2026-04-10T12:34:56Z","type":"assistant"}"#
        XCTAssertEqual(jsonLineStringValue(line, forKey: "timestamp"), "2026-04-10T12:34:56Z")
    }

    func test_codexDayKey_changesAcrossTimeZones() throws {
        let date = behaviorTestISODate("2026-04-01T23:30:00Z")
        let utc = try XCTUnwrap(TimeZone(secondsFromGMT: 0))
        let seoul = try XCTUnwrap(TimeZone(identifier: "Asia/Seoul"))

        XCTAssertEqual(codexDayKey(for: date, timeZone: utc), "2026-04-01")
        XCTAssertEqual(codexDayKey(for: date, timeZone: seoul), "2026-04-02")
    }
}
