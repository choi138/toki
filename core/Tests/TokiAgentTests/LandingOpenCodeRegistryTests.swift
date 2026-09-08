import Foundation
import TokiUsageReaders
import XCTest

final class LandingOpenCodeRegistryTests: XCTestCase {
    func test_registryUsesInjectedChannelRootAndAddsExplicitDatabase() async throws {
        let fixture = try OpenCodeFixture()
        defer { fixture.remove() }
        let xdgData = fixture.root.appendingPathComponent("xdg-data")
        let channel = try OpenCodeTestDatabase(
            at: xdgData.appendingPathComponent("opencode/opencode-nightly.db"))
        try channel.insert(fixture.payload(id: "channel", input: 100), id: "channel")
        let explicit = try OpenCodeTestDatabase(
            at: fixture.root.appendingPathComponent("explicit/custom.db"))
        try explicit.insert(fixture.payload(id: "explicit", input: 200), id: "explicit")
        let environment = [
            "XDG_DATA_HOME": xdgData.path,
            "OPENCODE_DB": explicit.url.path,
        ]
        let cacheRoot = fixture.root.appendingPathComponent("isolated-caches")
        let descriptor = try XCTUnwrap(LocalUsageReaderRegistry.agentDescriptors(
            home: fixture.root,
            environment: environment,
            codexRolloutUsageCache: CodexRolloutUsageCache(
                cacheURL: cacheRoot.appendingPathComponent("codex.json")),
            claudeUsageCache: ClaudeUsageCache(
                cacheURL: cacheRoot.appendingPathComponent("claude.json")),
            hermesUsageLedger: HermesUsageLedger(
                fileURL: cacheRoot.appendingPathComponent("hermes.json")))
            .first { $0.name == "OpenCode" })

        let usage = try await descriptor.reader.readUsage(
            from: OpenCodeFixture.date.addingTimeInterval(-1),
            to: OpenCodeFixture.date.addingTimeInterval(120))

        XCTAssertEqual(usage.inputTokens, 300)
        XCTAssertEqual(usage.tokenEvents.count, 2)
        let selectedFiles = try descriptor.resolvedSourceLocations().compactMap { location -> URL? in
            guard case let .file(url, true, _) = location else { return nil }
            return url
        }
        XCTAssertTrue(selectedFiles.contains(channel.url))
        XCTAssertTrue(selectedFiles.contains(explicit.url))
    }

    func test_directDatabaseOverrideRemainsExclusive() async throws {
        let fixture = try OpenCodeFixture()
        defer { fixture.remove() }
        let selected = try OpenCodeTestDatabase(
            at: fixture.root.appendingPathComponent("selected/custom.db"))
        try selected.insert(fixture.payload(id: "selected", input: 200), id: "selected")
        let unrelated = try OpenCodeTestDatabase(
            at: fixture.root.appendingPathComponent("selected/opencode-nightly.db"))
        try unrelated.insert(fixture.payload(id: "unrelated", input: 100), id: "unrelated")

        let usage = try await OpenCodeReader(dbPathOverride: selected.url.path).readUsage(
            from: OpenCodeFixture.date.addingTimeInterval(-1),
            to: OpenCodeFixture.date.addingTimeInterval(120))

        XCTAssertEqual(usage.inputTokens, 200)
        XCTAssertEqual(usage.tokenEvents.count, 1)
    }
}
