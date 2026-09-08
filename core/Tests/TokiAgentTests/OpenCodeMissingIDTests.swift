import Foundation
import TokiUsageCore
import TokiUsageReaders
import XCTest

final class OpenCodeMissingIDTests: XCTestCase {
    func test_nullSQLIDsWithoutPayloadIDsPreservePhysicalRows() async throws {
        let fixture = try OpenCodeFixture()
        defer { fixture.remove() }
        let database = try OpenCodeTestDatabase(at: fixture.root.appendingPathComponent("opencode.db"))
        try database.insert(fixture.payload(id: nil), id: "temporary-1")
        try database.insert(fixture.payload(id: nil), id: "temporary-2")
        try database.execute("UPDATE message SET id = NULL")

        let usage = try await OpenCodeReader(databaseURLs: [database.url]).readUsage(
            from: OpenCodeFixture.date, to: OpenCodeFixture.date.addingTimeInterval(60))

        XCTAssertEqual(usage.tokenEvents.count, 2)
        XCTAssertEqual(usage.totalTokens, 316)
    }
}

extension OpenCodeMissingIDTests {
    func test_missingAndBlankSQLAndJSONIDsPreserveSameSessionRows() async throws {
        for v2 in [false, true] {
            for sqlID in ["NULL", "''", "' ' || char(9) || char(10)"] {
                let fixture = try OpenCodeFixture()
                defer { fixture.remove() }
                let database = try makeDatabase(fixture, v2: v2)
                for jsonID: Any in [NSNull(), "", " \t\n"] {
                    var payload = fixture.payload(id: nil, v2: v2)
                    payload["id"] = jsonID
                    try insert(payload, into: database, sqlID: sqlID, v2: v2)
                    try insert(payload, into: database, sqlID: sqlID, v2: v2)
                }
                let usage = try await read(database)
                XCTAssertEqual(usage.tokenEvents.count, 6, "v2=\(v2), SQL=\(sqlID)")
                XCTAssertEqual(usage.totalTokens, 948)
            }
        }
    }

    func test_noIDColumnPreservesIdenticalRowsAndNumericLegacyID() async throws {
        let fixture = try OpenCodeFixture()
        defer { fixture.remove() }
        let database = try makeDatabase(fixture, hasID: false)
        try insert(fixture.payload(id: nil), into: database, sqlID: nil)
        try insert(fixture.payload(id: nil), into: database, sqlID: nil)
        try fixture.writeJSON(fixture.payload(id: "1"))

        let usage = try await read(database)
        XCTAssertEqual(usage.tokenEvents.count, 3)
        XCTAssertEqual(usage.totalTokens, 474)
    }

    func test_JSONIDWinsOverSQLIDAndDatabaseWinsMigrationOverlap() async throws {
        let fixture = try OpenCodeFixture()
        defer { fixture.remove() }
        let database = try makeDatabase(fixture)
        try insert(fixture.payload(id: "json-id", input: 200), into: database, sqlID: "'sql-id'")
        try insert(fixture.payload(id: "blank-sql-a", input: 300), into: database, sqlID: "''")
        try insert(fixture.payload(id: "blank-sql-b", input: 400), into: database, sqlID: "''")
        for id in ["json-id", "sql-id", "blank-sql-a", "blank-sql-b"] {
            try fixture.writeJSON(fixture.payload(id: id, input: 1), filename: "\(id).json")
        }

        let usage = try await read(database)
        XCTAssertEqual(usage.tokenEvents.count, 4)
        XCTAssertEqual(usage.inputTokens, 901)
    }

    func test_physicalRowIDDoesNotCollideWithSQLOrJSONLogicalIDs() async throws {
        let fixture = try OpenCodeFixture()
        defer { fixture.remove() }
        let database = try makeDatabase(fixture)
        try insert(fixture.payload(id: nil), into: database, sqlID: "NULL") // Hidden rowid 1.
        try insert(fixture.payload(id: nil, input: 200), into: database, sqlID: "'1'")
        try insert(fixture.payload(id: nil, input: 300), into: database, sqlID: "NULL") // Hidden rowid 3.
        try fixture.writeJSON(fixture.payload(id: "1", input: 1), filename: "1.json")
        try fixture.writeJSON(fixture.payload(id: "3", input: 400), filename: "3.json")

        let usage = try await read(database)
        XCTAssertEqual(usage.tokenEvents.count, 4)
        XCTAssertEqual(usage.inputTokens, 1000)
    }

    func test_v2AuthorityRequiresGenuineIDAcrossTables() async throws {
        let fixture = try OpenCodeFixture()
        defer { fixture.remove() }
        let database = try makeDatabase(fixture)
        try database.execute("""
        CREATE TABLE session_message (id TEXT, session_id TEXT, type TEXT, data TEXT)
        """)
        for v2 in [false, true] {
            try insert(fixture.payload(id: nil, v2: v2), into: database, sqlID: "NULL", v2: v2)
            try insert(fixture.payload(id: nil, v2: v2), into: database, sqlID: "''", v2: v2)
            try insert(
                fixture.payload(id: "shared", input: v2 ? 200 : 1, v2: v2),
                into: database, sqlID: "'different-\(v2)'", v2: v2)
            try insert(
                fixture.payload(id: nil, input: v2 ? 300 : 1, v2: v2),
                into: database, sqlID: "'shared-sql'", v2: v2)
        }
        try fixture.writeJSON(fixture.payload(id: "shared", input: 1))
        try fixture.writeJSON(fixture.payload(id: "shared-sql", input: 1), filename: "sql.json")

        let usage = try await read(database)
        XCTAssertEqual(usage.tokenEvents.count, 6)
        XCTAssertEqual(usage.inputTokens, 900)
    }
}

