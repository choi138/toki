import Foundation
import TokiUsageCore
import XCTest
@testable import TokiUsageReaders

final class OpenCodeJournalTests: XCTestCase {
    func test_hardlinkSelectsCommittedWALOnceAndKeepsSessionIdentityAfterCheckpoint() async throws {
        let fixture = try OpenCodeFixture()
        defer { fixture.remove() }
        let preferred = fixture.root.appendingPathComponent("opencode.db")
        let reader = OpenCodeReader(dataRoots: [fixture.root])
        let initial: RawTokenUsage
        do {
            let original = try OpenCodeTestDatabase(at: preferred)
            try original.insert(fixture.payload())
            initial = try await read(reader)
        }
        let producer = fixture.root.appendingPathComponent("opencode-next.db")
        try FileManager.default.linkItem(at: preferred, to: producer)
        let live = try await readPinnedWriter(fixture: fixture, producer: producer, reader: reader)
        XCTAssertEqual(live.inputTokens, 300)
        XCTAssertEqual(live.tokenEvents.count, 2)
        XCTAssertEqual(Set(live.activityEvents.map(\.streamID)), Set(initial.activityEvents.map(\.streamID)))
        let checkpointed = try await read(reader)
        XCTAssertEqual(checkpointed.tokenEvents, live.tokenEvents)
        XCTAssertEqual(try reader.sourceLocations().databaseURLs, [preferred])
    }

    private func readPinnedWriter(
        fixture: OpenCodeFixture, producer: URL, reader: OpenCodeReader) async throws -> RawTokenUsage {
        let writer = try OpenCodeTestDatabase(at: producer, schema: "")
        try writer.execute("PRAGMA journal_mode=WAL; PRAGMA wal_autocheckpoint=0; PRAGMA wal_checkpoint(TRUNCATE);")
        let live: RawTokenUsage
        do {
            let pinned = try OpenCodeTestDatabase(at: writer.url, schema: "BEGIN; SELECT COUNT(*) FROM message;")
            let checkpoint = try Data(contentsOf: writer.url)
            try writer.insert(fixture.payload(id: "wal-only", input: 200), id: "wal-only")
            XCTAssertEqual(try Data(contentsOf: writer.url), checkpoint)
            XCTAssertEqual(try reader.sourceLocations().databaseURLs, [writer.url])
            live = try await read(reader)
            try pinned.execute("ROLLBACK;")
        }
        try writer.execute("PRAGMA wal_checkpoint(TRUNCATE); PRAGMA journal_mode=DELETE;")
        return live
    }

    func test_conflictingHardlinkJournalsFailInsteadOfSelectingIncompleteUsage() throws {
        let fixture = try OpenCodeFixture()
        defer { fixture.remove() }
        let database = try OpenCodeTestDatabase(at: fixture.root.appendingPathComponent("opencode.db"))
        let alias = fixture.root.appendingPathComponent("opencode-next.db")
        try FileManager.default.linkItem(at: database.url, to: alias)
        // Discovery must reject ambiguity before opening either synthetic journal.
        for path in [database.url, alias] {
            try Data([1]).write(to: URL(fileURLWithPath: path.path + "-wal"))
        }
        XCTAssertThrowsError(try OpenCodeReader(dataRoots: [fixture.root]).sourceLocations())
    }

    func test_environmentPathsPreserveWhitespaceAndResolveAliasesOnEachRead() async throws {
        let fixture = try OpenCodeFixture()
        defer { fixture.remove() }
        let xdg = fixture.root.appendingPathComponent("data ")
        let first = try OpenCodeTestDatabase(at: xdg.appendingPathComponent("opencode/opencode.db"))
        let second = try OpenCodeTestDatabase(at: fixture.root.appendingPathComponent("second.db"))
        try first.insert(fixture.payload())
        try second.insert(fixture.payload(input: 200))
        let alias = fixture.root.appendingPathComponent("selected.db ")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: first.url)
        let reader = OpenCodeReader(homeDirectory: fixture.root, environment: [
            "XDG_DATA_HOME": xdg.path, "OPENCODE_DB": alias.path,
        ])
        let initial = try await read(reader)
        XCTAssertEqual(initial.inputTokens, 100)
        try FileManager.default.removeItem(at: alias)
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: second.url)
        let retargeted = try await read(reader)
        XCTAssertEqual(retargeted.inputTokens, 300)
        XCTAssertEqual(try reader.sourceLocations().databaseURLs.count, 2)
    }

    private func read(_ reader: OpenCodeReader) async throws -> RawTokenUsage {
        try await reader.readUsage(
            from: OpenCodeFixture.date.addingTimeInterval(-1), to: OpenCodeFixture.date.addingTimeInterval(120))
    }
}
