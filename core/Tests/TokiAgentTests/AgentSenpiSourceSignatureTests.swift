import Foundation
import TokiSyncProtocol
import XCTest
@testable import TokiAgentCore

final class AgentSenpiSourceSignatureTests: XCTestCase {
    func test_sourceSignatureTracksSenpiSessionChangesRegardlessOfMtime() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("toki-agent-senpi-signature-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let now = Date(timeIntervalSince1970: 1_789_862_400)
        let hubURL = try XCTUnwrap(URL(string: "https://hub.example.com"))
        let configuration = try AgentConfiguration(bundle: AgentPairingBundle(
            hubURL: hubURL,
            deviceID: "device",
            deviceName: "Device",
            uploadToken: SnapshotCipher.randomToken(),
            encryptionKey: SnapshotCipher.generateKey(),
            retentionDays: 7,
            syncIntervalSeconds: 900))
        let builder = AgentSnapshotBuilder(home: root, environment: [:])
        let sessions = root.appendingPathComponent(".senpi/agent/sessions")
        try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
        let initial = try await builder.sourceSignature(configuration: configuration, now: now)
        let session = sessions.appendingPathComponent("project/session.jsonl")
        try FileManager.default.createDirectory(
            at: session.deletingLastPathComponent(),
            withIntermediateDirectories: true)
        try Data("{}\n".utf8).write(to: session)
        try FileManager.default.setAttributes(
            [.modificationDate: now.addingTimeInterval(-30 * 24 * 60 * 60)],
            ofItemAtPath: session.path)
        let afterCreation = try await builder.sourceSignature(configuration: configuration, now: now)
        try Data("{}\n{}\n".utf8).write(to: session)
        let afterAppend = try await builder.sourceSignature(configuration: configuration, now: now)

        XCTAssertNotEqual(initial, afterCreation)
        XCTAssertNotEqual(afterCreation, afterAppend)
    }
}
