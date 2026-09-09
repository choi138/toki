import Foundation
import TokiUsageCore
import XCTest
@testable import TokiUsageReaders

final class GrokReaderRegressionTests: XCTestCase {
    private let wideRange = (
        from: GrokFixture.date.addingTimeInterval(-86400),
        to: GrokFixture.date.addingTimeInterval(86400))

    func test_nestedCacheAndReasoningTokensAreNotDoubleCounted() async throws {
        let fixture = try GrokFixture()
        defer { fixture.remove() }
        try fixture.writeSession(turns: [fixture.turn(endedAt: GrokFixture.date)])

        let usage = try await read(fixture)

        // Grok nests cachedReadTokens inside inputTokens and reasoningTokens inside outputTokens.
        XCTAssertEqual(usage.inputTokens, 200)
        XCTAssertEqual(usage.cacheReadTokens, 800)
        XCTAssertEqual(usage.outputTokens, 50)
        XCTAssertEqual(usage.reasoningTokens, 150)
        XCTAssertEqual(usage.cacheWriteTokens, 0)
        XCTAssertEqual(usage.totalTokens, 1200)
    }

    func test_cacheReadAboveInputTokensIsClampedInsteadOfGoingNegative() async throws {
        let fixture = try GrokFixture()
        defer { fixture.remove() }
        try fixture.writeSession(turns: [fixture.turn(
            endedAt: GrokFixture.date,
            fixture.counts(input: 100, output: 10, cachedRead: 500, reasoning: 50))])

        let usage = try await read(fixture)

        XCTAssertEqual(usage.inputTokens, 0)
        XCTAssertEqual(usage.cacheReadTokens, 100)
        XCTAssertEqual(usage.outputTokens, 0)
        XCTAssertEqual(usage.reasoningTokens, 10)
        XCTAssertEqual(usage.totalTokens, 110)
    }

    func test_turnDeltasSumIntoSessionTotals() async throws {
        let fixture = try GrokFixture()
        defer { fixture.remove() }
        try fixture.writeSession(turns: (0..<3).map {
            fixture.turn(endedAt: GrokFixture.date.addingTimeInterval(Double($0) * 60))
        })

        let usage = try await read(fixture)

        XCTAssertEqual(usage.tokenEvents.count, 3)
        XCTAssertEqual(usage.totalTokens, 3600)
        XCTAssertEqual(usage.cost, 7.5, accuracy: 0.000001)
        XCTAssertEqual(usage.tokenEvents.reduce(0) { $0 + $1.totalTokens }, usage.totalTokens)
    }

    func test_reportedCostTicksConvertToDollars() async throws {
        let fixture = try GrokFixture()
        defer { fixture.remove() }
        try fixture.writeSession(turns: [fixture.turn(
            endedAt: GrokFixture.date,
            fixture.counts(ticks: 2_462_099_800))])

        let usage = try await read(fixture)
        let event = try XCTUnwrap(usage.tokenEvents.first)

        XCTAssertEqual(event.cost, 2.4620998, accuracy: 0.0000001)
        XCTAssertEqual(event.costIsKnown, true)
        XCTAssertEqual(event.provider, "xai")
        XCTAssertEqual(event.model, "grok-4.6-build")
    }

    func test_missingOrNegativeCostTicksMarkCostUnknown() async throws {
        for ticks in [nil, Int64(-5)] {
            let fixture = try GrokFixture()
            defer { fixture.remove() }
            try fixture.writeSession(turns: [fixture.turn(
                endedAt: GrokFixture.date,
                fixture.counts(ticks: ticks))])

            let usage = try await read(fixture)
            let event = try XCTUnwrap(usage.tokenEvents.first)

            XCTAssertEqual(event.cost, 0)
            XCTAssertEqual(event.costIsKnown, false)
            XCTAssertEqual(event.totalTokens, 1200)
        }
    }

