import Foundation
import TokiUsageCore
import TokiUsageReaders
import XCTest

final class OpenCodeDiscoveryTests: XCTestCase {
    func test_defaultAndChannelDatabasesAreDiscoveredOnEveryRead() async throws {
        let fixture = try OpenCodeFixture()
        defer { fixture.remove() }
        let first = try OpenCodeTestDatabase(at: fixture.root.appendingPathComponent("opencode.db"))
        try first.insert(fixture.payload())
        let reader = OpenCodeReader(dataRoots: [fixture.root])
        let before = try await read(reader)
        let second = try OpenCodeTestDatabase(at: fixture.root.appendingPathComponent("opencode-pr_42.1.db"))
        try second.insert(fixture.payload(id: "channel-message"), id: "channel-message")
        let after = try await read(reader)

        XCTAssertEqual(before.totalTokens, 158)
        XCTAssertEqual(after.totalTokens, 316)
        XCTAssertEqual(after.workTime.activeStreamCount, 2)
        XCTAssertEqual(try reader.sourceLocations().databaseURLs.count, 2)
    }

    func test_independentRootsWithIdenticalIDsAndPayloadsAreNotDeduplicated() async throws {
        let fixture = try OpenCodeFixture()
        defer { fixture.remove() }
        let roots = [fixture.root.appendingPathComponent("one"), fixture.root.appendingPathComponent("two")]
        let first = try OpenCodeTestDatabase(at: roots[0].appendingPathComponent("opencode.db"))
        let second = try OpenCodeTestDatabase(at: roots[1].appendingPathComponent("opencode.db"))
        for database in [first, second] {
            try database.insert(fixture.payload(cost: 0.5))
            try fixture.writeJSON(fixture.payload(cost: 0.5), root: database.url.deletingLastPathComponent())
        }
        let reader = OpenCodeReader(dataRoots: roots)
        let usage = try await read(reader)
        let reversed = try await read(OpenCodeReader(dataRoots: Array(roots.reversed())))

        XCTAssertEqual(usage.tokenEvents.count, 2)
        XCTAssertEqual(usage.totalTokens, 316)
        XCTAssertEqual(usage.cost, 1)
        XCTAssertEqual(Set(usage.tokenEvents.compactMap { $0.attribution?.sessionID }).count, 2)
        XCTAssertEqual(Set(usage.activityEvents.map(\.streamID)).count, 2)
        XCTAssertEqual(usage.workTime.activeStreamCount, 2)
        XCTAssertEqual(usage.workTime.maxConcurrentStreams, 2)
        XCTAssertEqual(usage.workTime.agentSeconds, 60)
        XCTAssertEqual(usage.workTime.wallClockSeconds, 30)
        XCTAssertEqual(usage.tokenEvents, reversed.tokenEvents)
    }

    func test_independentChannelsWithConflictingIDsStayDistinct() async throws {
        let fixture = try OpenCodeFixture()
        defer { fixture.remove() }
        let first = try OpenCodeTestDatabase(at: fixture.root.appendingPathComponent("opencode.db"))
        let second = try OpenCodeTestDatabase(at: fixture.root.appendingPathComponent("opencode-next.db"))
        try first.insert(fixture.payload(input: 100))
        try second.insert(fixture.payload(input: 200))
        let usage = try await read(OpenCodeReader(dataRoots: [fixture.root]))

        XCTAssertEqual(usage.inputTokens, 300)
        XCTAssertEqual(usage.tokenEvents.count, 2)
        XCTAssertEqual(Set(usage.activityEvents.map(\.streamID)).count, 2)
    }

    func test_physicalDatabaseAndRootAliasesAreReadOnce() async throws {
        let fixture = try OpenCodeFixture()
        defer { fixture.remove() }
        let root = fixture.root.appendingPathComponent("real")
        let database = try OpenCodeTestDatabase(at: root.appendingPathComponent("opencode.db"))
        try database.insert(fixture.payload())
        let alias = fixture.root.appendingPathComponent("alias")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: root)
        try FileManager.default.createSymbolicLink(
            at: root.appendingPathComponent("opencode-linked.db"), withDestinationURL: database.url)
        try FileManager.default.linkItem(at: database.url, to: root.appendingPathComponent("opencode-hardlink.db"))
        let reader = OpenCodeReader(dataRoots: [root, alias], databaseURLs: [database.url])
        let usage = try await read(reader)

