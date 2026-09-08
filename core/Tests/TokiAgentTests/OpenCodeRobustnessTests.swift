import Foundation
import TokiUsageCore
import TokiUsageReaders
import XCTest

final class OpenCodeRobustnessTests: XCTestCase {
    func test_rolesAndMalformedTokenCountsDoNotCreateUsage() async throws {
        let fixture = try OpenCodeFixture()
        defer { fixture.remove() }
        let database = try OpenCodeTestDatabase(
            at: fixture.root.appendingPathComponent("opencode.db"),
            schema: OpenCodeTestDatabase.v1Schema + OpenCodeTestDatabase.v2Schema)
        try database.insert(fixture.payload())
        for (index, badCount) in [true as Any, "12", 1.5, 1_000_000_001].enumerated() {
            var payload = fixture.payload(id: "bad-\(index)")
            payload["tokens"] = ["input": badCount, "output": 20]
            try database.insert(payload, id: "bad-\(index)")
        }
        var roleless = fixture.payload(id: "roleless")
        roleless.removeValue(forKey: "role")
        try database.insert(roleless, id: "roleless")
        try fixture.writeJSON(roleless, filename: "roleless.json")
        try database.insert(fixture.payload(id: "user", v2: true), id: "user", v2: true, type: "user")
        var contradictory = fixture.payload(id: "contradictory", v2: true)
        contradictory["role"] = "user"
        try database.insert(contradictory, id: "contradictory", v2: true)
        let usage = try await read(OpenCodeReader(dataRoots: [fixture.root]))

        XCTAssertEqual(usage.totalTokens, 158)
        XCTAssertEqual(usage.tokenEvents.count, 1)
        XCTAssertEqual(usage.totalTokens, usage.perModel.values.reduce(0) { $0 + $1.totalTokens })
    }

    func test_topLevelModelAndProviderWinAndScalarPathDoesNotDropMessage() async throws {
        let fixture = try OpenCodeFixture()
        defer { fixture.remove() }
        let database = try OpenCodeTestDatabase(
            at: fixture.root.appendingPathComponent("opencode.db"), schema: OpenCodeTestDatabase.v2Schema)
        var payload = fixture.payload(cost: 3.25, v2: true)
        payload["modelID"] = "claude-sonnet-4"
        payload["providerID"] = "custom-billing-provider"
        payload["path"] = "older scalar path"
        try database.insert(payload, v2: true)
        let usage = try await read(OpenCodeReader(dataRoots: [fixture.root]))

        XCTAssertEqual(usage.totalTokens, 158)
        XCTAssertEqual(usage.tokenEvents.first?.model, "claude-sonnet-4")
        XCTAssertEqual(usage.tokenEvents.first?.provider, "custom-billing-provider")
        XCTAssertEqual(usage.cost, 3.25)
        XCTAssertEqual(usage.tokenEvents.first?.costIsKnown, true)
        XCTAssertNil(usage.tokenEvents.first?.attribution?.projectPath)
    }

    func test_negativeTokensClampWithoutBreakingConservation() async throws {
        let fixture = try OpenCodeFixture()
        defer { fixture.remove() }
        try fixture.writeJSON(fixture.payload(input: -100, output: -20, reasoning: -23, cost: -1))
        let usage = try await read(OpenCodeReader(dataRoots: [fixture.root]))

        XCTAssertEqual(usage.inputTokens, 0)
        XCTAssertEqual(usage.outputTokens, 0)
        XCTAssertEqual(usage.reasoningTokens, 0)
        XCTAssertEqual(usage.totalTokens, 15)
        XCTAssertEqual(usage.tokenEvents.first?.totalTokens, 15)
        XCTAssertEqual(usage.cost, 0)
        XCTAssertEqual(usage.tokenEvents.first?.costIsKnown, false)
    }

    func test_JSONAndDatabaseRecordSizeLimitsThrow() async throws {
        let fixture = try OpenCodeFixture()
        defer { fixture.remove() }
        try fixture.writeJSON(fixture.payload())
        let limits = OpenCodeReadLimits(maximumRecordBytes: 32)
        try await assertLimit(OpenCodeReader(dataRoots: [fixture.root], limits: limits))
        let database = try OpenCodeTestDatabase(at: fixture.root.appendingPathComponent("opencode.db"))
        try database.insert(fixture.payload())
        try await assertLimit(OpenCodeReader(databaseURLs: [database.url], limits: limits))
    }

