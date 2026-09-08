import Foundation
import TokiUsageCore
import XCTest
@testable import TokiUsageReaders

#if os(Linux)
    import CSQLite
#else
    import SQLite3
#endif

final class OpenClawReadRegressionTests: XCTestCase {
    func test_inRangeIndependentSessionSurvivesEarlierOutOfRangeReusedID() async throws {
        let fixture = try OpenClawFixture()
        defer { fixture.remove() }
        let database = try fixture.database()
        defer { sqlite3_close(database) }
        let event = try timestampLessEvent()
        let start = OpenClawFixture.start
        // Same physical agent/database; independent sessions a/b, not migration replicas.
        try fixture.insert(event, into: database, session: "b", createdAt: start.timeIntervalSince1970)
        try assertBounded(fixture, projectedBytes: 2 * event.utf8.count)
        let control = try await fixture.read()
        XCTAssertEqual(control.totalTokens, 360, "Session b alone at the inclusive start must be readable")
        XCTAssertEqual(control.tokenEvents.map(\.timestamp), [start])

        try fixture.insert(
            event, into: database, session: "a", createdAt: start.addingTimeInterval(-1).timeIntervalSince1970)
        try assertBounded(fixture, projectedBytes: 2 * event.utf8.count)
        let usage = try await fixture.read()
        XCTAssertEqual(usage.totalTokens, 360, "An earlier out-of-range independent session must not suppress b")
        XCTAssertEqual(usage.tokenEvents.map(\.timestamp), [start], "The inclusive-start event must survive")
        XCTAssertEqual(
            usage.tokenEvents.first?.attribution,
            control.tokenEvents.first?.attribution,
            "The surviving event must retain session b's source identity")
    }

    func test_independentInRangeSessionsPreserveReusedIDModelsAndProviders() async throws {
        let fixture = try OpenClawFixture()
        defer { fixture.remove() }
        let database = try fixture.database()
        defer { sqlite3_close(database) }
        let first = try timestampLessEvent(model: "claude-opus-4-6", provider: "anthropic")
        let second = try timestampLessEvent(model: "gpt-5.2", provider: "openai")
        let start = OpenClawFixture.start
        let later = start.addingTimeInterval(1)
        try fixture.insert(first, into: database, session: "a", createdAt: start.timeIntervalSince1970)
        try fixture.insert(second, into: database, session: "b", createdAt: later.timeIntervalSince1970)
        try assertBounded(fixture, projectedBytes: first.utf8.count + second.utf8.count)
        let usage = try await fixture.read()
        XCTAssertEqual(usage.totalTokens, 720, "Both independent in-range sessions must contribute usage")
        XCTAssertEqual(usage.tokenEvents.map(\.timestamp), [start, later], "Both fallback dates must survive")
        XCTAssertEqual(
            usage.tokenEvents.compactMap(\.model),
            ["claude-opus-4-6", "gpt-5.2"],
            "Independent session models must both survive reused IDs")
        XCTAssertEqual(
            usage.tokenEvents.compactMap(\.provider),
            ["anthropic", "openai"],
            "Independent session providers must both survive reused IDs")
        XCTAssertEqual(
            Set(usage.tokenEvents.compactMap { $0.attribution?.sessionID }).count,
            2,
            "Independent sessions in one agent must retain two source identities")

        // Positive control: identical data and schema with only the second ID changed.
        let distinct = try timestampLessEvent(id: "b1", model: "gpt-5.2", provider: "openai")
        try fixture.execute("DELETE FROM transcript_events WHERE session_id = 'b'", in: database)
        try fixture.insert(distinct, into: database, session: "b", createdAt: later.timeIntervalSince1970)
        try assertBounded(fixture, projectedBytes: first.utf8.count + distinct.utf8.count)
        let control = try await fixture.read()
        XCTAssertEqual(control.totalTokens, 720)
        XCTAssertEqual(control.tokenEvents.compactMap(\.model), ["claude-opus-4-6", "gpt-5.2"])
        XCTAssertEqual(Set(control.tokenEvents.compactMap { $0.attribution?.sessionID }).count, 2)
        let halfOpen = try await OpenClawReader(agentsURLOverride: fixture.agents)
            .readUsage(from: start, to: later)
        XCTAssertEqual(halfOpen.totalTokens, 360, "The control interval includes start and excludes its end")
        XCTAssertEqual(halfOpen.tokenEvents.map(\.timestamp), [start])
    }