        XCTAssertEqual(usage.totalTokens, 158)
        XCTAssertEqual(try reader.sourceLocations().databaseURLs.count, 1)
    }

    func test_allowlistIgnoresUnrelatedFilesSidecarsAndDeeperDatabases() async throws {
        let fixture = try OpenCodeFixture()
        defer { fixture.remove() }
        let database = try OpenCodeTestDatabase(at: fixture.root.appendingPathComponent("opencode.db"))
        try database.insert(fixture.payload())
        for name in ["unrelated.db", "opencode-.db", "opencode_stable.db", "opencode-☃.db", "notes.json"] {
            try Data("not a database".utf8).write(to: fixture.root.appendingPathComponent(name))
        }
        let nested = try OpenCodeTestDatabase(at: fixture.root.appendingPathComponent("unrelated/opencode.db"))
        try nested.insert(fixture.payload())
        let reader = OpenCodeReader(dataRoots: [fixture.root])
        let usage = try await read(reader)

        XCTAssertEqual(usage.totalTokens, 158)
        XCTAssertEqual(try reader.sourceLocations().databaseURLs, [database.url])
    }

    func test_environmentInputsAreExplicitAndRelativeRootsFallBackToInjectedHome() async throws {
        let fixture = try OpenCodeFixture()
        defer { fixture.remove() }
        let xdg = fixture.root.appendingPathComponent("xdg")
        let database = try OpenCodeTestDatabase(at: xdg.appendingPathComponent("opencode/opencode-nightly.db"))
        try database.insert(fixture.payload())
        let custom = try OpenCodeTestDatabase(at: fixture.root.appendingPathComponent("custom/opencode.db"))
        try custom.insert(fixture.payload(input: 200))
        let reader = OpenCodeReader(homeDirectory: fixture.root, environment: [
            "XDG_DATA_HOME": xdg.path, "OPENCODE_DB": custom.url.path,
        ])
        let usage = try await read(reader)
        XCTAssertEqual(usage.inputTokens, 300)

        let fallback = OpenCodeReader(homeDirectory: fixture.root, environment: ["XDG_DATA_HOME": "relative"])
        XCTAssertEqual(
            try fallback.sourceLocations().dataRoots,
            [fixture.root.appendingPathComponent(".local/share/opencode")])
    }

    func test_dualSchemaMigrationPrefersV2AndKeepsUnmigratedV1() async throws {
        let fixture = try OpenCodeFixture()
        defer { fixture.remove() }
        let database = try OpenCodeTestDatabase(
            at: fixture.root.appendingPathComponent("opencode.db"),
            schema: OpenCodeTestDatabase.v1Schema + OpenCodeTestDatabase.v2Schema)
        try database.insert(fixture.payload(input: 100))
        try database.insert(fixture.payload(input: 200, v2: true), v2: true)
        try database.insert(fixture.payload(id: "old-only", input: 7), id: "old-only")
        try fixture.writeJSON(fixture.payload(input: 10))
        let usage = try await read(OpenCodeReader(dataRoots: [fixture.root]))

        XCTAssertEqual(usage.inputTokens, 207)
        XCTAssertEqual(usage.tokenEvents.count, 2)
    }

    func test_databaseIdentityPrecedesDateFilteringForStaleLegacyCopies() async throws {
        let fixture = try OpenCodeFixture()
        defer { fixture.remove() }
        let database = try OpenCodeTestDatabase(at: fixture.root.appendingPathComponent("opencode.db"))
        try database.insert(fixture.payload(date: OpenCodeFixture.date.addingTimeInterval(3600)))
        try fixture.writeJSON(fixture.payload())
        let usage = try await read(OpenCodeReader(dataRoots: [fixture.root]))

        XCTAssertEqual(usage.totalTokens, 0)
        XCTAssertTrue(usage.tokenEvents.isEmpty)
    }

    func test_emptySupportedAndMissingStoresReturnEmptyWithoutCreatingFiles() async throws {
        let fixture = try OpenCodeFixture()
        defer { fixture.remove() }
        let missing = fixture.root.appendingPathComponent("missing")
        let empty = try await read(OpenCodeReader(dataRoots: [missing]))
        XCTAssertFalse(empty.hasReportableData)
        XCTAssertFalse(FileManager.default.fileExists(atPath: missing.path))
        let database = try OpenCodeTestDatabase(at: fixture.root.appendingPathComponent("opencode.db"))
        let supported = try await read(OpenCodeReader(databaseURLs: [database.url]))
        XCTAssertFalse(supported.hasReportableData)
    }

    func test_limitsFailInsteadOfReturningPartialTotals() async throws {
        let fixture = try OpenCodeFixture()
        defer { fixture.remove() }
        try fixture.writeJSON(fixture.payload())
        try fixture.writeJSON(fixture.payload(id: "second"), filename: "second.json")
        let limits = OpenCodeReadLimits(maximumFileCount: 1)
        do {
            _ = try await read(OpenCodeReader(dataRoots: [fixture.root], limits: limits))
            XCTFail("A truncated directory must not be reported as complete usage")
        } catch OpenCodeReaderError.limitExceeded {
            // Expected.
        }
    }

    func test_cancelledReadThrowsEvenWhenStoreIsMissing() async throws {
        let fixture = try OpenCodeFixture()
        defer { fixture.remove() }
        let reader = OpenCodeReader(dataRoots: [fixture.root])
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await reader.readUsage(
                from: OpenCodeFixture.date,
                to: OpenCodeFixture.date.addingTimeInterval(60))
        }
        do {
            _ = try await task.value
            XCTFail("Cancellation must not be converted to no-data")
        } catch is CancellationError {
            // Expected.
        }
    }

    private func read(_ reader: OpenCodeReader) async throws -> RawTokenUsage {
        try await reader.readUsage(
            from: OpenCodeFixture.date.addingTimeInterval(-1), to: OpenCodeFixture.date.addingTimeInterval(120))
    }
}
