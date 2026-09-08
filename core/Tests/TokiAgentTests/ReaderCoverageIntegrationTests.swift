import Foundation
import TokiSyncProtocol
import TokiUsageCore
import XCTest
@testable import TokiAgentCore
@testable import TokiUsageReaders

/// Synthetic public-registry fixtures. These tests also compile against the frozen lane candidate.
final class ReaderCoverageIntegrationTests: XCTestCase {
    func test_registryOpenCodeIncludesChannelsExplicitDatabaseAndLegacyJSON() async throws {
        let fixture = try OpenCodeFixture()
        defer { fixture.remove() }
        let dataRoot = fixture.root.appendingPathComponent(".local/share/opencode")
        let channel = try OpenCodeTestDatabase(at: dataRoot.appendingPathComponent("opencode-beta.db"))
        try channel.insert(fixture.payload())
        let explicit = try OpenCodeTestDatabase(at: fixture.root.appendingPathComponent("custom/selected.db"))
        try explicit.insert(fixture.payload(input: 200))
        try fixture.writeJSON(
            fixture.payload(id: "legacy", sessionID: "legacy-session", input: 300),
            root: dataRoot, session: "legacy-session", filename: "legacy.json")
        let descriptor = try descriptor("OpenCode", home: fixture.root, environment: ["OPENCODE_DB": explicit.url.path])
        let usage = try await descriptor.reader.readUsage(
            from: OpenCodeFixture.date, to: OpenCodeFixture.date.addingTimeInterval(1))
        XCTAssertEqual(usage.inputTokens, 600)
        XCTAssertEqual(usage.totalTokens, 774)
        XCTAssertEqual(usage.perModel.values.reduce(0) { $0 + $1.totalTokens }, 774)
        XCTAssertEqual(usage.tokenEvents.count, 3)
        XCTAssertTrue(usage.tokenEvents.allSatisfy { $0.costIsKnown == false })
        let snapshot = try await snapshot(descriptor, home: fixture.root, now: OpenCodeFixture.date)
        XCTAssertEqual(snapshot.tokenEvents.reduce(0) { $0 + $1.totalTokens }, 774)
        XCTAssertTrue(snapshot.tokenEvents.allSatisfy { $0.cost == 0 && $0.costIsKnown == false })
        XCTAssertEqual(snapshot.activityEvents.count, usage.activityEvents.count)
        XCTAssertEqual(Set(snapshot.activityEvents.map(\.streamID)).count, 3)
        let outside = try await descriptor.reader.readUsage(
            from: OpenCodeFixture.date.addingTimeInterval(-60), to: OpenCodeFixture.date)
        XCTAssertEqual(outside.totalTokens, 0, "The range end remains exclusive")
        XCTAssertEqual(usage.activeSeconds, usage.perModel.values.reduce(0) { $0 + $1.activeSeconds })
    }