    func test_perModelUsageSplitsEveryModelInOneTurn() async throws {
        let fixture = try GrokFixture()
        defer { fixture.remove() }
        let build = fixture.counts(
            input: 100, output: 20, cachedRead: 0, reasoning: 0, ticks: 1_000_000_000)
        let previous = fixture.counts(
            input: 200, output: 40, cachedRead: 0, reasoning: 0, ticks: 3_000_000_000)
        try fixture.writeSession(turns: [fixture.turn(
            endedAt: GrokFixture.date,
            fixture.counts(model: "grok-4.6-build"),
            modelUsage: ["grok-4.6-build": build, "grok-4.5": previous])])

        let usage = try await read(fixture)

        XCTAssertEqual(usage.tokenEvents.count, 2)
        XCTAssertEqual(usage.perModel["grok-4.6-build"]?.totalTokens, 120)
        XCTAssertEqual(usage.perModel["grok-4.5"]?.totalTokens, 240)
        XCTAssertEqual(try XCTUnwrap(usage.perModel["grok-4.5"]?.cost), 3, accuracy: 0.000001)
        XCTAssertEqual(usage.cost, 4, accuracy: 0.000001)
        XCTAssertEqual(usage.perModel["grok-4.6-build"]?.sources, [GrokReader.sourceName])
    }

    func test_sessionTotalsAreUsedWhenTurnsAreAbsent() async throws {
        let fixture = try GrokFixture()
        defer { fixture.remove() }
        try fixture.writeSession(turns: [], session: fixture.counts())

        let usage = try await read(fixture)
        let event = try XCTUnwrap(usage.tokenEvents.first)

        XCTAssertEqual(usage.tokenEvents.count, 1)
        XCTAssertEqual(event.timestamp, GrokFixture.date)
        XCTAssertEqual(usage.totalTokens, 1200)
    }

    func test_turnsTakePrecedenceOverSessionTotals() async throws {
        let fixture = try GrokFixture()
        defer { fixture.remove() }
        try fixture.writeSession(
            turns: [fixture.turn(endedAt: GrokFixture.date)],
            session: fixture.counts(input: 999_999, output: 999_999))

        let usage = try await read(fixture)

        XCTAssertEqual(usage.totalTokens, 1200)
    }

    func test_dateRangeFiltersTurnsByEndedAt() async throws {
        let fixture = try GrokFixture()
        defer { fixture.remove() }
        try fixture.writeSession(turns: (0..<3).map {
            fixture.turn(endedAt: GrokFixture.date.addingTimeInterval(Double($0) * 60))
        })
        let reader = GrokReader(sessionRootsOverride: [fixture.sessionsRoot])

        let usage = try await reader.readUsage(
            from: GrokFixture.date,
            to: GrokFixture.date.addingTimeInterval(90))

        XCTAssertEqual(usage.tokenEvents.count, 2)
        XCTAssertEqual(usage.totalTokens, 2400)
    }

    func test_invertedDateRangeReportsNoUsage() async throws {
        let fixture = try GrokFixture()
        defer { fixture.remove() }
        try fixture.writeSession(turns: [fixture.turn(endedAt: GrokFixture.date)])
        let reader = GrokReader(sessionRootsOverride: [fixture.sessionsRoot])

        let usage = try await reader.readUsage(from: wideRange.to, to: wideRange.from)

        XCTAssertTrue(usage.tokenEvents.isEmpty)
    }

    func test_microsecondPrecisionTimestampsAreParsed() async throws {
        let fixture = try GrokFixture()
        defer { fixture.remove() }
        try fixture.writeRawUsage(
            """
            {"sessionId":"session-1","updatedAt":"2026-08-20T13:00:00.999999+00:00",
             "turns":[{"endedAt":"2026-08-20T12:00:00.355446+00:00","inputTokens":10,
             "outputTokens":5,"costUsdTicks":1000000000,"primaryModelId":"grok-4.6"}]}
            """,
            id: "session-1")

        let usage = try await read(fixture)
        let event = try XCTUnwrap(usage.tokenEvents.first)

        // A parse failure would silently fall back to updatedAt, an hour later.
        XCTAssertEqual(
            event.timestamp.timeIntervalSince1970,
            GrokFixture.date.timeIntervalSince1970,
            accuracy: 1)
        XCTAssertGreaterThanOrEqual(event.timestamp, GrokFixture.date)
        XCTAssertEqual(event.totalTokens, 15)
        XCTAssertEqual(event.cost, 1)
    }

    func test_malformedAndEmptyDocumentsAreSkippedWithoutLosingHealthySessions() async throws {
        let fixture = try GrokFixture()
        defer { fixture.remove() }
        try fixture.writeRawUsage("not json at all", id: "session-broken")
        try fixture.writeRawUsage("{}", id: "session-empty")
        try fixture.writeSession(id: "session-healthy", turns: [fixture.turn(endedAt: GrokFixture.date)])

        let usage = try await read(fixture)

        XCTAssertEqual(usage.totalTokens, 1200)
        XCTAssertEqual(Set(usage.tokenEvents.compactMap { $0.attribution?.sessionID }).count, 1)
    }

