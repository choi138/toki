import Foundation
import TokiSyncProtocol
import XCTest
@testable import TokiAgentCore
@testable import TokiUsageReaders

final class CodexHomeSourceSignatureTests: XCTestCase {
    func test_overrideSessionInvalidatesSignatureWithoutReadingDefaultHome() async throws {
        let fixture = try AgentSyncFixture()
        defer { fixture.remove() }
        let now = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-09-08T12:00:00Z"))
        let builder = try builder(fixture)
        let before = try await builder.sourceSignature(configuration: fixture.configuration, now: now)
        XCTAssertNotNil(before)
        try writeRollout(root: fixture.root.appendingPathComponent(".codex"), input: 900)
        let unselected = try await builder.sourceSignature(configuration: fixture.configuration, now: now)
        XCTAssertEqual(before, unselected, "An unselected default home must not affect the override signature")
        try writeRollout(root: fixture.root.appendingPathComponent("selected-codex"), input: 100)
        let selected = try await builder.sourceSignature(configuration: fixture.configuration, now: now)
        XCTAssertNotEqual(unselected, selected)
        try writeRollout(root: fixture.root.appendingPathComponent("selected-codex"), input: 200)
        let updated = try await builder.sourceSignature(configuration: fixture.configuration, now: now)
        XCTAssertNotEqual(selected, updated)
        let snapshot = try await builder.build(configuration: fixture.configuration, now: now)
        XCTAssertEqual(snapshot.tokenEvents.reduce(0) { $0 + $1.totalTokens }, 225)
    }

    func test_overrideSessionUpdateLeavesHeartbeatFastPathAndUploadsNewUsage() async throws {
        let fixture = try AgentSyncFixture()
        defer { fixture.remove() }
        let now = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-09-08T12:00:00Z"))
        let builder = try builder(fixture)
        try AgentConfigurationStore(paths: fixture.paths).save(fixture.configuration)
        let hub = CodexSignatureRecordingHubClient()
        let service = AgentSyncService(paths: fixture.paths, hubClient: hub, snapshotBuilder: builder)
        try await service.syncOnce(now: now)
        try await service.syncOnce(now: now)
        try await service.syncOnce(now: now)
        XCTAssertEqual(hub.uploadedSequences, [1])
        XCTAssertEqual(hub.heartbeatSequences, [1, 1])

        try writeRollout(root: fixture.root.appendingPathComponent("selected-codex"), input: 100)
        try await service.syncOnce(now: now)
        XCTAssertEqual(hub.uploadedSequences, [1, 2])
        XCTAssertEqual(try AgentStateStore(paths: fixture.paths).load().latestSequence, 2)
        let snapshot = try await builder.build(configuration: fixture.configuration, now: now)
        XCTAssertEqual(snapshot.tokenEvents.reduce(0) { $0 + $1.totalTokens }, 125)
        let decoded = try TokiSyncCoding.makeDecoder().decode(
            RemoteUsageSnapshot.self, from: TokiSyncCoding.makeEncoder().encode(snapshot))
        XCTAssertEqual(decoded, snapshot)
        XCTAssertNoThrow(try RemoteUsageSnapshotValidator.validate(decoded, now: now))
    }

    private func builder(_ fixture: AgentSyncFixture) throws -> AgentSnapshotBuilder {
        let environment = [
            "CODEX_HOME": fixture.root.appendingPathComponent("selected-codex").path,
            "XDG_CONFIG_HOME": fixture.root.appendingPathComponent("config").path,
            "XDG_DATA_HOME": fixture.root.appendingPathComponent("data").path,
            "XDG_STATE_HOME": fixture.root.appendingPathComponent("state").path,
        ]
        let descriptor = try XCTUnwrap(LocalUsageReaderRegistry.agentDescriptors(
            home: fixture.root, environment: environment).first { $0.name == "Codex" })
        return AgentSnapshotBuilder(home: fixture.root, environment: environment, readerDescriptors: [descriptor])
    }

    private func writeRollout(root: URL, input: Int) throws {
        let file = root.appendingPathComponent("sessions/2026/09/08/review.jsonl")
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        let lines = [
            #"{"timestamp":"2026-09-08T00:01:00Z","type":"session_meta","payload":{"#
                + #""id":"review-session","source":"cli"}}"#,
            #"{"timestamp":"2026-09-08T00:01:00Z","type":"turn_context","payload":{"model":"gpt-5"}}"#,
            #"{"timestamp":"2026-09-08T00:01:01Z","type":"event_msg","payload":{"#
                + #""type":"token_count","info":{"total_token_usage":{"input_tokens":\#(input),"#
                + #""cached_input_tokens":0,"output_tokens":25,"reasoning_output_tokens":0,"#
                + #""total_tokens":\#(input + 25)}}}}"#,
        ]
        try Data((lines.joined(separator: "\n") + "\n").utf8).write(to: file)
    }
}

private final class CodexSignatureRecordingHubClient: AgentHubClientProtocol {
    private let lock = NSLock()
    private var uploads: [UInt64] = []
    private var heartbeats: [UInt64] = []

    var uploadedSequences: [UInt64] {
        lock.withLock { uploads }
    }

    var heartbeatSequences: [UInt64] {
        lock.withLock { heartbeats }
    }

    func upload(_ envelope: EncryptedUsageEnvelope, configuration _: AgentConfiguration) async throws {
        lock.withLock { uploads.append(envelope.sequence) }
    }

    func heartbeat(configuration _: AgentConfiguration, latestSequence: UInt64) async throws {
        lock.withLock { heartbeats.append(latestSequence) }
    }
}
