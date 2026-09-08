import Foundation
import TokiUsageCore
import TokiUsageReaders
import XCTest

/// Synthetic regressions for source selection and the shared SQLite read budget.
final class OpenCodeReadBudgetRegressionTests: XCTestCase {
    func test_environmentUnionConservesSourcesWhileDatabaseOverrideIsScoped() async throws {
        let fixture = try OpenCodeFixture()
        defer { fixture.remove() }
        let xdg = fixture.root.appendingPathComponent("xdg")
        let xdgRoot = xdg.appendingPathComponent("opencode")
        let customRoot = fixture.root.appendingPathComponent("custom")
        let homeRoot = fixture.root.appendingPathComponent(".local/share/opencode")
        let standard = try OpenCodeTestDatabase(at: xdgRoot.appendingPathComponent("opencode.db"))
        let channel = try OpenCodeTestDatabase(at: xdgRoot.appendingPathComponent("opencode-nightly.db"))
        let selected = try OpenCodeTestDatabase(at: customRoot.appendingPathComponent("opencode.db"))
        let sibling = try OpenCodeTestDatabase(at: customRoot.appendingPathComponent("opencode-canary.db"))
        let home = try OpenCodeTestDatabase(at: homeRoot.appendingPathComponent("opencode.db"))
        for (database, id, input) in [
            (standard, "standard", 10), (channel, "channel", 20), (selected, "selected", 40),
            (sibling, "sibling", 1000), (home, "home", 2000),
        ] {
            try database.insert(payload(fixture, id: id, input: input), id: id)
        }
        try fixture.writeJSON(
            payload(fixture, id: "xdg-legacy", input: 80), root: xdgRoot, filename: "xdg-legacy.json")
        try fixture.writeJSON(
            payload(fixture, id: "custom-legacy", input: 160), root: customRoot, filename: "custom-legacy.json")

        // Current Toki's environment API is additive, matching its existing discovery test.
        // Pinned tokscale scanner config is also additive; it does not read OPENCODE_DB itself.
        let environmentReader = OpenCodeReader(homeDirectory: fixture.root, environment: [
            "XDG_DATA_HOME": xdg.path, "OPENCODE_DB": selected.url.path,
        ])
        let locations = try environmentReader.sourceLocations()
        XCTAssertEqual(Set(locations.databaseURLs.map(\.path)), Set([
            standard.url.path, channel.url.path, selected.url.path,
        ]))
        let union = try await read(environmentReader)
        XCTAssertEqual(union.inputTokens, 310)
        XCTAssertEqual(union.tokenEvents.count, 5)
        assertConservation(union)

        // Compatibility override selects one DB plus adjacent legacy JSON, not sibling DBs.
        let overrideReader = OpenCodeReader(dbPathOverride: selected.url.path)
        XCTAssertEqual(try overrideReader.sourceLocations().databaseURLs.map(\.path), [selected.url.path])
        let scoped = try await read(overrideReader)
        XCTAssertEqual(scoped.inputTokens, 200)
        XCTAssertEqual(scoped.tokenEvents.count, 2)
        assertConservation(scoped)

        // XDG replaces the fallback home root; the environment API does not union both roots.
        let fallback = try await read(OpenCodeReader(homeDirectory: fixture.root, environment: [
            "OPENCODE_DB": selected.url.path,
        ]))
        XCTAssertEqual(fallback.inputTokens, 2200)
        XCTAssertEqual(fallback.tokenEvents.count, 3)
        assertConservation(fallback)
    }

    func test_v2IgnoredRolesExceedingAggregateBytesMustThrow() async throws {
        let fixture = try OpenCodeFixture()
        defer { fixture.remove() }
        let databases = try budgetDatabases(fixture, roles: ["user", "system"], split: false)
        let generous = try await read(OpenCodeReader(databaseURLs: databases.map(\.url), limits: limits(total: 16384)))
        XCTAssertTrue(generous.tokenEvents.isEmpty)
        XCTAssertEqual(generous.totalTokens, 0)

        // Both payloads are materialized by SQLite and must consume the shared budget.
        try await assertAggregateLimit(OpenCodeReader(databaseURLs: databases.map(\.url), limits: limits(total: 3500)))
    }

    func test_v2IgnoredRolesAcrossDatabasesMustShareAggregateByteBudget() async throws {
        let fixture = try OpenCodeFixture()
        defer { fixture.remove() }
        let databases = try budgetDatabases(fixture, roles: ["user", "system"], split: true)
        for database in databases {
            let single = try await read(OpenCodeReader(databaseURLs: [database.url], limits: limits(total: 3500)))
            XCTAssertTrue(single.tokenEvents.isEmpty)
            XCTAssertEqual(single.totalTokens, 0)
        }

        // Each DB fits alone; their selected payload bytes exceed one shared budget.
        try await assertAggregateLimit(OpenCodeReader(databaseURLs: databases.map(\.url), limits: limits(total: 3500)))
    }

