import SQLite3
import TokiUsageCore
import XCTest
@testable import Toki
@testable import TokiUsageReaders

final class CursorReaderWALTests: XCTestCase {
    func test_cursorReader_readsWALDatabaseWhoseSidecarsAreGone() async throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let dbURL = tempDir.appendingPathComponent("state.vscdb")
        try createCursorStateDB(
            at: dbURL,
            rows: [
                (
                    "bubbleId:model-gpt",
                    cursorModelBubble(
                        bubbleId: "model-gpt",
                        requestId: "usage-gpt",
                        createdAt: "2026-04-10T00:00:01Z",
                        modelName: "gpt-5.2")),
                (
                    "bubbleId:token-gpt",
                    cursorTokenBubble(
                        bubbleId: "token-gpt",
                        usageUuid: "usage-gpt",
                        createdAt: "2026-04-10T00:00:02Z",
                        input: 120,
                        output: 30)),
            ])
        try enableWAL(at: dbURL)
        for suffix in ["-wal", "-shm"] {
            try? FileManager.default.removeItem(atPath: dbURL.path + suffix)
            XCTAssertFalse(FileManager.default.fileExists(atPath: dbURL.path + suffix))
        }

        let usage = try await CursorReader(dbPathOverride: dbURL.path).readUsage(
            from: tokiTestISODate("2026-04-10T00:00:00Z"),
            to: tokiTestISODate("2026-04-11T00:00:00Z"))

        XCTAssertEqual(usage.inputTokens, 120)
        XCTAssertEqual(usage.outputTokens, 30)
    }

    private func enableWAL(at url: URL) throws {
        var db: OpaquePointer?
        guard sqlite3_open(url.path, &db) == SQLITE_OK, let db else {
            throw NSError(domain: "CursorReaderTests", code: 6)
        }
        defer { sqlite3_close(db) }
        guard sqlite3_exec(db, "PRAGMA journal_mode=WAL", nil, nil, nil) == SQLITE_OK else {
            throw NSError(domain: "CursorReaderTests", code: 7)
        }
    }
}
