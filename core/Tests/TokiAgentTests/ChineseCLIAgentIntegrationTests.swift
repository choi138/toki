import Foundation
import XCTest
@testable import TokiAgentCore
@testable import TokiUsageReaders

final class ChineseCLIAgentIntegrationTests: XCTestCase {
    func test_agentRegistryExportsKimiAndQwenAndTracksOnlyUsageSourceFiles() async throws {
        let fixture = try AgentSnapshotFixture()
        defer { fixture.remove() }
        let builder = AgentSnapshotBuilder(home: fixture.root)
        let initialSignature = try await builder.sourceSignature(
            configuration: fixture.configuration,
            now: fixture.now)
        let timestamp = fixture.latestEventDate.timeIntervalSince1970

        try Self.write(
            [
                #"{"timestamp":\#(timestamp),"message":{"type":"StatusUpdate","payload":{"# +
                    #""token_usage":{"input_other":20,"output":5},"message_id":"agent-cli"}}}"#,
            ],
            to: fixture.root.appendingPathComponent(
                ".kimi/sessions/workspace/session-cli/wire.jsonl"))
        try Self.write(
            [
                #"{"type":"usage.record","model":"moonshot/kimi-k2.6","usage":{"inputOther":30,"# +
                    #""output":8},"usageScope":"turn","time":\#(Int64(timestamp * 1000))}"#,
            ],
            to: fixture.root.appendingPathComponent(
                ".kimi-code/sessions/workspace/session-code/agents/main/wire.jsonl"))
        try Self.write(
            [
                #"{"type":"assistant","model":"qwen3.5-plus","# +
                    #""timestamp":"\#(ISO8601DateFormatter().string(from: fixture.latestEventDate))","# +
                    #""sessionId":"session-qwen","usageMetadata":{"promptTokenCount":40,"# +
                    #""candidatesTokenCount":9,"thoughtsTokenCount":2}}"#,
            ],
            to: fixture.root.appendingPathComponent(
                ".qwen/projects/workspace/chats/session-qwen.jsonl"))

        let sessionSignature = try await builder.sourceSignature(
            configuration: fixture.configuration,
            now: fixture.now)
        try Self.write(
            [#"default_model = "kimi-for-coding""#],
            to: fixture.root.appendingPathComponent(".kimi/config.toml"))
        let tomlSignature = try await builder.sourceSignature(
            configuration: fixture.configuration,
            now: fixture.now)
        try Self.write(
            [#"{"model":"kimi-for-coding"}"#],
            to: fixture.root.appendingPathComponent(".kimi/config.json"))
        let jsonSignature = try await builder.sourceSignature(
            configuration: fixture.configuration,
            now: fixture.now)
        let snapshot = try await builder.build(
            configuration: fixture.configuration,
            now: fixture.now)

        XCTAssertNotEqual(initialSignature, sessionSignature)
        XCTAssertEqual(sessionSignature, tomlSignature)
        XCTAssertEqual(tomlSignature, jsonSignature)
        XCTAssertTrue(snapshot.tokenEvents.contains {
            $0.source == "Kimi CLI" && $0.model == "kimi-for-coding"
                && $0.provider == "moonshot" && $0.cost == 0 && $0.costIsKnown == false
        })
        XCTAssertTrue(snapshot.tokenEvents.contains {
            $0.source == "Kimi Code" && $0.model == "moonshot/kimi-k2.6"
                && $0.provider == "moonshot" && $0.cost == 0 && $0.costIsKnown == false
        })
        XCTAssertTrue(snapshot.tokenEvents.contains {
            $0.source == "Qwen CLI" && $0.model == "qwen3.5-plus"
                && $0.provider == "qwen" && $0.cost == 0 && $0.costIsKnown == false
        })
    }

    private static func write(_ lines: [String], to url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true)
        try Data((lines.joined(separator: "\n") + "\n").utf8).write(to: url)
    }
}