    func test_v2AssistantControlEnforcesAggregateBytesWithinAndAcrossDatabases() async throws {
        let fixture = try OpenCodeFixture()
        defer { fixture.remove() }
        let databases = try budgetDatabases(fixture, roles: ["assistant", "assistant"], split: true)
        for database in databases {
            let single = try await read(OpenCodeReader(databaseURLs: [database.url], limits: limits(total: 3500)))
            XCTAssertEqual(single.totalTokens, 158)
            XCTAssertEqual(single.tokenEvents.count, 1)
            XCTAssertEqual(single.tokenEvents.first?.timestamp, OpenCodeFixture.date)
        }
        let generous = try await read(OpenCodeReader(databaseURLs: databases.map(\.url), limits: limits(total: 16384)))
        XCTAssertEqual(generous.totalTokens, 316)
        XCTAssertEqual(generous.tokenEvents.count, 2)
        assertConservation(generous)
        try await assertAggregateLimit(OpenCodeReader(databaseURLs: databases.map(\.url), limits: limits(total: 3500)))

        let togetherRoot = fixture.root.appendingPathComponent("together")
        let together = try OpenCodeTestDatabase(
            at: togetherRoot.appendingPathComponent("opencode.db"), schema: OpenCodeTestDatabase.v2Schema)
        for index in 0..<2 {
            let id = "budget-\(index)"
            try together.insert(payload(fixture, id: id, v2: true, padding: 2048), id: id, v2: true)
        }
        try await assertAggregateLimit(OpenCodeReader(databaseURLs: [together.url], limits: limits(total: 3500)))
    }

    func test_v2NormalIgnoredRolesDoNotContributeUsageBelowBudget() async throws {
        let fixture = try OpenCodeFixture()
        defer { fixture.remove() }
        let databases = try budgetDatabases(fixture, roles: ["user", "system", "assistant"], split: false)
        let usage = try await read(OpenCodeReader(databaseURLs: databases.map(\.url), limits: limits(total: 16384)))
        XCTAssertEqual(usage.totalTokens, 158)
        XCTAssertEqual(usage.inputTokens, 100)
        XCTAssertEqual(usage.tokenEvents.count, 1)
        XCTAssertEqual(usage.tokenEvents.first?.timestamp, OpenCodeFixture.date)
        assertConservation(usage)
    }

    private func budgetDatabases(
        _ fixture: OpenCodeFixture,
        roles: [String],
        split: Bool) throws -> [OpenCodeTestDatabase] {
        var databases: [OpenCodeTestDatabase] = []
        var payloadBytes = 0
        for (index, role) in roles.enumerated() {
            if split || databases.isEmpty {
                let url = fixture.root.appendingPathComponent("store-\(index)/opencode.db")
                try databases.append(OpenCodeTestDatabase(at: url, schema: OpenCodeTestDatabase.v2Schema))
            }
            let id = "budget-\(index)"
            // The same valid v2 JSON is used for assistant controls. Only SQL type changes.
            // Token-bearing ignored rows ensure role filtering, not absent tokens, explains zero usage.
            let value = try payload(fixture, id: id, v2: true, padding: 2048)
            let bytes = try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]).count
            XCTAssertLessThan(bytes, 4096, "Individual record limit must not bind")
            XCTAssertLessThan(bytes + id.utf8.count + "session-1".utf8.count, 3500, "One charged row must fit")
            payloadBytes += bytes
            let database = try XCTUnwrap(databases.last)
            try database.insert(value, id: id, v2: true, type: role)
        }
        XCTAssertGreaterThan(payloadBytes, 3500, "Payloads alone must cross the aggregate limit")
        XCTAssertLessThan(payloadBytes, 16384, "Generous control must fit")
        return databases
    }

    private func payload(
        _ fixture: OpenCodeFixture,
        id: String,
        input: Int = 100,
        v2: Bool = false,
        padding: Int = 0) throws -> [String: Any] {
        var value = fixture.payload(id: id, date: OpenCodeFixture.date, input: input, v2: v2)
        if padding > 0 { value["syntheticPadding"] = String(repeating: "x", count: padding) }
        XCTAssertTrue(JSONSerialization.isValidJSONObject(value))
        let data = try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])
        let decoded = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let time = try XCTUnwrap(decoded["time"] as? [String: Any])
        let created = try XCTUnwrap(time["created"] as? NSNumber)
        XCTAssertEqual(created.doubleValue, OpenCodeFixture.date.timeIntervalSince1970 * 1000)
        XCTAssertNotNil(decoded["tokens"] as? [String: Any])
        return value
    }

    private func limits(total: Int) -> OpenCodeReadLimits {
        OpenCodeReadLimits(
            maximumRowCount: 1000, maximumRecordBytes: 4096,
            maximumTotalBytes: total, maximumSQLiteSteps: 1_000_000)
    }

    private func read(_ reader: OpenCodeReader) async throws -> RawTokenUsage {
        try await reader.readUsage(
            from: OpenCodeFixture.date.addingTimeInterval(-1),
            to: OpenCodeFixture.date.addingTimeInterval(60))
    }

    private func assertConservation(_ usage: RawTokenUsage, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(usage.totalTokens, usage.tokenEvents.reduce(0) { $0 + $1.totalTokens }, file: file, line: line)
        XCTAssertEqual(
            usage.totalTokens, usage.perModel.values.reduce(0) { $0 + $1.totalTokens }, file: file, line: line)
    }

    private func assertAggregateLimit(
        _ reader: OpenCodeReader,
        file: StaticString = #filePath,
        line: UInt = #line) async throws {
        do {
            let usage = try await read(reader)
            XCTFail(
                "Expected limitExceeded above maximumTotalBytes; returned \(usage.totalTokens) tokens",
                file: file, line: line)
        } catch OpenCodeReaderError.limitExceeded {
            // Expected safety contract. Other errors propagate and do not satisfy the probe.
        }
    }
}
