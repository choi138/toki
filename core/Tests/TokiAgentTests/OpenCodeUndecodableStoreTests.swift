import Foundation
import TokiSyncProtocol
import TokiUsageCore
import XCTest
@testable import TokiAgentCore
@testable import TokiUsageReaders

final class OpenCodeUndecodableStoreTests: XCTestCase {
    func test_allUndecodableV1AndV2RecordsFailWithSanitizedErrors() async throws {
        let fixture = try OpenCodeFixture()
        defer { fixture.remove() }
        let undecodable = ["'{private-synthetic-message'", "''", "NULL", "'[]'", "X'fffe'"]
        for v2 in [false, true] {
            for (index, payloadSQL) in undecodable.enumerated() {
                let database = try OpenCodeTestDatabase(
                    at: fixture.root.appendingPathComponent("only-invalid-\(v2)-\(index).db"),
                    schema: v2 ? OpenCodeTestDatabase.v2Schema : OpenCodeTestDatabase.v1Schema)
                try insertRawRecord(database, v2: v2, payloadSQL: payloadSQL)
                let original = try Data(contentsOf: database.url)
                try await assertUndecodable(OpenCodeReader(databaseURLs: [database.url]), fixture: fixture)
                XCTAssertEqual(try Data(contentsOf: database.url), original)
            }
        }
    }

    func test_emptyAndValidUnmeteredStoresRemainEmptyEvenWithMalformedSiblings() async throws {
        let fixture = try OpenCodeFixture()
        defer { fixture.remove() }
        for v2 in [false, true] {
            let database = try OpenCodeTestDatabase(
                at: fixture.root.appendingPathComponent("unmetered-\(v2).db"),
                schema: v2 ? OpenCodeTestDatabase.v2Schema : OpenCodeTestDatabase.v1Schema)
            let reader = OpenCodeReader(databaseURLs: [database.url])
            let empty = try await read(reader)
            XCTAssertEqual(empty.totalTokens, 0)
            var user = fixture.payload(v2: v2)
            user["role"] = "user"
            try database.insert(user, id: "user", v2: v2, type: "user")
            let userOnly = try await read(reader)
            XCTAssertTrue(userOnly.tokenEvents.isEmpty)
            XCTAssertEqual(userOnly.cost, 0)
            try insertRawRecord(database, v2: v2, payloadSQL: "'{private-synthetic-message'")
            let mixedUnmetered = try await read(reader)
            XCTAssertEqual(mixedUnmetered.totalTokens, 0)
            XCTAssertTrue(mixedUnmetered.tokenEvents.isEmpty)
            try database.execute("DELETE FROM \(v2 ? "session_message" : "message") WHERE id = 'user'")
            try database.insert(["role": "assistant", "time": ["created": 1]], id: "unmetered", v2: v2)
            let assistantWithoutUsage = try await read(reader)
            XCTAssertEqual(assistantWithoutUsage.totalTokens, 0)
            XCTAssertEqual(assistantWithoutUsage.cost, 0)
        }
    }

    func test_mixedValidAndMalformedV1AndV2RecordsPreserveUsage() async throws {
        let fixture = try OpenCodeFixture()
        defer { fixture.remove() }
        for v2 in [false, true] {
            let database = try OpenCodeTestDatabase(
                at: fixture.root.appendingPathComponent("mixed-\(v2).db"),
                schema: v2 ? OpenCodeTestDatabase.v2Schema : OpenCodeTestDatabase.v1Schema)
            try insertRawRecord(database, v2: v2, payloadSQL: "'{private-synthetic-message'")
            try database.insert(fixture.payload(cost: 0.75, v2: v2), v2: v2)
            let reader = OpenCodeReader(databaseURLs: [database.url])
            let usage = try await read(reader)
            XCTAssertEqual(usage.inputTokens, 100)
            XCTAssertEqual(usage.outputTokens, 20)
            XCTAssertEqual(usage.reasoningTokens, 23)
            XCTAssertEqual(usage.cacheReadTokens, 10)
            XCTAssertEqual(usage.cacheWriteTokens, 5)
            XCTAssertEqual(usage.totalTokens, 158)
            XCTAssertEqual(usage.cost, 0.75)
            XCTAssertEqual(usage.tokenEvents.count, 1)
            let restarted = try await read(OpenCodeReader(databaseURLs: [database.url]))
            XCTAssertEqual(restarted.tokenEvents, usage.tokenEvents)
        }
    }

