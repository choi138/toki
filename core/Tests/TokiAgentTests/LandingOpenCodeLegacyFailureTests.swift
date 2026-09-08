import Foundation
import TokiUsageCore
import TokiUsageReaders
import XCTest

final class LandingOpenCodeLegacyFailureTests: XCTestCase {
    func test_eachSelectedLegacyRootFailsClosedOnlyWhenWhollyUndecodable() async throws {
        let fixture = try OpenCodeFixture()
        defer { fixture.remove() }
        let emptyRoot = fixture.root.appendingPathComponent("empty")
        let unmeteredRoot = fixture.root.appendingPathComponent("unmetered")
        let migratedRoot = fixture.root.appendingPathComponent("migrated")
        let healthyRoot = fixture.root.appendingPathComponent("healthy")
        let brokenRoot = fixture.root.appendingPathComponent("broken")

        try FileManager.default.createDirectory(
            at: emptyRoot.appendingPathComponent("storage/message"),
            withIntermediateDirectories: true)
        try fixture.writeJSON(["role": "user"], root: unmeteredRoot)

        let database = try OpenCodeTestDatabase(at: migratedRoot.appendingPathComponent("opencode.db"))
        try database.insert(fixture.payload(cost: 0.5))
        try fixture.writeJSON(fixture.payload(cost: 0.5), root: migratedRoot)
        try writeMalformedLegacyRecord(root: migratedRoot, filename: "malformed.json")

        let empty = try await read(OpenCodeReader(dataRoots: [emptyRoot, unmeteredRoot]))
        XCTAssertFalse(empty.hasReportableData)

        let migrated = try await read(OpenCodeReader(dataRoots: [migratedRoot]))
        XCTAssertEqual(migrated.tokenEvents.count, 1)
        XCTAssertEqual(migrated.cost, 0.5)

        try fixture.writeJSON(fixture.payload(), root: healthyRoot)
        try writeMalformedLegacyRecord(root: brokenRoot, filename: "only-malformed.json")
        do {
            _ = try await read(OpenCodeReader(dataRoots: [healthyRoot, brokenRoot]))
            XCTFail("A healthy root must not hide a wholly undecodable selected root")
        } catch {
            XCTAssertEqual(error as? OpenCodeReaderError, .unreadableSource)
            XCTAssertEqual(error.localizedDescription, "An OpenCode usage source could not be read.")
            XCTAssertFalse(error.localizedDescription.contains(fixture.root.path))
        }
    }

    private func read(_ reader: OpenCodeReader) async throws -> RawTokenUsage {
        try await reader.readUsage(
            from: OpenCodeFixture.date.addingTimeInterval(-1),
            to: OpenCodeFixture.date.addingTimeInterval(120))
    }

    private func writeMalformedLegacyRecord(root: URL, filename: String) throws {
        let directory = root.appendingPathComponent("storage/message/synthetic-session")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data("{synthetic-invalid-json".utf8).write(to: directory.appendingPathComponent(filename))
    }
}
