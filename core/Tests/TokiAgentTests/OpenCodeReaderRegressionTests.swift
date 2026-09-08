import Foundation
import TokiUsageCore
import TokiUsageReaders
import XCTest

/// This entire class and OpenCodeTestSupport.swift compile against the old public API.
/// Copy only these two files to the coordinator's baseline checkout for semantic RED.
final class OpenCodeReaderRegressionTests: XCTestCase {
    func test_legacyJSONOnlyUsesExistingDatabaseOverride() async throws {
        let fixture = try OpenCodeFixture()
        defer { fixture.remove() }
        try fixture.writeJSON(fixture.payload(cost: 0.75))

        let usage = try await read(fixture)

        XCTAssertEqual(usage.totalTokens, 158)
        XCTAssertEqual(usage.tokenEvents.count, 1)
        XCTAssertEqual(usage.tokenEvents.first?.provider, "fixture-provider")
        XCTAssertEqual(usage.tokenEvents.first?.attribution?.projectPath, "/synthetic/project")
        XCTAssertEqual(usage.cost, 0.75, accuracy: 0.000001)
        XCTAssertEqual(usage.tokenEvents.first?.costIsKnown, true)
        XCTAssertGreaterThan(usage.activeSeconds, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.root.appendingPathComponent("opencode.db").path))
    }

    func test_v1PayloadTimestampDoesNotRequireTimeCreatedColumn() async throws {
        let fixture = try OpenCodeFixture()
        defer { fixture.remove() }
        let database = try OpenCodeTestDatabase(
            at: fixture.root.appendingPathComponent("opencode.db"), schema: OpenCodeTestDatabase.payloadOnlySchema)
        try database.insert(fixture.payload(), payloadOnly: true)

        let usage = try await read(fixture)

        XCTAssertEqual(usage.totalTokens, 158)
        XCTAssertEqual(usage.tokenEvents.first?.timestamp, OpenCodeFixture.date)
    }

    func test_v2PreservesNestedUnknownModelProviderAndSessionMetadata() async throws {
        let fixture = try OpenCodeFixture()
        defer { fixture.remove() }
        let database = try OpenCodeTestDatabase(
            at: fixture.root.appendingPathComponent("opencode.db"), schema: OpenCodeTestDatabase.v2Schema)
        try database.execute("INSERT INTO session_v2 VALUES ('session-1', '/synthetic/v2', 'Synthetic session')")
        try database.insert(fixture.payload(v2: true), v2: true)

        let usage = try await read(fixture)
        let event = try XCTUnwrap(usage.tokenEvents.first)

        XCTAssertEqual(usage.totalTokens, 158)
        XCTAssertEqual(event.model, "fixture/unknown-model")
        XCTAssertEqual(event.provider, "fixture-provider")
        XCTAssertEqual(event.costIsKnown, false)
        XCTAssertEqual(event.attribution?.projectPath, "/synthetic/v2")
        XCTAssertEqual(event.attribution?.sessionLabel, "Synthetic session")
        XCTAssertEqual(event.attribution?.quality, .exact)
        XCTAssertEqual(usage.perModel["fixture/unknown-model"]?.totalTokens, 158)
    }

    func test_v1NestedModelFallbackAndReportedCostSurvive() async throws {
        let fixture = try OpenCodeFixture()
        defer { fixture.remove() }
        let database = try OpenCodeTestDatabase(at: fixture.root.appendingPathComponent("opencode.db"))
        var payload = fixture.payload(cost: 1.25, v2: true)
        payload["role"] = "assistant"
        try database.insert(payload)

        let usage = try await read(fixture)

        XCTAssertEqual(usage.tokenEvents.first?.model, "fixture/unknown-model")
        XCTAssertEqual(usage.tokenEvents.first?.provider, "fixture-provider")
        XCTAssertEqual(usage.cost, 1.25, accuracy: 0.000001)
        XCTAssertEqual(usage.tokenEvents.first?.costIsKnown, true)
        XCTAssertEqual(usage.perModel["fixture/unknown-model"]?.cost, 1.25)
    }

    func test_zeroReportedCostForUnpricedModelRemainsUnknown() async throws {
        let fixture = try OpenCodeFixture()
        defer { fixture.remove() }
        let database = try OpenCodeTestDatabase(at: fixture.root.appendingPathComponent("opencode.db"))
        try database.insert(fixture.payload(cost: 0))

        let usage = try await read(fixture)

        XCTAssertEqual(usage.tokenEvents.first?.model, "fixture/unknown-model")
        XCTAssertEqual(usage.tokenEvents.first?.costIsKnown, false)
        XCTAssertEqual(usage.cost, 0)
    }

    func test_reasoningAndOutputKeepPinnedRawTotalAndPrice() async throws {
        let fixture = try OpenCodeFixture()
        defer { fixture.remove() }
        let database = try OpenCodeTestDatabase(at: fixture.root.appendingPathComponent("opencode.db"))
        // Pinned upstream v2 fixture has output=20, reasoning=23. Its parser preserves
        // both; TokenBreakdown.total() and pricing/lookup.rs add both output buckets.
        try database.insert(fixture.payload(model: "claude-sonnet-4", cost: 0))
        let usage = try await read(fixture)
        let price = try XCTUnwrap(modelPrice(for: "claude-sonnet-4", at: OpenCodeFixture.date))
        let expected = price.cost(input: 100, output: 43, cacheRead: 10, cacheWrite: 5)

        XCTAssertEqual(usage.outputTokens, 20)
        XCTAssertEqual(usage.reasoningTokens, 23)
        XCTAssertEqual(usage.totalTokens, 158)
        XCTAssertEqual(usage.tokenEvents.reduce(0) { $0 + $1.totalTokens }, 158)
        XCTAssertEqual(usage.perModel.values.reduce(0) { $0 + $1.totalTokens }, 158)
        XCTAssertEqual(usage.cost, expected, accuracy: 0.000000001)
        XCTAssertEqual(usage.tokenEvents.first?.costIsKnown, true)
    }

    func test_partialMigrationPrefersDatabaseAndKeepsJSONOnlyRows() async throws {
        let fixture = try OpenCodeFixture()
        defer { fixture.remove() }
        let database = try OpenCodeTestDatabase(at: fixture.root.appendingPathComponent("opencode.db"))
        try database.insert(fixture.payload(input: 200, cost: 0.5))
        try fixture.writeJSON(fixture.payload(input: 100, cost: 0.25))
        try fixture.writeJSON(
            fixture.payload(id: "unmigrated", input: 7, cost: 0.1), filename: "unmigrated.json")

        let first = try await read(fixture)
        let second = try await read(fixture)

        XCTAssertEqual(first.tokenEvents.count, 2)
        XCTAssertEqual(first.inputTokens, 207)
        XCTAssertEqual(first.cost, 0.6, accuracy: 0.000001)
        XCTAssertEqual(first.tokenEvents, second.tokenEvents)
        XCTAssertEqual(Set(first.activityEvents.map(\.streamID)).count, 1)
        XCTAssertEqual(first.workTime.activeStreamCount, 1)
    }

    func test_migrationKeepsNamespacedSessionAndActivityIdentity() async throws {
        let fixture = try OpenCodeFixture()
        defer { fixture.remove() }
        try fixture.writeJSON(fixture.payload())
        let before = try await read(fixture)
        let database = try OpenCodeTestDatabase(at: fixture.root.appendingPathComponent("opencode.db"))
        try database.insert(fixture.payload())
        let after = try await read(fixture)

        let session = try XCTUnwrap(before.tokenEvents.first?.attribution?.sessionID)
        XCTAssertTrue(session.hasPrefix("opencode:"))
        XCTAssertEqual(after.tokenEvents.first?.attribution?.sessionID, session)
        XCTAssertEqual(before.activityEvents.first?.streamID, after.activityEvents.first?.streamID)
        XCTAssertEqual(after.tokenEvents.count, 1)
    }

    func test_idlessSameNamedJSONFilesRemainIndependent() async throws {
        let fixture = try OpenCodeFixture()
        defer { fixture.remove() }
        for session in ["one", "two"] {
            try fixture.writeJSON(fixture.payload(id: nil, sessionID: session), session: session)
        }
        let usage = try await read(fixture)

        XCTAssertEqual(usage.tokenEvents.count, 2)
        XCTAssertEqual(usage.totalTokens, 316)
        XCTAssertEqual(Set(usage.activityEvents.map(\.streamID)).count, 2)
    }

    func test_payloadDatesUseHalfOpenMillisecondBoundaries() async throws {
        let fixture = try OpenCodeFixture()
        defer { fixture.remove() }
        let database = try OpenCodeTestDatabase(at: fixture.root.appendingPathComponent("opencode.db"))
        for (index, offset) in [-0.001, 0, 0.001, 59.999, 60].enumerated() {
            let id = "boundary-\(index)"
            try database.insert(
                fixture.payload(id: id, date: OpenCodeFixture.date.addingTimeInterval(offset)), id: id)
        }
        let usage = try await OpenCodeReader(dbPathOverride: database.url.path).readUsage(
            from: OpenCodeFixture.date, to: OpenCodeFixture.date.addingTimeInterval(60))

        XCTAssertEqual(usage.tokenEvents.count, 3)
        XCTAssertEqual(usage.totalTokens, 474)
        XCTAssertTrue(usage.tokenEvents.allSatisfy {
            $0.timestamp >= OpenCodeFixture.date && $0.timestamp < OpenCodeFixture.date.addingTimeInterval(60)
        })
    }
}

