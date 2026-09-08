import Foundation
import XCTest
@testable import TokiUsageReaders

#if os(Linux)
    import CSQLite
#else
    import SQLite3
#endif

final class LandingOpenClawTimestampMetadataTests: XCTestCase {
    func test_sqliteInvalidFallbackDatesNeverUseDatabaseModificationDate() async throws {
        let fixture = try OpenClawFixture()
        defer { fixture.remove() }
        let schema = """
        CREATE TABLE transcript_events (
            session_id TEXT, seq INTEGER, event_json TEXT, created_at,
            PRIMARY KEY (session_id, seq)
        );
        """
        let database = try fixture.database(schema: schema)
        defer { sqlite3_close(database) }
        let undated = OpenClawFixture.event(timestamp: nil)
        for (index, value) in [
            "0", "NULL", "'not-a-date'", "-1", "1e999", "253402300800000",
        ].enumerated() {
            let event = undated.replacingOccurrences(of: #""id":"a1""#, with: #""id":"invalid-\#(index)""#)
            try fixture.execute("""
            INSERT INTO transcript_events VALUES ('session', \(index), '\(event)', \(value));
            """, in: database)
        }
        let validOwnDate = OpenClawFixture.event(id: "valid-own-date")
        try fixture.execute("""
        INSERT INTO transcript_events VALUES ('session', 100, '\(validOwnDate)', NULL);
        """, in: database)
        let databaseURL = fixture.agents.appendingPathComponent("main/agent/openclaw-agent.sqlite")
        try FileManager.default.setAttributes(
            [.modificationDate: OpenClawFixture.start.addingTimeInterval(10)],
            ofItemAtPath: databaseURL.path)

        let usage = try await fixture.read()

        XCTAssertEqual(usage.totalTokens, 360)
        XCTAssertEqual(usage.tokenEvents.count, 1)
        XCTAssertEqual(
            try XCTUnwrap(usage.tokenEvents.first).timestamp.timeIntervalSince1970,
            OpenClawFixture.timestamp / 1000,
            accuracy: 0.001)
    }

    func test_standaloneJSONLRetainsStableReadModificationDateFallback() async throws {
        let fixture = try OpenClawFixture()
        defer { fixture.remove() }
        let url = try fixture.jsonl([OpenClawFixture.event(timestamp: nil)])
        let expected = OpenClawFixture.start.addingTimeInterval(20)
        try FileManager.default.setAttributes([.modificationDate: expected], ofItemAtPath: url.path)

        let usage = try await fixture.read()

        XCTAssertEqual(usage.totalTokens, 360)
        XCTAssertEqual(
            try XCTUnwrap(usage.tokenEvents.first).timestamp.timeIntervalSince1970,
            expected.timeIntervalSince1970,
            accuracy: 0.001)
    }

    func test_transcriptUpdateAtReadBoundaryUsesTheReadSnapshotModificationDate() async throws {
        let fixture = try OpenClawFixture()
        defer { fixture.remove() }
        let initial = OpenClawFixture.event(id: "before-read", timestamp: nil)
        let updated = OpenClawFixture.event(id: "at-read", timestamp: nil)
        let url = try fixture.jsonl([initial])
        try FileManager.default.setAttributes(
            [.modificationDate: OpenClawFixture.start.addingTimeInterval(-10)],
            ofItemAtPath: url.path)
        var boundaryModificationDate: Date?
        var boundaryCalls = 0
        let reader = OpenClawReader(
            agentsRoots: [fixture.agents],
            limits: OpenClawReadLimits(),
            beforeTranscriptRead: { readURL in
                XCTAssertEqual(readURL, url)
                boundaryCalls += 1
                try Data(updated.utf8).write(to: readURL)
                try FileManager.default.setAttributes(
                    [.modificationDate: OpenClawFixture.start.addingTimeInterval(30)],
                    ofItemAtPath: readURL.path)
                boundaryModificationDate = try XCTUnwrap(
                    FileManager.default.attributesOfItem(atPath: readURL.path)[.modificationDate] as? Date)
            })

        let usage = try await reader.readUsage(from: OpenClawFixture.start, to: OpenClawFixture.end)

        XCTAssertEqual(boundaryCalls, 1)
        XCTAssertEqual(usage.totalTokens, 360)
        XCTAssertEqual(
            try XCTUnwrap(usage.tokenEvents.first).timestamp.timeIntervalSince1970,
            try XCTUnwrap(boundaryModificationDate).timeIntervalSince1970,
            accuracy: 0.001)
    }

    func test_transcriptMutationDuringReadStillRejectsTheSnapshot() throws {
        let fixture = try OpenClawFixture()
        defer { fixture.remove() }
        let original = OpenClawFixture.event(id: "original")
        let url = try fixture.jsonl([original])
        var mutated = false

        XCTAssertThrowsError(try OpenClawTranscriptIO.forEachLine(
            at: url,
            budget: OpenClawReadBudget(limits: OpenClawReadLimits())) { _, _ in
                guard !mutated else { return }
                mutated = true
                try? Data([original, OpenClawFixture.event(id: "appended")]
                    .joined(separator: "\n").utf8).write(to: url)
            }) { error in
                XCTAssertEqual(error as? OpenClawReadError, .sourceChanged)
            }
        XCTAssertTrue(mutated)
    }

    func test_metadataFallsBackPerSessionButNotPastAnExistingPreferredRow() async throws {
        let fixture = try OpenClawFixture()
        defer { fixture.remove() }
        let database = try fixture.database(schema: OpenClawSQLiteTests.bareSchema + """
        CREATE TABLE session_windows (session_id TEXT, model_provider TEXT, model TEXT);
        CREATE TABLE sessions (session_id TEXT, model_provider TEXT, model TEXT);
        INSERT INTO session_windows VALUES ('preferred', NULL, NULL);
        INSERT INTO sessions VALUES ('preferred', 'anthropic', 'claude-opus-4-6');
        INSERT INTO sessions VALUES ('legacy-only', 'openai', 'gpt-5.2');
        """)
        defer { sqlite3_close(database) }
        let legacyOnly = metadataFreeEvent(id: "legacy", timestamp: OpenClawFixture.timestamp)
        let preferred = metadataFreeEvent(id: "preferred", timestamp: OpenClawFixture.timestamp + 1000)
        try fixture.insert(legacyOnly, into: database, session: "legacy-only")
        try fixture.insert(preferred, into: database, session: "preferred")

        let usage = try await fixture.read()

        XCTAssertEqual(usage.tokenEvents.map(\.model), ["gpt-5.2", nil])
        XCTAssertEqual(usage.tokenEvents.map(\.provider), ["openai", nil])
    }

    func test_legacyMetadataFallbackRemainsRowBoundedWithoutEventAmplification() async throws {
        let fixture = try OpenClawFixture()
        defer { fixture.remove() }
        let model = String(repeating: "m", count: 4096)
        let database = try fixture.database(schema: OpenClawSQLiteTests.bareSchema + """
        CREATE TABLE session_windows (session_id TEXT, model_provider TEXT, model TEXT);
        CREATE TABLE sessions (session_id TEXT, model_provider TEXT, model TEXT);
        INSERT INTO sessions VALUES ('session', 'synthetic', '\(model)');
        INSERT INTO sessions VALUES ('session', 'duplicate', 'must-not-amplify');
        """)
        defer { sqlite3_close(database) }
        try fixture.insert(metadataFreeEvent(id: "bounded", timestamp: OpenClawFixture.timestamp), into: database)

        let usage = try await fixture.read()

        XCTAssertEqual(usage.totalTokens, 360)
        XCTAssertEqual(usage.tokenEvents.count, 1)
        XCTAssertEqual(usage.tokenEvents.first?.model, model)

        var limits = OpenClawReadLimits()
        limits.maximumRecordBytes = 1024
        let reader = OpenClawReader(agentsRoots: [fixture.agents], limits: limits)
        do {
            _ = try await reader.readUsage(from: OpenClawFixture.start, to: OpenClawFixture.end)
            XCTFail("Oversized fallback metadata must remain bounded")
        } catch {
            XCTAssertEqual(error as? OpenClawReadError, .limitExceeded)
        }
    }

    private func metadataFreeEvent(id: String, timestamp: Double) -> String {
        OpenClawFixture.event(id: id, model: nil, timestamp: timestamp)
            .replacingOccurrences(of: #""provider":"anthropic""#, with: #""provider":null"#)
    }
}