extension OpenCodeMissingIDTests {
    func test_withoutRowidPreservesIdlessAndLogicalRowsWithOrWithoutIDColumn() async throws {
        for hasID in [false, true] {
            let fixture = try OpenCodeFixture()
            defer { fixture.remove() }
            let database = try makeDatabase(
                fixture, hasID: hasID, extraColumns: ", physical_key INTEGER PRIMARY KEY", withoutRowid: true)
            for key in 1...4 {
                try insert(
                    fixture.payload(id: key == 3 ? "json-id" : nil), into: database,
                    sqlID: hasID ? (key == 4 ? "'sql-id'" : "NULL") : nil,
                    extraColumns: ", physical_key", extraValues: ", \(key)")
            }
            try fixture.writeJSON(fixture.payload(id: "json-id", input: 1))
            if hasID {
                try fixture.writeJSON(fixture.payload(id: "sql-id", input: 1), filename: "sql.json")
            }
            let first = try await read(database)
            let second = try await read(database)
            XCTAssertEqual(first.tokenEvents.count, 4)
            XCTAssertEqual(first.totalTokens, 632)
            XCTAssertEqual(first.tokenEvents, second.tokenEvents)
        }
    }

    func test_withoutRowidV2WithValidSQLAndJSONIDsRemainsReadable() async throws {
        let fixture = try OpenCodeFixture()
        defer { fixture.remove() }
        let database = try OpenCodeTestDatabase(
            at: fixture.root.appendingPathComponent("opencode.db"),
            schema: """
            CREATE TABLE session_message (id TEXT PRIMARY KEY, session_id TEXT, type TEXT, data TEXT) WITHOUT ROWID
            """)
        try insert(fixture.payload(id: nil, v2: true), into: database, sqlID: "'sql-id'", v2: true)
        try insert(fixture.payload(id: "json-id", v2: true), into: database, sqlID: "''", v2: true)
        let usage = try await read(database)
        XCTAssertEqual(usage.tokenEvents.count, 2)
        XCTAssertEqual(usage.totalTokens, 316)
    }

    func test_shadowedRowidAliasesIncludingGeneratedColumnsPreserveRows() async throws {
        let shadows = [
            ", RoWiD TEXT DEFAULT 'same'",
            ", RoWiD TEXT DEFAULT 'same', _RoWiD_ TEXT DEFAULT 'same'",
            ", RoWiD TEXT DEFAULT 'same', _RoWiD_ TEXT DEFAULT 'same', OiD TEXT DEFAULT 'same'",
            ", RoWiD TEXT GENERATED ALWAYS AS ('same') VIRTUAL",
            """
            , RoWiD TEXT GENERATED ALWAYS AS ('same') VIRTUAL,
            _RoWiD_ TEXT GENERATED ALWAYS AS ('same') STORED, OiD TEXT GENERATED ALWAYS AS ('same') VIRTUAL
            """,
        ]
        for shadow in shadows {
            for hasID in [false, true] {
                let fixture = try OpenCodeFixture()
                defer { fixture.remove() }
                let database = try makeDatabase(fixture, hasID: hasID, extraColumns: shadow)
                for _ in 0..<2 {
                    try insert(fixture.payload(id: nil), into: database, sqlID: hasID ? "NULL" : nil)
                }
                try fixture.writeJSON(fixture.payload(id: "1"))
                let usage = try await read(database)
                XCTAssertEqual(usage.tokenEvents.count, 3, "hasID=\(hasID), \(shadow)")
                XCTAssertEqual(usage.totalTokens, 474)
            }
        }
    }

    private func makeDatabase(
        _ fixture: OpenCodeFixture,
        v2: Bool = false,
        hasID: Bool = true,
        extraColumns: String = "",
        withoutRowid: Bool = false) throws -> OpenCodeTestDatabase {
        try OpenCodeTestDatabase(
            at: fixture.root.appendingPathComponent("opencode.db"), schema: """
            CREATE TABLE \(v2 ? "session_message" : "message") (
                \(hasID ? "id TEXT," : "") session_id TEXT, time_created INTEGER, data TEXT,
                type TEXT DEFAULT 'assistant' \(extraColumns)
            ) \(withoutRowid ? "WITHOUT ROWID" : "")
            """)
    }

    private func insert(
        _ payload: [String: Any],
        into database: OpenCodeTestDatabase,
        sqlID: String?,
        v2: Bool = false,
        extraColumns: String = "",
        extraValues: String = "") throws {
        // Only generated synthetic fixtures enter this SQL literal; escape JSON apostrophes.
        let data = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
        let json = try XCTUnwrap(String(data: data, encoding: .utf8)).replacingOccurrences(of: "'", with: "''")
        try database.execute("""
        INSERT INTO \(v2 ? "session_message" : "message")
            (\(sqlID == nil ? "" : "id,") session_id, data, type \(extraColumns))
        VALUES (\(sqlID.map { "\($0)," } ?? "") 'session-1', '\(json)', 'assistant' \(extraValues))
        """)
    }

    private func read(_ database: OpenCodeTestDatabase) async throws -> RawTokenUsage {
        try await OpenCodeReader(databaseURLs: [database.url]).readUsage(
            from: OpenCodeFixture.date, to: OpenCodeFixture.date.addingTimeInterval(60))
    }
}