extension OpenCodeReaderRegressionTests {
    func test_oldUnattributedRowsWithoutIDTimeOrCacheRemainReadable() async throws {
        let fixture = try OpenCodeFixture()
        defer { fixture.remove() }
        let database = try OpenCodeTestDatabase(
            at: fixture.root.appendingPathComponent("opencode.db"),
            schema: "CREATE TABLE message (session_id TEXT, time_created INTEGER, data TEXT)")
        let timestamp = Int64(OpenCodeFixture.date.timeIntervalSince1970 * 1000)
        try database.execute("""
        INSERT INTO message VALUES ('old-session', \(timestamp),
        '{"role":"assistant","tokens":{"input":300,"output":40}}')
        """)
        let usage = try await read(fixture)

        XCTAssertEqual(usage.totalTokens, 340)
        XCTAssertNil(usage.tokenEvents.first?.model)
        XCTAssertEqual(usage.perModel[UsageModelGrouping.mixedOrUnattributedKey]?.totalTokens, 340)
        XCTAssertGreaterThan(usage.activeSeconds, 0)
    }

    func test_malformedRowDoesNotDiscardValidUsage() async throws {
        let fixture = try OpenCodeFixture()
        defer { fixture.remove() }
        let database = try OpenCodeTestDatabase(at: fixture.root.appendingPathComponent("opencode.db"))
        try database.insert(fixture.payload())
        try database.execute("INSERT INTO message VALUES ('broken', 'session-1', 0, '{invalid')")
        let usage = try await read(fixture)

        XCTAssertEqual(usage.totalTokens, 158)
        XCTAssertEqual(usage.tokenEvents.count, 1)
    }