    func test_decodeValiditySpansGenerationsAndIncludesUnmeteredV2Roles() async throws {
        let fixture = try OpenCodeFixture()
        defer { fixture.remove() }
        let database = try OpenCodeTestDatabase(
            at: fixture.root.appendingPathComponent("opencode.db"),
            schema: OpenCodeTestDatabase.v1Schema + OpenCodeTestDatabase.v2Schema)
        try insertRawRecord(database, v2: false, payloadSQL: "'{private-synthetic-message'")
        try insertRawRecord(database, v2: true, payloadSQL: "'{private-synthetic-message'", type: "user")
        let reader = OpenCodeReader(databaseURLs: [database.url])
        try await assertUndecodable(reader, fixture: fixture)
        try database.insert(["role": "user"], id: "valid-user", v2: true, type: "user")
        let decodedUser = try await read(reader)
        XCTAssertEqual(decodedUser.totalTokens, 0)
        try database.insert(fixture.payload(cost: 0.5))
        let decodedUsage = try await read(reader)
        XCTAssertEqual(decodedUsage.totalTokens, 158)
        XCTAssertEqual(decodedUsage.cost, 0.5)
    }

    func test_healthyDatabaseAndLegacyRecordsCannotHideAnUndecodableStore() async throws {
        let fixture = try OpenCodeFixture()
        defer { fixture.remove() }
        let healthy = try OpenCodeTestDatabase(at: fixture.root.appendingPathComponent("healthy/opencode.db"))
        try healthy.insert(fixture.payload())
        let malformed = try OpenCodeTestDatabase(at: fixture.root.appendingPathComponent("malformed/opencode.db"))
        try insertRawRecord(malformed, v2: false, payloadSQL: "'{private-synthetic-message'")
        try fixture.writeJSON(fixture.payload(), root: malformed.url.deletingLastPathComponent())
        try await assertUndecodable(
            OpenCodeReader(databaseURLs: [healthy.url, malformed.url]), fixture: fixture)
    }

    func test_agentRejectsUndecodableV1AndV2StoresInsteadOfExportingEmptySnapshots() async throws {
        let fixture = try OpenCodeFixture()
        defer { fixture.remove() }
        let configuration = try AgentConfiguration(bundle: AgentPairingBundle(
            hubURL: XCTUnwrap(URL(string: "https://opencode-fixture.example.test")),
            deviceID: "opencode-fixture", deviceName: "synthetic",
            uploadToken: SnapshotCipher.randomToken(), encryptionKey: SnapshotCipher.generateKey(),
            retentionDays: 2, syncIntervalSeconds: 900))
        for v2 in [false, true] {
            let database = try OpenCodeTestDatabase(
                at: fixture.root.appendingPathComponent("agent-\(v2).db"),
                schema: v2 ? OpenCodeTestDatabase.v2Schema : OpenCodeTestDatabase.v1Schema)
            try insertRawRecord(database, v2: v2, payloadSQL: "'{private-synthetic-message'")
            let environment = ["OPENCODE_DB": database.url.path]
            let descriptor = LocalUsageReaderDescriptor(
                reader: OpenCodeReader(databaseURLs: [database.url]),
                sourceLocations: [.file(database.url, includesSQLiteSidecars: true)])
            let builder = AgentSnapshotBuilder(
                home: fixture.root, environment: environment, readerDescriptors: [descriptor])
            do {
                _ = try await builder.build(
                    configuration: configuration, now: OpenCodeFixture.date.addingTimeInterval(120))
                XCTFail("An undecodable store must not be exported as complete empty coverage")
            } catch let AgentSnapshotBuilderError.readerFailed(source) {
                XCTAssertEqual(source, "OpenCode")
            }
        }
    }

    private func read(_ reader: OpenCodeReader) async throws -> RawTokenUsage {
        try await reader.readUsage(from: OpenCodeFixture.date, to: OpenCodeFixture.date.addingTimeInterval(60))
    }

    private func assertUndecodable(
        _ reader: OpenCodeReader,
        fixture: OpenCodeFixture,
        file: StaticString = #filePath,
        line: UInt = #line) async throws {
        do {
            _ = try await read(reader)
            XCTFail("An entirely undecodable store must report a read failure", file: file, line: line)
        } catch {
            XCTAssertEqual(error as? OpenCodeReaderError, .unreadableSource, file: file, line: line)
            XCTAssertEqual(
                error.localizedDescription,
                "An OpenCode usage source could not be read.",
                file: file,
                line: line)
            XCTAssertFalse(error.localizedDescription.contains(fixture.root.path), file: file, line: line)
            XCTAssertFalse(error.localizedDescription.contains("private-synthetic-message"), file: file, line: line)
        }
    }

    private func insertRawRecord(
        _ database: OpenCodeTestDatabase,
        v2: Bool,
        payloadSQL: String,
        type: String = "assistant") throws {
        // SQL fragments are fixed synthetic test values, never source data or credentials.
        let table = v2 ? "session_message" : "message"
        let extraColumn = v2 ? ", type" : ""
        let extraValue = v2 ? ", '\(type)'" : ""
        try database.execute("""
        INSERT INTO \(table) (id, session_id, data\(extraColumn))
        VALUES ('malformed', 'synthetic-session', \(payloadSQL)\(extraValue))
        """)
    }
}