    func test_registryOpenClawUsesEveryInjectedLegacyRootAndPreservesSnapshotModel() async throws {
        let fixture = try OpenClawFixture()
        defer { fixture.remove() }
        let event = OpenClawFixture.event()
        XCTAssertNoThrow(try JSONSerialization.jsonObject(with: Data(event.utf8)))
        for root in [".openclaw", ".clawdbot", ".moltbot", ".moldbot"] {
            let file = fixture.root.appendingPathComponent("\(root)/agents/main/sessions/session.jsonl")
            try FileManager.default.createDirectory(
                at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(event.utf8).write(to: file)
        }
        let descriptor = try descriptor("OpenClaw", home: fixture.root)
        let usage = try await descriptor.reader.readUsage(from: OpenClawFixture.start, to: OpenClawFixture.end)
        XCTAssertEqual(usage.totalTokens, 1440)
        XCTAssertEqual(usage.perModel["claude-opus-4-6"]?.totalTokens, 1440)
        XCTAssertEqual(usage.cost, 0.0144, accuracy: 0.000001)
        let snapshot = try await snapshot(
            descriptor, home: fixture.root, now: OpenClawFixture.end.addingTimeInterval(-1))
        XCTAssertEqual(snapshot.tokenEvents.reduce(0) { $0 + $1.totalTokens }, usage.totalTokens)
        XCTAssertEqual(Set(snapshot.activityEvents.map(\.streamID)).count, 4)
        XCTAssertTrue(snapshot.tokenEvents.allSatisfy { $0.model == "claude-opus-4-6" && $0.costIsKnown == true })
        let work = ActivityTimeEstimator.estimate(events: snapshot.activityEvents.map {
            ActivityTimeEvent(streamID: $0.streamID, timestamp: $0.timestamp, key: $0.model)
        })
        XCTAssertEqual(work.totalSeconds, usage.workTime.agentSeconds)
        XCTAssertEqual(work.wallClockSeconds, usage.workTime.wallClockSeconds)
    }

    func test_registrySharedPIConfigHasOneDeterministicOwner() async throws {
        let fixture = try OpenCodeFixture()
        defer { fixture.remove() }
        let root = fixture.root.appendingPathComponent("shared")
        let file = root.appendingPathComponent("agent/sessions/session.jsonl")
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        let line = [
            #"{"type":"message","id":"m1","timestamp":"2026-08-20T12:00:00Z","message":{"role":"assistant","#,
            #""model":"fixture-unpriced","usage":{"input":100,"output":20}}}"#,
        ].joined()
        XCTAssertNoThrow(try JSONSerialization.jsonObject(with: Data(line.utf8)))
        let header = #"{"type":"session","id":"fixture-session"}"#
        XCTAssertNoThrow(try JSONSerialization.jsonObject(with: Data(header.utf8)))
        try Data((header + "\n" + line + "\n").utf8).write(to: file)
        let readers = LocalUsageReaderRegistry.readers(home: fixture.root, environment: ["PI_CONFIG_DIR": root.path])
            .filter { [OMPReader.sourceName, GJCReader.sourceName].contains($0.name) }
        var totals: [String: Int] = [:]
        for reader in readers {
            totals[reader.name] = try await reader.readUsage(
                from: OpenCodeFixture.date, to: OpenCodeFixture.date.addingTimeInterval(60)).totalTokens
        }
        XCTAssertEqual(totals[OMPReader.sourceName], 120)
        XCTAssertEqual(totals["GJC"], 0)
        XCTAssertEqual(totals.values.reduce(0, +), 120)
    }

    func test_cliCoverageReportsPartialProfileCount() throws {
        let fixture = try HermesM1Fixture()
        defer { fixture.remove() }
        let lines = try TokiAgentCommand.statusLines(
            configuration: fixture.configuration(), state: AgentRuntimeState(), pendingCount: 0,
            hermesCoverage: HermesUsageCoverageStatus(unmeteredMainAPICallCount: 7, profileReadErrorCount: 2))
        XCTAssertTrue(lines.contains("Hermes unmetered main calls: 7"))
        XCTAssertTrue(lines.contains("Hermes profile read errors: 2"))
    }

    private func descriptor(_ name: String, home: URL, environment: [String: String] = [:]) throws
        -> LocalUsageReaderDescriptor {
        try XCTUnwrap(LocalUsageReaderRegistry.agentDescriptors(home: home, environment: environment)
            .first { $0.name == name })
    }

    private func snapshot(_ descriptor: LocalUsageReaderDescriptor, home: URL, now: Date) async throws
        -> RemoteUsageSnapshot {
        let fixture = try HermesM1Fixture()
        defer { fixture.remove() }
        let result = try await AgentSnapshotBuilder(home: home, environment: [:], readerDescriptors: [descriptor])
            .build(configuration: fixture.configuration(), now: now)
        let decoded = try TokiSyncCoding.makeDecoder().decode(
            RemoteUsageSnapshot.self, from: TokiSyncCoding.makeEncoder().encode(result))
        XCTAssertEqual(decoded, result)
        XCTAssertNoThrow(try RemoteUsageSnapshotValidator.validate(decoded, now: now))
        return result
    }
}