    func test_actualTimestampLessDatabaseJSONReplicaCountsOnceAndKeepsJSONOnlyHistory() async throws {
        let fixture = try OpenClawFixture()
        defer { fixture.remove() }
        let database = try fixture.database()
        defer { sqlite3_close(database) }
        let replica = try timestampLessEvent()
        let jsonOnly = try timestampLessEvent(id: "json-only")
        let start = OpenClawFixture.start
        // session.jsonl and DB session 'session' are copies of the SAME source event.
        try fixture.insert(replica, into: database, session: "session", createdAt: start.timeIntervalSince1970)
        let json = try fixture.jsonl([replica, jsonOnly], filename: "session.jsonl")
        try FileManager.default.setAttributes(
            [.modificationDate: start.addingTimeInterval(2)], ofItemAtPath: json.path)
        try assertBounded(fixture, projectedBytes: 3 * 1024)
        let usage = try await fixture.read()
        XCTAssertEqual(usage.totalTokens, 720, "A real DB/JSON replica must count once, retaining JSON-only usage")
        XCTAssertEqual(
            usage.tokenEvents.map(\.timestamp),
            [start, start.addingTimeInterval(2)],
            "The database fallback date must remain authoritative for the replica")
        XCTAssertEqual(Set(usage.tokenEvents.compactMap { $0.attribution?.sessionID }).count, 1)
        XCTAssertEqual(usage.activityEvents.count, 2)
        XCTAssertEqual(usage.cost, 0.0072, accuracy: 0.000001)
    }

    func test_outOfRangeDatabaseReplicaIsNotResurrectedByInRangeJSONModificationDate() async throws {
        let fixture = try OpenClawFixture()
        defer { fixture.remove() }
        let database = try fixture.database()
        defer { sqlite3_close(database) }
        let event = try timestampLessEvent()
        try fixture.insert(
            event, into: database, session: "session",
            createdAt: OpenClawFixture.start.addingTimeInterval(-1).timeIntervalSince1970)
        let json = try fixture.jsonl([event], filename: "session.jsonl")
        try FileManager.default.setAttributes(
            [.modificationDate: OpenClawFixture.start], ofItemAtPath: json.path)
        try assertBounded(fixture, projectedBytes: 2 * event.utf8.count)
        let usage = try await fixture.read()
        XCTAssertEqual(usage.totalTokens, 0, "An actual out-of-range DB replica must remain excluded")
        XCTAssertTrue(usage.tokenEvents.isEmpty)
    }