    func test_recordsWithoutAnyTimestampFallBackToTheFileModificationDate() async throws {
        let fixture = try GrokFixture()
        defer { fixture.remove() }
        let modifiedAt = GrokFixture.date.addingTimeInterval(-120)
        try fixture.writeRawUsage(
            """
            {"sessionId":"session-no-date","turns":[{"inputTokens":10,"outputTokens":5}]}
            """,
            id: "session-no-date",
            modifiedAt: modifiedAt)

        let usage = try await read(fixture)
        let event = try XCTUnwrap(usage.tokenEvents.first)

        XCTAssertEqual(usage.tokenEvents.count, 1)
        XCTAssertEqual(event.timestamp, modifiedAt)
        XCTAssertEqual(event.totalTokens, 15)
    }

    func test_timestamplessRecordsOutsideTheRequestedRangeAreExcluded() async throws {
        let fixture = try GrokFixture()
        defer { fixture.remove() }
        try fixture.writeRawUsage(
            """
            {"sessionId":"session-no-date","turns":[{"inputTokens":10,"outputTokens":5}]}
            """,
            id: "session-no-date",
            modifiedAt: wideRange.from.addingTimeInterval(-86400))

        let usage = try await read(fixture)

        XCTAssertTrue(usage.tokenEvents.isEmpty)
        XCTAssertEqual(usage.totalTokens, 0)
    }

    fileprivate func read(_ fixture: GrokFixture) async throws -> RawTokenUsage {
        try await GrokReader(sessionRootsOverride: [fixture.sessionsRoot])
            .readUsage(from: wideRange.from, to: wideRange.to)
    }
}

extension GrokReaderRegressionTests {
    func test_attributionPrefersSummaryCWDAndTitle() async throws {
        let fixture = try GrokFixture()
        defer { fixture.remove() }
        try fixture.writeSession(
            turns: [fixture.turn(endedAt: GrokFixture.date)],
            title: "Reviewed leftover specs",
            summaryCWD: "/summary/workspace")

        let usage = try await read(fixture)
        let attribution = try XCTUnwrap(usage.tokenEvents.first?.attribution)

        XCTAssertEqual(attribution.projectPath, "/summary/workspace")
        XCTAssertEqual(attribution.projectName, "workspace")
        XCTAssertEqual(attribution.sessionLabel, "Reviewed leftover specs")
        XCTAssertEqual(attribution.quality, .exact)
    }

    func test_attributionFallsBackToPercentEncodedProjectDirectory() async throws {
        let fixture = try GrokFixture()
        defer { fixture.remove() }
        try fixture.writeSession(
            cwd: "/synthetic/fallback",
            turns: [fixture.turn(endedAt: GrokFixture.date)],
            title: nil)

        let usage = try await read(fixture)
        let attribution = try XCTUnwrap(usage.tokenEvents.first?.attribution)

        XCTAssertEqual(attribution.projectPath, "/synthetic/fallback")
        XCTAssertNil(attribution.sessionLabel)
    }

    func test_sessionIdentifiersAreHashedRatherThanExposed() async throws {
        let fixture = try GrokFixture()
        defer { fixture.remove() }
        try fixture.writeSession(id: "01a084ff-ff0e-7b02-92df-622243089e67", turns: [
            fixture.turn(endedAt: GrokFixture.date),
        ])

        let usage = try await read(fixture)
        let sessionID = try XCTUnwrap(usage.tokenEvents.first?.attribution?.sessionID)

        XCTAssertTrue(sessionID.hasPrefix("grokcli:"))
        XCTAssertFalse(sessionID.contains("01a084ff"))
    }

    func test_separateSessionsProduceIndependentActivityStreams() async throws {
        let fixture = try GrokFixture()
        defer { fixture.remove() }
        for index in 0..<2 {
            try fixture.writeSession(
                id: "session-\(index)",
                turns: [fixture.turn(endedAt: GrokFixture.date.addingTimeInterval(Double(index) * 60))])
        }

        let usage = try await read(fixture)

        XCTAssertEqual(Set(usage.activityEvents.map(\.streamID)).count, 2)
        XCTAssertEqual(usage.totalTokens, 2400)
    }
}
