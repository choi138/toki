import Foundation
import TokiUsageCore
import XCTest
@testable import TokiUsageReaders

#if os(Linux)
    import CSQLite
#else
    import SQLite3
#endif

final class OpenClawIdentityTests: XCTestCase {
    func test_databaseAndRetainedMigrationCopiesCountOnceAndKeepJSONOnlyHistory() async throws {
        let fixture = try OpenClawFixture()
        defer { fixture.remove() }
        let database = try fixture.database()
        defer { sqlite3_close(database) }
        try fixture.insert(OpenClawFixture.event(), into: database)
        try fixture.jsonl([OpenClawFixture.event(), OpenClawFixture.event(id: "json-only")])
        try fixture.jsonl([OpenClawFixture.event()], filename: "renamed.jsonl.deleted.123")
        try fixture.jsonl([OpenClawFixture.event()], filename: "session-sqlite-import-archive/imported.jsonl")
        let usage = try await fixture.read()
        XCTAssertEqual(usage.totalTokens, 720)
        XCTAssertEqual(usage.tokenEvents.count, 2)
        XCTAssertEqual(usage.activityEvents.count, 2)
        XCTAssertEqual(usage.cost, 0.0072, accuracy: 0.000001)
    }

    func test_independentAgentsWithIdenticalSessionMessageAndUsageRemainIndependent() async throws {
        let fixture = try OpenClawFixture()
        defer { fixture.remove() }
        let database = try fixture.database()
        defer { sqlite3_close(database) }
        try fixture.insert(OpenClawFixture.event(), into: database)
        try fixture.jsonl([OpenClawFixture.event()], agent: "work")
        let usage = try await fixture.read()
        XCTAssertEqual(usage.totalTokens, 720)
        XCTAssertEqual(Set(usage.activityEvents.map(\.streamID)).count, 2)
        XCTAssertEqual(Set(usage.tokenEvents.compactMap { $0.attribution?.sessionID }).count, 2)
        XCTAssertEqual(usage.workTime.activeStreamCount, 2)
        XCTAssertEqual(usage.activeSeconds, usage.workTime.wallClockSeconds * 2, accuracy: 0.001)
        for event in usage.tokenEvents {
            XCTAssertFalse(event.attribution?.sessionID?.contains(fixture.root.path) ?? true)
        }
    }

    func test_independentDatabasesDoNotCollapseIdenticalAgentLocalIDs() async throws {
        let fixture = try OpenClawFixture()
        defer { fixture.remove() }
        let main = try fixture.database()
        defer { sqlite3_close(main) }
        let work = try fixture.database(agent: "work")
        defer { sqlite3_close(work) }
        try fixture.insert(OpenClawFixture.event(), into: main)
        try fixture.insert(OpenClawFixture.event(), into: work)
        let usage = try await fixture.read()
        XCTAssertEqual(usage.totalTokens, 720)
        XCTAssertEqual(usage.tokenEvents.count, 2)
        XCTAssertEqual(usage.workTime.activeStreamCount, 2)
    }

    func test_sameAgentForkCopiesCollapseButReusedIDsWithDifferentTimesSurvive() async throws {
        let fixture = try OpenClawFixture()
        defer { fixture.remove() }
        try fixture.jsonl([OpenClawFixture.event()])
        try fixture.jsonl([
            OpenClawFixture.event(),
            OpenClawFixture.event(timestamp: OpenClawFixture.timestamp + 1000),
        ], filename: "fork.jsonl")
        let usage = try await fixture.read()
        XCTAssertEqual(usage.totalTokens, 720)
        XCTAssertEqual(usage.tokenEvents.count, 2)
    }

    func test_messagesWithoutIDsAreNotMergedByEqualTokenCountsAndTime() async throws {
        let fixture = try OpenClawFixture()
        defer { fixture.remove() }
        let event = OpenClawFixture.event().replacingOccurrences(of: #""id":"a1","#, with: "")
        try fixture.jsonl([event, event])
        let usage = try await fixture.read()
        XCTAssertEqual(usage.totalTokens, 720)
        XCTAssertEqual(usage.tokenEvents.count, 2)
    }

    func test_migrationWithoutOwnTimestampUsesDatabaseDateEvenIfJSONMtimeIsInRange() async throws {
        let fixture = try OpenClawFixture()
        defer { fixture.remove() }
        let database = try fixture.database()
        defer { sqlite3_close(database) }
        let event = OpenClawFixture.event(timestamp: nil)
        try fixture.insert(
            event, into: database, createdAt: OpenClawFixture.start.addingTimeInterval(-1).timeIntervalSince1970 * 1000)
        let file = try fixture.jsonl([event])
        try FileManager.default.setAttributes(
            [.modificationDate: OpenClawFixture.start.addingTimeInterval(10)], ofItemAtPath: file.path)
        let usage = try await fixture.read()
        XCTAssertEqual(usage.totalTokens, 0)
    }

    func test_repeatReadsAndPhysicalRootAliasesDoNotDuplicateUsage() async throws {
        let fixture = try OpenClawFixture()
        defer { fixture.remove() }
        try fixture.jsonl([OpenClawFixture.event()])
        let alias = fixture.root.appendingPathComponent("alias")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: fixture.agents)
        let reader = OpenClawReader(agentsRoots: [fixture.agents, alias, fixture.agents])
        let first = try await reader.readUsage(from: OpenClawFixture.start, to: OpenClawFixture.end)
        let second = try await reader.readUsage(from: OpenClawFixture.start, to: OpenClawFixture.end)
        XCTAssertEqual(first.totalTokens, 360)
        XCTAssertEqual(first.tokenEvents, second.tokenEvents)
        XCTAssertEqual(first.activeSeconds, second.activeSeconds)
    }
}
