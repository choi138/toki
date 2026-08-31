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

    func test_qwenSourceSignatureTracksOldMtimeFiles() async throws {
        let fixture = try AgentSnapshotFixture()
        defer { fixture.remove() }
        let projectsRoot = fixture.root.appendingPathComponent(".qwen/projects")
        try FileManager.default.createDirectory(
            at: projectsRoot,
            withIntermediateDirectories: true)
        let builder = AgentSnapshotBuilder(home: fixture.root)
        let initialSignature = try await builder.sourceSignature(
            configuration: fixture.configuration,
            now: fixture.now)
        let historyFile = projectsRoot.appendingPathComponent(
            "workspace/chats/old-mtime.jsonl")
        try Self.write(
            [
                #"{"type":"assistant","model":"qwen3.5-plus","# +
                    #""timestamp":"\#(ISO8601DateFormatter().string(from: fixture.latestEventDate))","# +
                    #""sessionId":"old-mtime","usageMetadata":{"promptTokenCount":40,"# +
                    #""candidatesTokenCount":9}}"#,
            ],
            to: historyFile)
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSince1970: 978_307_200)],
            ofItemAtPath: historyFile.path)

        let addedSignature = try await builder.sourceSignature(
            configuration: fixture.configuration,
            now: fixture.now)
        try FileManager.default.removeItem(at: historyFile)
        let removedSignature = try await builder.sourceSignature(
            configuration: fixture.configuration,
            now: fixture.now)

        XCTAssertNotEqual(initialSignature, addedSignature)
        XCTAssertEqual(initialSignature, removedSignature)
    }

    func test_kimiSourceSignaturesTrackOldMtimeFiles() async throws {
        let fixture = try AgentSnapshotFixture()
        defer { fixture.remove() }
        let kimiCLIRoot = fixture.root.appendingPathComponent(".kimi/sessions")
        let kimiCodeRoot = fixture.root.appendingPathComponent(".kimi-code/sessions")
        try FileManager.default.createDirectory(at: kimiCLIRoot, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: kimiCodeRoot, withIntermediateDirectories: true)
        let builder = AgentSnapshotBuilder(home: fixture.root)
        let initialSignature = try await builder.sourceSignature(
            configuration: fixture.configuration,
            now: fixture.now)
        let timestamp = fixture.latestEventDate.timeIntervalSince1970
        let cliHistory = kimiCLIRoot.appendingPathComponent("workspace/session-cli/wire.jsonl")
        try Self.write(
            [
                #"{"timestamp":\#(timestamp),"message":{"type":"StatusUpdate","payload":{"# +
                    #""token_usage":{"input_other":20,"output":5},"message_id":"old-cli"}}}"#,
            ],
            to: cliHistory)
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSince1970: 978_307_200)],
            ofItemAtPath: cliHistory.path)

        let cliAddedSignature = try await builder.sourceSignature(
            configuration: fixture.configuration,
            now: fixture.now)
        try FileManager.default.removeItem(at: cliHistory)
        let cliRemovedSignature = try await builder.sourceSignature(
            configuration: fixture.configuration,
            now: fixture.now)

        let codeHistory = kimiCodeRoot.appendingPathComponent(
            "workspace/session-code/agents/main/wire.jsonl")
        try Self.write(
            [
                #"{"type":"usage.record","model":"moonshot/kimi-k2.6","usage":{"inputOther":30,"# +
                    #""output":8},"usageScope":"turn","time":\#(Int64(timestamp * 1000))}"#,
            ],
            to: codeHistory)
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSince1970: 978_307_200)],
            ofItemAtPath: codeHistory.path)

        let codeAddedSignature = try await builder.sourceSignature(
            configuration: fixture.configuration,
            now: fixture.now)
        try FileManager.default.removeItem(at: codeHistory)
        let codeRemovedSignature = try await builder.sourceSignature(
            configuration: fixture.configuration,
            now: fixture.now)

        XCTAssertNotEqual(initialSignature, cliAddedSignature)
        XCTAssertEqual(initialSignature, cliRemovedSignature)
        XCTAssertNotEqual(initialSignature, codeAddedSignature)
        XCTAssertEqual(initialSignature, codeRemovedSignature)
    }

    private static func write(_ lines: [String], to url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true)
        try Data((lines.joined(separator: "\n") + "\n").utf8).write(to: url)
    }
}
