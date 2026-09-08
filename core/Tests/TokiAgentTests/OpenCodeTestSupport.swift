import Foundation
import XCTest

#if os(Linux)
    import CSQLite
#else
    import SQLite3
#endif

/// Synthetic fixtures, never personal sessions. Schema and field semantics derived from
/// junhoyeo/tokscale@3bd6dceb98925edab4e149c9bb1cf3fec9123f17:
/// crates/tokscale-core/src/sessions/opencode.rs (v1/v2/legacy fixtures),
/// sessions/opencode_schema.rs (model/provider/time/cost), scanner.rs (channel names).
/// The upstream MIT notice is retained in OpenCodeSourceDiscovery.swift and LANE_REPORT.md.
final class OpenCodeFixture {
    static let date = Date(timeIntervalSince1970: 1_787_227_200) // 2026-08-20 12:00 UTC
    let root: URL

    init() throws {
        root = FileManager.default.temporaryDirectory
            .resolvingSymlinksInPath()
            .appendingPathComponent("toki-opencode-fixture-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    func remove() {
        try? FileManager.default.removeItem(at: root)
    }

    func payload(
        id: String? = "message-1",
        sessionID: String? = "session-1",
        date: Date = OpenCodeFixture.date,
        input: Int = 100,
        output: Int = 20,
        reasoning: Int = 23,
        model: String? = "fixture/unknown-model",
        cost: Double? = nil,
        v2: Bool = false) -> [String: Any] {
        var value: [String: Any] = [
            "time": ["created": date.timeIntervalSince1970 * 1000],
            "tokens": [
                "input": input, "output": output, "reasoning": reasoning,
                "cache": ["read": 10, "write": 5],
            ],
            "path": ["root": "/synthetic/project"],
        ]
        value["id"] = id
        value["sessionID"] = sessionID
        value["cost"] = cost
        if v2 {
            var descriptor: [String: Any] = ["providerID": "fixture-provider"]
            descriptor["id"] = model
            value["model"] = descriptor
        } else {
            value["role"] = "assistant"
            value["modelID"] = model
            value["providerID"] = "fixture-provider"
        }
        return value
    }

    @discardableResult
    func writeJSON(
        _ payload: [String: Any],
        root dataRoot: URL? = nil,
        session: String = "session-1",
        filename: String = "message-1.json") throws -> URL {
        let url = (dataRoot ?? root).appendingPathComponent("storage/message/\(session)/\(filename)")
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys]).write(to: url)
        return url
    }
}

final class OpenCodeTestDatabase {
    static let v1Schema = """
    CREATE TABLE message (id TEXT PRIMARY KEY, session_id TEXT, time_created INTEGER, data TEXT);
    """
    static let payloadOnlySchema = """
    CREATE TABLE message (id TEXT PRIMARY KEY, session_id TEXT NOT NULL, data TEXT NOT NULL);
    """
    static let v2Schema = """
    CREATE TABLE session_message (id TEXT PRIMARY KEY, session_id TEXT, type TEXT, data TEXT);
    CREATE TABLE session_v2 (id TEXT PRIMARY KEY, directory TEXT, title TEXT);
    """

    let url: URL
    private let database: OpaquePointer

    init(at url: URL, schema: String = OpenCodeTestDatabase.v1Schema) throws {
        self.url = url
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        var handle: OpaquePointer?
        let status = sqlite3_open(url.path, &handle)
        guard status == SQLITE_OK, let handle else {
            sqlite3_close(handle)
            throw NSError(domain: "OpenCodeFixture.open", code: Int(status))
        }
        database = handle
        try execute(schema)
    }

    deinit { sqlite3_close(database) }

    func execute(_ sql: String) throws {
        let status = sqlite3_exec(database, sql, nil, nil, nil)
        guard status == SQLITE_OK else {
            throw NSError(domain: "OpenCodeFixture.execute", code: Int(status))
        }
    }

    func insert(
        _ payload: [String: Any],
        id: String = "message-1",
        session: String = "session-1",
        v2: Bool = false,
        type: String = "assistant",
        columnDate: Date? = OpenCodeFixture.date,
        payloadOnly: Bool = false) throws {
        let data = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
        let json = try XCTUnwrap(String(data: data, encoding: .utf8))
        let sql: String
        var values = [id, session, json]
        if v2 {
            sql = "INSERT INTO session_message (id, session_id, data, type) VALUES (?, ?, ?, ?)"
            values.append(type)
        } else if payloadOnly {
            sql = "INSERT INTO message (id, session_id, data) VALUES (?, ?, ?)"
        } else {
            sql = "INSERT INTO message (id, session_id, data, time_created) VALUES (?, ?, ?, ?)"
            values.append(String((columnDate ?? OpenCodeFixture.date).timeIntervalSince1970 * 1000))
        }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw NSError(domain: "OpenCodeFixture.prepare", code: 1)
        }
        defer { sqlite3_finalize(statement) }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        for (index, value) in values.enumerated() {
            guard sqlite3_bind_text(statement, Int32(index + 1), value, -1, transient) == SQLITE_OK else {
                throw NSError(domain: "OpenCodeFixture.bind", code: 1)
            }
        }
        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw NSError(domain: "OpenCodeFixture.insert", code: 1)
        }
    }
}
