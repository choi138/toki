import Foundation
import TokiSyncProtocol
import XCTest
@testable import TokiAgentCore
@testable import TokiUsageReaders

final class PiCompatibleSourceSignatureTests: XCTestCase {
    func test_sourceSignatureTracksPiCompatibleFileAddModifyDelete() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("toki-pi-signature-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let now = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-08-29T12:00:00Z"))
        let builder = AgentSnapshotBuilder(home: root, environment: [:])
        let configuration = try AgentConfiguration(bundle: AgentPairingBundle(
            hubURL: XCTUnwrap(URL(string: "https://hub.example.test")),
            deviceID: "pi-signature-device",
            deviceName: "pi-signature-device",
            uploadToken: SnapshotCipher.randomToken(),
            encryptionKey: SnapshotCipher.generateKey(),
            retentionDays: 7,
            syncIntervalSeconds: 900))
        let session = root.appendingPathComponent(".omp/agent/sessions/project/session.jsonl")

        let missing = try await builder.sourceSignature(configuration: configuration, now: now)
        try FileManager.default.createDirectory(
            at: session.deletingLastPathComponent(),
            withIntermediateDirectories: true)
        try Data("{\"type\":\"session\",\"id\":\"one\"}\n".utf8).write(to: session)
        try FileManager.default.setAttributes([.modificationDate: now], ofItemAtPath: session.path)
        let added = try await builder.sourceSignature(configuration: configuration, now: now)
        try Data("{\"type\":\"session\",\"id\":\"two\"}\n".utf8).write(to: session)
        try FileManager.default.setAttributes(
            [.modificationDate: now.addingTimeInterval(1)],
            ofItemAtPath: session.path)
        let modified = try await builder.sourceSignature(configuration: configuration, now: now)
        try FileManager.default.removeItem(at: session)
        let deleted = try await builder.sourceSignature(configuration: configuration, now: now)

        XCTAssertNotEqual(missing, added)
        XCTAssertNotEqual(added, modified)
        XCTAssertNotEqual(modified, deleted)
    }

    func test_senpiOverrideDoesNotRedirectPiOrOMP() {
        let paths = LocalUsageReaderPaths(
            homeDirectory: URL(fileURLWithPath: "/tmp/toki-home"),
            environment: [
                "SENPI_CODING_AGENT_SESSION_DIR": "/tmp/senpi-override",
                "PI_CODING_AGENT_DIR": "/tmp/shared-legacy-agent",
            ])

        XCTAssertEqual(paths.senpiSessions.map(\.path), ["/tmp/senpi-override"])
        XCTAssertEqual(paths.piSessions.path, "/tmp/toki-home/.pi/agent/sessions")
        XCTAssertEqual(paths.ompSessions.path, "/tmp/toki-home/.omp/agent/sessions")
    }

    func test_defaultRegistryExportsFourDistinctPiCompatibleSources() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("toki-pi-export-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let locations = [
            ".omo/agent/sessions/project/senpi.jsonl",
            ".pi/agent/sessions/project/pi.jsonl",
            ".omp/agent/sessions/project/omp.jsonl",
            ".config/kimchi/harness/sessions/project/kimchi.jsonl",
        ]
        for location in locations {
            let file = root.appendingPathComponent(location)
            try FileManager.default.createDirectory(
                at: file.deletingLastPathComponent(),
                withIntermediateDirectories: true)
            try Data(Self.session.utf8).write(to: file)
        }
        let now = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-08-29T12:00:00Z"))
        let configuration = try AgentConfiguration(bundle: AgentPairingBundle(
            hubURL: XCTUnwrap(URL(string: "https://hub.example.test")),
            deviceID: "pi-export-device",
            deviceName: "pi-export-device",
            uploadToken: SnapshotCipher.randomToken(),
            encryptionKey: SnapshotCipher.generateKey(),
            retentionDays: 7,
            syncIntervalSeconds: 900))

        let snapshot = try await AgentSnapshotBuilder(home: root, environment: [:])
            .build(configuration: configuration, now: now)

        XCTAssertEqual(
            Set(snapshot.tokenEvents.map(\.source)),
            ["Senpi", "Pi", "Oh My Pi", "Kimchi"])
        XCTAssertEqual(snapshot.tokenEvents.map(\.provider), ["openai", "openai", "openai", "openai"])
        XCTAssertEqual(snapshot.tokenEvents.map(\.totalTokens), [18, 18, 18, 18])
        XCTAssertEqual(Set(snapshot.activityEvents.map(\.source)), ["Senpi", "Pi", "Oh My Pi", "Kimchi"])
    }

    private static let session = [
        #"{"type":"session","id":"export-session","timestamp":"2026-08-28T11:59:00Z","cwd":"/tmp/export"}"#,
        [
            #"{"type":"message","id":"export-message","timestamp":"2026-08-28T12:00:00Z","message":"#,
            #"{"role":"assistant","model":"gpt-5","usage":"#,
            #"{"input":10,"output":5,"cacheRead":2,"cacheWrite":1}}}"#,
        ].joined(),
    ].joined(separator: "\n")
}