    func test_unknownDatabaseSchemaThrowsInsteadOfReportingEmptySuccess() async throws {
        let fixture = try OpenCodeFixture()
        defer { fixture.remove() }
        let database = try OpenCodeTestDatabase(
            at: fixture.root.appendingPathComponent("opencode.db"), schema: "CREATE TABLE future_usage (payload TEXT)")
        do {
            _ = try await OpenCodeReader(dbPathOverride: database.url.path).readUsage(
                from: OpenCodeFixture.date, to: OpenCodeFixture.date.addingTimeInterval(60))
            XCTFail("An unknown database schema must not become no-data")
        } catch {
            XCTAssertFalse(error.localizedDescription.isEmpty)
        }
    }

    func test_WALCommittedChangesRefreshWithoutMutatingSource() async throws {
        let fixture = try OpenCodeFixture()
        defer { fixture.remove() }
        let database = try OpenCodeTestDatabase(at: fixture.root.appendingPathComponent("opencode.db"))
        try database.execute("PRAGMA journal_mode=WAL; PRAGMA wal_autocheckpoint=0")
        try database.insert(fixture.payload())
        let walURL = URL(fileURLWithPath: database.url.path + "-wal")
        let originalDB = try Data(contentsOf: database.url)
        let originalWAL = try Data(contentsOf: walURL)

        let first = try await read(fixture)

        XCTAssertEqual(first.inputTokens, 100)
        XCTAssertEqual(try Data(contentsOf: database.url), originalDB)
        XCTAssertEqual(try Data(contentsOf: walURL), originalWAL)
        try database.execute("BEGIN IMMEDIATE; UPDATE message SET data=json_set(data, '$.tokens.input', 200)")
        let uncommitted = try await read(fixture)
        XCTAssertEqual(uncommitted.inputTokens, 100)
        try database.execute("COMMIT")
        let committed = try await read(fixture)
        XCTAssertEqual(committed.inputTokens, 200)
        XCTAssertEqual(committed.tokenEvents.count, 1)
    }

    private func read(_ fixture: OpenCodeFixture) async throws -> RawTokenUsage {
        try await OpenCodeReader(dbPathOverride: fixture.root.appendingPathComponent("opencode.db").path)
            .readUsage(
                from: OpenCodeFixture.date.addingTimeInterval(-1),
                to: OpenCodeFixture.date.addingTimeInterval(120))
    }
}