    /// Run this test ALONE, without --parallel. SQLite memory counters are process-global diagnostics.
    func test_boundedUnindexedMetadataSorterPublicReaderDiagnostic() async throws {
        let fixture = try OpenClawFixture()
        defer { fixture.remove() }
        // Retain the existing STRICT fixture schema, removing only the transcript ordering PK.
        let schema = OpenClawFixture.schema.replacingOccurrences(of: ", PRIMARY KEY (session_id, seq)", with: "")
        XCTAssertNotEqual(schema, OpenClawFixture.schema)
        let database = try fixture.database(schema: schema)
        defer { sqlite3_close(database) }
        let rows = 256
        let model = String(repeating: "m", count: 4096)
        let date = Int64(OpenClawFixture.timestamp)
        try fixture.execute("BEGIN", in: database)
        try fixture.execute("""
        INSERT INTO session_windows(session_id, session_key, created_at, updated_at, model_provider, model)
        VALUES ('session', 'synthetic-session', \(date), \(date), 'anthropic', '\(model)');
        """, in: database)
        var eventBytes = 0
        for seq in (0..<rows).reversed() {
            let event = try timestampLessEvent(id: "event-\(seq)", model: nil)
            eventBytes += event.utf8.count
            try fixture.insert(event, into: database, seq: seq)
        }
        try fixture.execute("COMMIT; PRAGMA wal_checkpoint(TRUNCATE)", in: database)
        // Includes metadata, keys and conservative per-row SQL record framing; payload, not heap usage.
        let projectedBytes = eventBytes + rows * (model.utf8.count + 256)
        try assertBounded(fixture, projectedBytes: projectedBytes)
        let unindexedPlan = try queryPlan(in: database)
        XCTAssertTrue(
            unindexedPlan.contains { $0.contains("USE TEMP B-TREE FOR ORDER BY") },
            "Supplementary EXPLAIN must establish the unindexed ORDER BY premise")

        var generous = OpenClawReadLimits()
        generous.maximumRecordBytes = 8192
        generous.maximumTotalBytes = 4 * 1024 * 1024
        generous.maximumRecords = rows + 1
        generous.maximumSQLiteSteps = 1_000_000
        let reader = OpenClawReader(agentsRoots: [fixture.agents], limits: generous)
        let accepted = try await reader.readUsage(from: OpenClawFixture.start, to: OpenClawFixture.end)
        XCTAssertEqual(accepted.totalTokens, rows * 360, "The actual reader must accept every synthetic row")
        XCTAssertEqual(accepted.tokenEvents.count, rows)
        XCTAssertTrue(
            accepted.tokenEvents.allSatisfy { $0.model == model },
            "The public read must actually resolve the projected session model")

        var tight = generous
        tight.maximumRecordBytes = 1024 // 4 KiB model > row guard, but < SQLite's 17 KiB length ceiling.
        tight.maximumTotalBytes = 512 * 1024
        tight.maximumRecords = 1
        // Snapshot must fit comfortably: a snapshot-budget failure would be unrelated evidence.
        let sourceBytes = try fixtureBytes(fixture)
        XCTAssertLessThan(sourceBytes, tight.maximumTotalBytes / 2)
        guard sourceBytes < tight.maximumTotalBytes / 2 else { return }
        let unindexed = await measureRejectedRead(fixture, limits: tight)

        try fixture.execute("CREATE INDEX review_transcript_order ON transcript_events(session_id, seq)", in: database)
        try fixture.execute("PRAGMA wal_checkpoint(TRUNCATE)", in: database)
        try assertBounded(fixture, projectedBytes: projectedBytes)
        let indexedPlan = try queryPlan(in: database)
        XCTAssertFalse(
            indexedPlan.contains { $0.contains("USE TEMP B-TREE FOR ORDER BY") },
            "The index control must eliminate the supplementary query's ordering sorter")
        let indexedSourceBytes = try fixtureBytes(fixture)
        XCTAssertLessThan(indexedSourceBytes, tight.maximumTotalBytes / 2)
        guard indexedSourceBytes < tight.maximumTotalBytes / 2 else { return }
        let indexed = await measureRejectedRead(fixture, limits: tight)
        // SQLite memory accounting is disabled on some Apple builds. Where available,
        // the actual reader must stay below this fixture's conservative 512 KiB budget.
        // Reintroducing the metadata join consumes over 1 MiB before rejecting the row.
        if unindexed.peak > 0, indexed.peak > 0 {
            XCTAssertLessThan(unindexed.peak - unindexed.baseline, Int64(tight.maximumTotalBytes))
            XCTAssertLessThan(indexed.peak - indexed.baseline, Int64(tight.maximumTotalBytes))
        }
        print("OpenClaw sorter diagnostic sqlite=\(String(cString: sqlite3_libversion())) rows=\(rows) "
            + "modelBytes=\(model.utf8.count) projectedPayloadUpperBound=\(projectedBytes) "
            + "sourceBytes=\(sourceBytes) indexedSourceBytes=\(indexedSourceBytes) "
            + "unindexedBaseline=\(unindexed.baseline) unindexedPeak=\(unindexed.peak) "
            + "unindexedDelta=\(unindexed.peak - unindexed.baseline) "
            + "indexedBaseline=\(indexed.baseline) indexedPeak=\(indexed.peak) "
            + "indexedDelta=\(indexed.peak - indexed.baseline)")
        print("OpenClaw supplementary EXPLAIN unindexed=\(unindexedPlan) indexed=\(indexedPlan)")
    }
}

