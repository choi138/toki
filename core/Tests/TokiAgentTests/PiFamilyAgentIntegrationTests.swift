import Foundation
import TokiSyncProtocol
import XCTest
@testable import TokiAgentCore

final class PiFamilyAgentIntegrationTests: XCTestCase {
    func test_temporaryHomeFlowsFromRegistryThroughSnapshotExport() async throws {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("toki-pi-family-agent-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: home) }
        let eventDate = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-08-20T12:00:00Z"))
        let now = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-08-20T18:00:00Z"))
        try writeSession(
            at: home.appendingPathComponent(".pi/agent/sessions/pi.jsonl"),
            sessionID: "pi-session",
            messageID: "pi-message",
            timestamp: eventDate,
            input: 3,
            output: 2)
        try writeSession(
            at: home.appendingPathComponent(".omp/agent/sessions/project/parent.jsonl"),
            sessionID: "omp-session",
            messageID: "omp-message",
            timestamp: eventDate,
            input: 7,
            output: 4)
        try writeSession(
            at: home.appendingPathComponent(".config/kimchi/harness/sessions/kimchi.jsonl"),
            sessionID: "kimchi-session",
            messageID: "kimchi-message",
            timestamp: eventDate,
            input: 13,
            output: 6)
        let configuration = try AgentConfiguration(bundle: AgentPairingBundle(
            hubURL: XCTUnwrap(URL(string: "https://hub.example.test")),
            deviceID: "pi-family-device",
            deviceName: "fixture",
            uploadToken: SnapshotCipher.randomToken(),
            encryptionKey: SnapshotCipher.generateKey(),
            retentionDays: 2,
            syncIntervalSeconds: 900))

        let snapshot = try await AgentSnapshotBuilder(home: home, environment: [:])
            .build(configuration: configuration, now: now)
        let exported = try TokiSyncCoding.makeEncoder().encode(snapshot)
        let decoded = try TokiSyncCoding.makeDecoder().decode(RemoteUsageSnapshot.self, from: exported)
        let piFamilyEvents = decoded.tokenEvents.filter {
            ["Pi", "Oh My Pi", "Kimchi"].contains($0.source)
        }

        XCTAssertEqual(piFamilyEvents.count, 3)
        XCTAssertEqual(Set(piFamilyEvents.map(\.source)), ["Pi", "Oh My Pi", "Kimchi"])
        XCTAssertEqual(piFamilyEvents.reduce(0) { $0 + $1.totalTokens }, 35)
        let encoded = try XCTUnwrap(String(bytes: exported, encoding: .utf8))
        XCTAssertFalse(encoded.contains(home.path))
    }
}

private extension PiFamilyAgentIntegrationTests {
    func writeSession(
        at url: URL,
        sessionID: String,
        messageID: String,
        timestamp: Date,
        input: Int,
        output: Int) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true)
        let date = ISO8601DateFormatter().string(from: timestamp)
        let lines = [
            #"{"type":"session","id":"\#(sessionID)","cwd":"/tmp/project"}"#,
            """
            {"type":"message","id":"\(messageID)","timestamp":"\(date)","message":\
            {"role":"assistant","model":"gpt-5","provider":"openai",\
            "usage":{"input":\(input),"output":\(output)}}}
            """,
        ]
        try Data(lines.joined(separator: "\n").utf8).write(to: url)
    }
}
