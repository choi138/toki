import Foundation
import XCTest
@testable import TokiAgentCore
@testable import TokiUsageReaders

final class OpenCodeAliasSignatureTests: XCTestCase {
    func test_hardlinkMembershipInvalidatesSignatureWhenWALReadPathStaysTheSame() async throws {
        try await verifyAliasMembership(hardlink: true)
    }

    func test_symlinkMembershipInvalidatesSignatureWhenCanonicalPathsStayTheSame() async throws {
        try await verifyAliasMembership(hardlink: false)
    }

    private func verifyAliasMembership(hardlink: Bool) async throws {
        let fixture = try HermesM1Fixture()
        let code = try OpenCodeFixture()
        defer { fixture.remove()
            code.remove()
        }
        let producer = fixture.root.appendingPathComponent("external/selected.db")
        do { _ = try OpenCodeTestDatabase(at: producer) }
        let dataRoot = fixture.root.appendingPathComponent("data/opencode")
        let payload = code.payload(date: fixture.activityAt)
        try code.writeJSON(payload, root: dataRoot)
        // Rename an existing alias so SQLite's open file keeps a stable link count.
        let hidden = dataRoot.appendingPathComponent("unselected.db")
        let selected = dataRoot.appendingPathComponent("opencode.db")
        if hardlink {
            try FileManager.default.linkItem(at: producer, to: hidden)
        } else {
            try FileManager.default.createSymbolicLink(at: hidden, withDestinationURL: producer)
        }
        let writer = try OpenCodeTestDatabase(at: producer, schema: "")
        try writer.execute("PRAGMA journal_mode=WAL; PRAGMA wal_autocheckpoint=0;")
        let pinned = try OpenCodeTestDatabase(at: producer, schema: "BEGIN; SELECT COUNT(*) FROM message;")
        try writer.insert(payload, columnDate: fixture.activityAt)
        var environment = fixture.environment
        environment["OPENCODE_DB"] = producer.path
        let descriptor = try XCTUnwrap(LocalUsageReaderRegistry.agentDescriptors(
            home: fixture.home, environment: environment).first { $0.name == "OpenCode" })
        let builder = AgentSnapshotBuilder(
            home: fixture.home, environment: environment, readerDescriptors: [descriptor])
        let reader = OpenCodeReader(homeDirectory: fixture.home, environment: environment)
        let initial = try await reader.readUsage(from: fixture.start, to: fixture.end)
        XCTAssertEqual(initial.inputTokens, 200)
        let before = try await builder.sourceSignature(configuration: fixture.configuration(), now: fixture.now)
        try FileManager.default.moveItem(at: hidden, to: selected)
        let added = try await builder.sourceSignature(configuration: fixture.configuration(), now: fixture.now)
        XCTAssertNotEqual(before, added)
        XCTAssertEqual(try reader.sourceLocations().databaseURLs, [producer.resolvingSymlinksInPath()])
        let deduplicated = try await reader.readUsage(from: fixture.start, to: fixture.end)
        XCTAssertEqual(deduplicated.inputTokens, 100)
        let addedAfterRead = try await builder.sourceSignature(configuration: fixture.configuration(), now: fixture.now)
        try FileManager.default.moveItem(at: selected, to: hidden)
        let removed = try await builder.sourceSignature(configuration: fixture.configuration(), now: fixture.now)
        XCTAssertNotEqual(addedAfterRead, removed)
        let restored = try await reader.readUsage(from: fixture.start, to: fixture.end)
        XCTAssertEqual(restored.inputTokens, 200)
        try pinned.execute("ROLLBACK;")
    }
}
