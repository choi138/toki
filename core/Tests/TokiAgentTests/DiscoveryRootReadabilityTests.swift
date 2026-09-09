import Foundation
import XCTest
@testable import TokiAgentCore

/// A `.directoryPresence` location is a change-detection root, not a readable record set.
/// Counting it as readable let an empty client home satisfy `toki-agent doctor`, hiding
/// `localUsageDataUnavailable`. These cases pin the corrected classification for every
/// reader that registers a discovery root, and keep the type check that predates it.
final class DiscoveryRootReadabilityTests: XCTestCase {
    func test_emptyHermesHomeIsNotAReadableSource() throws {
        let fixture = try AgentSyncFixture()
        defer { fixture.remove() }
        try FileManager.default.createDirectory(
            at: fixture.root.appendingPathComponent(".hermes"),
            withIntermediateDirectories: true)

        let diagnostics = TokiAgentCommand.sourceDiagnostics(
            home: fixture.root,
            environment: [:])

        XCTAssertEqual(diagnostics.first(where: { $0.name == "Hermes" })?.status, .notFound)
    }

    func test_doctorRejectsAnEmptyHermesHome() throws {
        let fixture = try AgentSyncFixture()
        defer { fixture.remove() }
        try FileManager.default.createDirectory(
            at: fixture.root.appendingPathComponent(".hermes/profiles"),
            withIntermediateDirectories: true)

        XCTAssertThrowsError(try TokiAgentCommand.doctor(
            paths: fixture.paths,
            home: fixture.root,
            environment: [:])) { error in
                guard let commandError = error as? AgentCommandError,
                      case .localUsageDataUnavailable = commandError else {
                    return XCTFail("Expected localUsageDataUnavailable, got \(error)")
                }
            }
    }

    func test_emptyOpenCodeDataRootIsNotAReadableSource() throws {
        let fixture = try AgentSyncFixture()
        defer { fixture.remove() }
        try FileManager.default.createDirectory(
            at: fixture.root.appendingPathComponent(".local/share/opencode"),
            withIntermediateDirectories: true)

        let diagnostics = TokiAgentCommand.sourceDiagnostics(
            home: fixture.root,
            environment: [:])

        XCTAssertEqual(diagnostics.first(where: { $0.name == "OpenCode" })?.status, .notFound)
    }

    func test_emptyOpenClawAgentsRootIsNotAReadableSource() throws {
        let fixture = try AgentSyncFixture()
        defer { fixture.remove() }
        try FileManager.default.createDirectory(
            at: fixture.root.appendingPathComponent(".openclaw/agents"),
            withIntermediateDirectories: true)

        let diagnostics = TokiAgentCommand.sourceDiagnostics(
            home: fixture.root,
            environment: [:])

        XCTAssertEqual(diagnostics.first(where: { $0.name == "OpenClaw" })?.status, .notFound)
    }

    /// Excluding a discovery root from the readable tally must not drop its type check:
    /// a non-directory at a selected root is still a misconfiguration, not "not found".
    func test_discoveryRootWithWrongTypeStillReportsError() throws {
        let fixture = try AgentSyncFixture()
        defer { fixture.remove() }
        let agentsRoot = fixture.root.appendingPathComponent(".openclaw/agents")
        try FileManager.default.createDirectory(
            at: agentsRoot.deletingLastPathComponent(),
            withIntermediateDirectories: true)
        try Data().write(to: agentsRoot)

        let diagnostics = TokiAgentCommand.sourceDiagnostics(
            home: fixture.root,
            environment: [:])

        XCTAssertEqual(diagnostics.first(where: { $0.name == "OpenClaw" })?.status, .error)
    }

    /// A populated home must remain readable, so the fix cannot regress real coverage.
    func test_populatedHermesHomeRemainsReadable() throws {
        let fixture = try AgentSyncFixture()
        defer { fixture.remove() }
        let databaseURL = fixture.root.appendingPathComponent(".hermes/state.db")
        try FileManager.default.createDirectory(
            at: databaseURL.deletingLastPathComponent(),
            withIntermediateDirectories: true)
        try Data().write(to: databaseURL)

        let diagnostics = TokiAgentCommand.sourceDiagnostics(
            home: fixture.root,
            environment: [:])

        XCTAssertEqual(diagnostics.first(where: { $0.name == "Hermes" })?.status, .readable)
    }
}
