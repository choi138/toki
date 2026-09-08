import Foundation
import TokiUsageCore
import XCTest
@testable import TokiUsageReaders

#if os(Linux)
    import CSQLite
#else
    import SQLite3
#endif

final class OpenClawReadBoundsTests: XCTestCase {
    func test_fileRecordByteAndEntryLimitsFailWithoutReturningPartialUsage() async throws {
        let fixture = try OpenClawFixture()
        defer { fixture.remove() }
        try fixture.jsonl([OpenClawFixture.event(), OpenClawFixture.event(id: "a2")])
        try fixture.jsonl([OpenClawFixture.event(id: "a3")], filename: "second.jsonl")
        var limits: [OpenClawReadLimits] = []
        var files = OpenClawReadLimits()
        files.maximumFiles = 1
        limits.append(files)
        var entries = OpenClawReadLimits()
        entries.maximumEntries = 1
        limits.append(entries)
        var records = OpenClawReadLimits()
        records.maximumRecords = 1
        limits.append(records)
        var line = OpenClawReadLimits()
        line.maximumRecordBytes = 16
        limits.append(line)
        var file = OpenClawReadLimits()
        file.maximumFileBytes = 16
        limits.append(file)
        var total = OpenClawReadLimits()
        total.maximumTotalBytes = 16
        limits.append(total)
        for limit in limits {
            let reader = OpenClawReader(agentsRoots: [fixture.agents], limits: limit)
            await assertLimit(reader)
        }
    }

    func test_sqliteRecordAndSnapshotByteLimitsAreBounded() async throws {
        let fixture = try OpenClawFixture()
        defer { fixture.remove() }
        let database = try fixture.database()
        defer { sqlite3_close(database) }
        try fixture.insert(OpenClawFixture.event(), into: database)
        try fixture.insert(OpenClawFixture.event(id: "a2"), into: database, seq: 1)
        var record = OpenClawReadLimits()
        record.maximumRecords = 1
        await assertLimit(OpenClawReader(agentsRoots: [fixture.agents], limits: record))
        var bytes = OpenClawReadLimits()
        bytes.maximumTotalBytes = 16
        await assertLimit(OpenClawReader(agentsRoots: [fixture.agents], limits: bytes))
        var row = OpenClawReadLimits()
        row.maximumRecordBytes = 16
        await assertLimit(OpenClawReader(agentsRoots: [fixture.agents], limits: row))
    }

    func test_cancelledReadPropagatesCancellation() async throws {
        let fixture = try OpenClawFixture()
        defer { fixture.remove() }
        try fixture.jsonl([OpenClawFixture.event()])
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await fixture.read()
        }
        do {
            _ = try await task.value
            XCTFail("Cancellation must not return success")
        } catch {
            XCTAssertTrue(error is CancellationError)
        }
    }

    func test_databaseQueryInstructionBudgetInterruptsLongScans() async throws {
        let fixture = try OpenClawFixture()
        defer { fixture.remove() }
        let database = try fixture.database()
        defer { sqlite3_close(database) }
        try fixture.execute("""
        WITH RECURSIVE numbers(n) AS (SELECT 1 UNION ALL SELECT n + 1 FROM numbers WHERE n < 1000)
        INSERT INTO transcript_events(session_id, seq, event_json, created_at)
        SELECT 'session', n, '{"type":"message","message":{"role":"user"}}', 1788084001000 FROM numbers;
        """, in: database)
        var limits = OpenClawReadLimits()
        limits.maximumSQLiteSteps = 0
        await assertLimit(OpenClawReader(agentsRoots: [fixture.agents], limits: limits))
    }

    func test_corruptDatabaseIsAnErrorAndSourceIsUnchanged() async throws {
        let fixture = try OpenClawFixture()
        defer { fixture.remove() }
        let url = fixture.agents.appendingPathComponent("main/agent/openclaw-agent.sqlite")
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let bytes = Data("synthetic invalid sqlite".utf8)
        try bytes.write(to: url)
        do {
            _ = try await fixture.read()
            XCTFail("Corrupt SQLite must not look empty")
        } catch {
            XCTAssertNotNil(error as? OpenClawReadError)
        }
        XCTAssertEqual(try Data(contentsOf: url), bytes)
    }

    private func assertLimit(_ reader: OpenClawReader, file: StaticString = #filePath, line: UInt = #line) async {
        do {
            _ = try await reader.readUsage(from: OpenClawFixture.start, to: OpenClawFixture.end)
            XCTFail("Expected a bounded read error", file: file, line: line)
        } catch {
            XCTAssertEqual(error as? OpenClawReadError, .limitExceeded, file: file, line: line)
        }
    }
}