    func test_rowAndTotalByteBudgetsThrowWithoutPartialResults() async throws {
        let fixture = try OpenCodeFixture()
        defer { fixture.remove() }
        let database = try OpenCodeTestDatabase(at: fixture.root.appendingPathComponent("opencode.db"))
        try database.insert(fixture.payload())
        try database.insert(fixture.payload(id: "second"), id: "second")
        try await assertLimit(OpenCodeReader(
            dataRoots: [fixture.root], limits: OpenCodeReadLimits(maximumRowCount: 1)))
        try await assertLimit(OpenCodeReader(
            dataRoots: [fixture.root], limits: OpenCodeReadLimits(maximumTotalBytes: 32)))
    }

    func test_SQLiteProgressBudgetInterruptsLargeScans() async throws {
        let fixture = try OpenCodeFixture()
        defer { fixture.remove() }
        let database = try OpenCodeTestDatabase(at: fixture.root.appendingPathComponent("opencode.db"))
        try database.insert(fixture.payload())
        try database.execute("""
        WITH RECURSIVE numbers(n) AS (SELECT 1 UNION ALL SELECT n + 1 FROM numbers WHERE n < 4000)
        INSERT INTO message (id, session_id, time_created, data)
        SELECT 'copy-' || n, session_id, time_created, data FROM numbers, message WHERE id = 'message-1'
        """)
        try await assertLimit(OpenCodeReader(
            dataRoots: [fixture.root], limits: OpenCodeReadLimits(maximumSQLiteSteps: 1000)))
    }

    func test_entryBudgetIncludesUnrelatedDirectoryEntries() async throws {
        let fixture = try OpenCodeFixture()
        defer { fixture.remove() }
        for index in 0..<4 {
            try Data().write(to: fixture.root.appendingPathComponent("unrelated-\(index)"))
        }
        try await assertLimit(OpenCodeReader(
            dataRoots: [fixture.root], limits: OpenCodeReadLimits(maximumEntryCount: 2)))
    }

    func test_v2WithoutMetadataAndOlderSessionMetadataRemainReadable() async throws {
        let fixture = try OpenCodeFixture()
        defer { fixture.remove() }
        let database = try OpenCodeTestDatabase(
            at: fixture.root.appendingPathComponent("opencode.db"),
            schema: "CREATE TABLE session_message (id TEXT PRIMARY KEY, session_id TEXT, type TEXT, data TEXT)")
        try database.insert(fixture.payload(v2: true), v2: true)
        let reader = OpenCodeReader(dataRoots: [fixture.root])
        let noMetadata = try await read(reader)
        XCTAssertEqual(noMetadata.tokenEvents.first?.attribution?.projectPath, "/synthetic/project")
        try database.execute("""
        CREATE TABLE session (id TEXT PRIMARY KEY, directory TEXT);
        INSERT INTO session VALUES ('session-1', '/synthetic/older-v2');
        """)
        let oldMetadata = try await read(reader)
        XCTAssertEqual(oldMetadata.totalTokens, 158)
        XCTAssertEqual(oldMetadata.tokenEvents.first?.attribution?.projectPath, "/synthetic/older-v2")
    }

    func test_distinctMessageIDsWithIdenticalContentRemainDistinct() async throws {
        let fixture = try OpenCodeFixture()
        defer { fixture.remove() }
        let database = try OpenCodeTestDatabase(at: fixture.root.appendingPathComponent("opencode.db"))
        try database.insert(fixture.payload())
        try database.insert(fixture.payload(id: "second"), id: "second")
        let usage = try await read(OpenCodeReader(dataRoots: [fixture.root]))

        XCTAssertEqual(usage.tokenEvents.count, 2)
        XCTAssertEqual(usage.totalTokens, 316)
    }

    func test_legacyTraversalSkipsDeepTreesAndFileSymlinks() async throws {
        let fixture = try OpenCodeFixture()
        defer { fixture.remove() }
        let valid = try fixture.writeJSON(fixture.payload())
        try fixture.writeJSON(fixture.payload(id: "deep"), session: "too/deep", filename: "deep.json")
        try FileManager.default.createSymbolicLink(
            at: valid.deletingLastPathComponent().appendingPathComponent("alias.json"), withDestinationURL: valid)
        let usage = try await read(OpenCodeReader(dataRoots: [fixture.root]))

        XCTAssertEqual(usage.totalTokens, 158)
        XCTAssertEqual(usage.tokenEvents.count, 1)
    }

    private func read(_ reader: OpenCodeReader) async throws -> RawTokenUsage {
        try await reader.readUsage(from: OpenCodeFixture.date, to: OpenCodeFixture.date.addingTimeInterval(60))
    }

    private func assertLimit(
        _ reader: OpenCodeReader,
        file: StaticString = #filePath,
        line: UInt = #line) async throws {
        do {
            _ = try await read(reader)
            XCTFail("Expected a bounded read failure", file: file, line: line)
        } catch OpenCodeReaderError.limitExceeded {
            // Expected.
        }
    }
}
