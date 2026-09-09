import Foundation
import XCTest
@testable import TokiAgentCore
@testable import TokiUsageReaders

final class GJCSharedRootSignatureTests: XCTestCase {
    func test_sharedPiAliasRetargetInvalidatesGJCSignatureWithUnchangedSourceFiles() async throws {
        let fixture = try HermesM1Fixture()
        defer { fixture.remove() }
        let sessions = fixture.home.appendingPathComponent(".gjc/agent/sessions")
        let unrelated = fixture.root.appendingPathComponent("unrelated")
        try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: unrelated, withIntermediateDirectories: true)
        let timestamp = ISO8601DateFormatter().string(from: fixture.activityAt)
        let content = "{\"type\":\"session\",\"id\":\"synthetic-shared\"}\n"
            + "{\"type\":\"message\",\"id\":\"m1\",\"timestamp\":\"\(timestamp)\",\"message\":"
            + "{\"role\":\"assistant\",\"model\":\"synthetic-model\",\"usage\":{\"input\":8,\"output\":4}}}\n"
        try Data(content.utf8).write(to: sessions.appendingPathComponent("shared.jsonl"))
        let alias = fixture.root.appendingPathComponent("selected-pi")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: unrelated)
        var environment = fixture.environment
        environment["PI_CODING_AGENT_SESSION_DIR"] = alias.path
        let descriptor = try XCTUnwrap(LocalUsageReaderRegistry.agentDescriptors(
            home: fixture.home, environment: environment).first { $0.name == "GJC" })
        let builder = AgentSnapshotBuilder(
            home: fixture.home, environment: environment, readerDescriptors: [descriptor])
        let initialLocations = try descriptor.resolvedSourceLocations().map(\.url)
        var signatures: [String] = []
        for (target, expected) in [(unrelated, 12), (sessions, 0), (unrelated, 12)] {
            try FileManager.default.removeItem(at: alias)
            try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: target)
            let usage = try await descriptor.reader.readUsage(from: fixture.start, to: fixture.end)
            XCTAssertEqual(usage.totalTokens, expected)
            XCTAssertEqual(try descriptor.resolvedSourceLocations().map(\.url), initialLocations)
            let signature = try await builder.sourceSignature(configuration: fixture.configuration(), now: fixture.now)
            try signatures.append(XCTUnwrap(signature))
        }
        XCTAssertNotEqual(signatures[0], signatures[1])
        XCTAssertNotEqual(signatures[1], signatures[2])
        XCTAssertEqual(signatures[0], signatures[2])
    }
}