private extension OpenClawReadRegressionTests {
    func timestampLessEvent(
        id: String = "a1", model: String? = "claude-opus-4-6", provider: String = "anthropic") throws -> String {
        let original = OpenClawFixture.event(id: id, model: model, timestamp: nil)
        var envelope = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(original.utf8)) as? [String: Any])
        var message = try XCTUnwrap(envelope["message"] as? [String: Any])
        message["provider"] = provider
        envelope["message"] = message
        XCTAssertNil(envelope["timestamp"])
        XCTAssertNil(envelope["created_at"])
        XCTAssertNil(message["timestamp"])
        XCTAssertNil(message["created_at"])
        XCTAssertEqual(envelope["id"] as? String, id)
        XCTAssertEqual(envelope["type"] as? String, "message")
        XCTAssertEqual(message["role"] as? String, "assistant")
        XCTAssertEqual(message["model"] as? String, model)
        let usage = try XCTUnwrap(message["usage"] as? [String: Any])
        XCTAssertEqual(usage["input"] as? Int, 100)
        XCTAssertEqual(usage["output"] as? Int, 50)
        XCTAssertEqual(usage["cacheRead"] as? Int, 200)
        XCTAssertEqual(usage["cacheWrite"] as? Int, 10)
        XCTAssertEqual(usage["reasoningTokens"] as? Int, 20)
        XCTAssertEqual(usage["totalTokens"] as? Int, 360)
        XCTAssertTrue(JSONSerialization.isValidJSONObject(envelope))
        let data = try JSONSerialization.data(withJSONObject: envelope, options: [.sortedKeys])
        XCTAssertLessThan(data.count, 1024)
        return try XCTUnwrap(String(data: data, encoding: .utf8))
    }

    private func fixtureBytes(_ fixture: OpenClawFixture) throws -> Int {
        let files = try XCTUnwrap(FileManager.default.enumerator(
            at: fixture.root, includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey]))
        var total = 0
        for case let url as URL in files {
            let values = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
            if values.isRegularFile == true { total += values.fileSize ?? 0 }
        }
        return total
    }

    private func assertBounded(_ fixture: OpenClawFixture, projectedBytes: Int) throws {
        // Source + one private snapshot + projected payload must stay under the worker's 16 MiB cap.
        let bytes = try fixtureBytes(fixture) * 2 + projectedBytes
        XCTAssertLessThan(bytes, 16 * 1024 * 1024)
        guard bytes < 16 * 1024 * 1024 else {
            throw NSError(domain: "OpenClawReviewReproductionFixtureCap", code: 1)
        }
    }

    private func measureRejectedRead(
        _ fixture: OpenClawFixture, limits: OpenClawReadLimits) async -> (baseline: Int64, peak: Int64) {
        let reader = OpenClawReader(agentsRoots: [fixture.agents], limits: limits)
        // Reset diagnostic high-water accounting only; never change SQLite heap limits/configuration.
        _ = sqlite3_memory_highwater(1)
        let baseline = sqlite3_memory_used()
        var readError: Error?
        do {
            _ = try await reader.readUsage(from: OpenClawFixture.start, to: OpenClawFixture.end)
        } catch {
            readError = error
        }
        let peak = sqlite3_memory_highwater(0)
        XCTAssertEqual(
            readError as? OpenClawReadError,
            .limitExceeded,
            "The actual public reader must reject oversized metadata without partial success")
        return (baseline, peak)
    }

    private func queryPlan(in database: OpaquePointer) throws -> [String] {
        // Supplementary SQL-only evidence, copied from the transcript projection.
        // This is EXPLAIN only; measureRejectedRead above invokes production readUsage, not this SQL.
        let sql = """
        EXPLAIN QUERY PLAN
        SELECT e.session_id, e.event_json, e.created_at
        FROM transcript_events e ORDER BY e.session_id, e.seq
        """
        var statement: OpaquePointer?
        let status = sqlite3_prepare_v2(database, sql, -1, &statement, nil)
        defer { sqlite3_finalize(statement) }
        XCTAssertEqual(status, SQLITE_OK)
        guard status == SQLITE_OK else { throw NSError(domain: "OpenClawReviewQueryPlan", code: Int(status)) }
        var details: [String] = []
        while true {
            let step = sqlite3_step(statement)
            if step == SQLITE_DONE { return details }
            guard step == SQLITE_ROW else { throw NSError(domain: "OpenClawReviewQueryPlan", code: Int(step)) }
            try details.append(String(cString: XCTUnwrap(sqlite3_column_text(statement, 3))))
        }
    }
}
