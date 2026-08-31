import Foundation
import XCTest
@testable import TokiAgentCore
@testable import TokiUsageReaders

final class AgentAdditionalSourceSignatureTests: XCTestCase {
    func test_sourceSignatureTracksFactoryDroidAndAmpFileChanges() async throws {
        let fixture = try AgentSnapshotFixture()
        defer { fixture.remove() }
        let builder = AgentSnapshotBuilder(home: fixture.root)
        let initial = try await builder.sourceSignature(
            configuration: fixture.configuration,
            now: fixture.now)

        let droidSettings = fixture.root
            .appendingPathComponent(".factory/sessions/session.settings.json")
        try FileManager.default.createDirectory(
            at: droidSettings.deletingLastPathComponent(),
            withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: droidSettings)
        try FileManager.default.setAttributes(
            [.modificationDate: fixture.now],
            ofItemAtPath: droidSettings.path)
        let afterDroid = try await builder.sourceSignature(
            configuration: fixture.configuration,
            now: fixture.now)

        let ampThread = fixture.root
            .appendingPathComponent(".local/share/amp/threads/T-signature.json")
        try FileManager.default.createDirectory(
            at: ampThread.deletingLastPathComponent(),
            withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: ampThread)
        try FileManager.default.setAttributes(
            [.modificationDate: fixture.now],
            ofItemAtPath: ampThread.path)
        let afterAmp = try await builder.sourceSignature(
            configuration: fixture.configuration,
            now: fixture.now)

        try FileManager.default.removeItem(at: droidSettings)
        let afterDroidRemoval = try await builder.sourceSignature(
            configuration: fixture.configuration,
            now: fixture.now)

        XCTAssertNotEqual(initial, afterDroid)
        XCTAssertNotEqual(afterDroid, afterAmp)
        XCTAssertNotEqual(afterAmp, afterDroidRemoval)
    }

    func test_sourceSignatureTracksCopilotDefaultAndExporterFiles() async throws {
        let fixture = try AgentSnapshotFixture()
        defer { fixture.remove() }
        let exporterFile = fixture.root.appendingPathComponent("export/copilot.jsonl")
        let builder = AgentSnapshotBuilder(
            home: fixture.root,
            environment: ["COPILOT_OTEL_FILE_EXPORTER_PATH": exporterFile.path])
        let initial = try await builder.sourceSignature(
            configuration: fixture.configuration,
            now: fixture.now)

        let defaultFile = fixture.root.appendingPathComponent(".copilot/otel/default.jsonl")
        try FileManager.default.createDirectory(
            at: defaultFile.deletingLastPathComponent(),
            withIntermediateDirectories: true)
        try Data("{}\n".utf8).write(to: defaultFile)
        try FileManager.default.setAttributes(
            [.modificationDate: fixture.now],
            ofItemAtPath: defaultFile.path)
        let afterDefault = try await builder.sourceSignature(
            configuration: fixture.configuration,
            now: fixture.now)

        try FileManager.default.createDirectory(
            at: exporterFile.deletingLastPathComponent(),
            withIntermediateDirectories: true)
        try Data("{}\n".utf8).write(to: exporterFile)
        let afterExporter = try await builder.sourceSignature(
            configuration: fixture.configuration,
            now: fixture.now)

        XCTAssertNotEqual(initial, afterDefault)
        XCTAssertNotEqual(afterDefault, afterExporter)
    }
}

final class AgentAdditionalRegistryTests: XCTestCase {
    func test_agentRegistryContainsEveryLocalTokiReaderAndNoRemoteReader() {
        let names = LocalUsageReaderRegistry.agentDescriptors().map(\.name)

        XCTAssertEqual(
            names,
            [
                "Claude Code",
                "Codex",
                "Hermes",
                "Cursor",
                "Gemini CLI",
                "GJC",
                "Factory Droid",
                "Amp",
                "Senpi",
                "Pi",
                "Oh My Pi",
                "Kimchi",
                "OpenCode",
                "OpenClaw",
                "GitHub Copilot CLI",
                "Kimi CLI",
                "Kimi Code",
                "Qwen CLI",
            ])
        XCTAssertFalse(names.contains("Remote Devices"))
    }
}
