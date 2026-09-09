import Foundation
import XCTest
@testable import TokiAgentCore
@testable import TokiUsageReaders

#if os(Linux)
    import Glibc
#else
    import Darwin
#endif

final class HermesStatusCoverageIntegrationTests: XCTestCase {
    func test_realStatusIncludesSelectedCollectionRetainedHistoryAndReadErrors() async throws {
        let fixture = try HermesM1Fixture()
        defer { fixture.remove() }
        let paths = AgentPaths(environment: fixture.environment, home: fixture.home)
        try AgentConfigurationStore(paths: paths).save(fixture.configuration())
        try fixture.createDatabase(at: fixture.database())
        let named = fixture.database("synthetic-named")
        try fixture.createDatabase(at: named)
        try await fixture.seedLedger(at: fixture.ledgerURL(scope: .agent))
        let retainedLedger = fixture.ledgerURL(for: named, scope: .agent)
        try await fixture.seedLedger(at: retainedLedger)
        _ = try await fixture.agentDescriptor().reader.readUsage(from: fixture.start, to: fixture.end)
        try FileManager.default.removeItem(at: named.deletingLastPathComponent())
        let broken = fixture.database("synthetic-broken")
        try FileManager.default.createDirectory(
            at: broken.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("invalid-synthetic-sqlite".utf8).write(to: broken)
        let output = try await captureStatus(paths: paths, fixture: fixture, environment: fixture.environment)
        XCTAssertTrue(output.contains("Hermes profile read errors: 1"))
        XCTAssertTrue(output.contains("Hermes collection history: 3 profiles, 2 initialized, 0 read errors"))
        XCTAssertTrue(output.contains("Hermes legacy default ledger (only):"))
        XCTAssertTrue(output.contains("Hermes accurate since:"))
        XCTAssertTrue(output.contains("Hermes profile default accurate since:"))
        for value in [fixture.root.path, "synthetic-named", "synthetic-broken", retainedLedger.lastPathComponent] {
            XCTAssertFalse(output.contains(value))
        }

        try Data("invalid-synthetic-ledger".utf8).write(to: retainedLedger)
        let corrupted = try await captureStatus(paths: paths, fixture: fixture, environment: fixture.environment)
        XCTAssertTrue(corrupted.contains("3 profiles, 1 initialized, 1 read errors"))
        XCTAssertTrue(corrupted.contains("history: unreadable"))
    }

    func test_explicitHermesHomeDoesNotClaimLegacyDefaultHistory() async throws {
        let fixture = try HermesM1Fixture()
        defer { fixture.remove() }
        let paths = AgentPaths(environment: fixture.environment, home: fixture.home)
        try AgentConfigurationStore(paths: paths).save(fixture.configuration())
        try await fixture.seedLedger(at: fixture.ledgerURL(scope: .agent))
        let selected = fixture.root.appendingPathComponent("selected")
        try fixture.createDatabase(at: selected.appendingPathComponent("state.db"))
        var environment = fixture.environment
        environment["HERMES_HOME"] = selected.path
        let output = try await captureStatus(paths: paths, fixture: fixture, environment: environment)
        XCTAssertTrue(output.contains("Hermes collection history: 1 profiles, 0 initialized, 0 read errors"))
        XCTAssertFalse(output.contains("Hermes accurate since:"))
        XCTAssertFalse(output.contains("Hermes profile default"))
        XCTAssertFalse(output.contains(selected.path))
    }

    func test_explicitDefaultAndAliasClaimOnlyLegacyDefaultHistory() async throws {
        let fixture = try HermesM1Fixture()
        defer { fixture.remove() }
        let paths = AgentPaths(environment: fixture.environment, home: fixture.home)
        try AgentConfigurationStore(paths: paths).save(fixture.configuration())
        try fixture.createDatabase(at: fixture.database())
        try await fixture.seedLedger(at: fixture.ledgerURL(scope: .agent))
        let named = fixture.database("named")
        try fixture.createDatabase(at: named)
        try await fixture.seedLedger(at: fixture.ledgerURL(for: named, scope: .agent))
        _ = try await fixture.agentDescriptor().reader.readUsage(from: fixture.start, to: fixture.end)
        let alias = fixture.root.appendingPathComponent("default-alias")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: fixture.hermesHome)

        for selectedHome in [fixture.hermesHome, alias] {
            var environment = fixture.environment
            environment["HERMES_HOME"] = selectedHome.path
            let output = try await captureStatus(paths: paths, fixture: fixture, environment: environment)
            XCTAssertTrue(output.contains("Hermes collection history: 1 profiles, 1 initialized, 0 read errors"))
            XCTAssertTrue(output.contains("Hermes legacy default ledger (only):"))
            XCTAssertTrue(output.contains("Hermes accurate since:"))
            XCTAssertTrue(output.contains("Hermes profile default accurate since:"))
            XCTAssertFalse(output.contains("Hermes profile 2"))
        }

        let unrelated = fixture.root.appendingPathComponent("unrelated")
        try fixture.createDatabase(at: unrelated.appendingPathComponent("state.db"))
        try FileManager.default.removeItem(at: alias)
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: unrelated)
        var environment = fixture.environment
        environment["HERMES_HOME"] = alias.path
        let output = try await captureStatus(paths: paths, fixture: fixture, environment: environment)
        XCTAssertTrue(output.contains("Hermes collection history: 1 profiles, 0 initialized, 0 read errors"))
        XCTAssertFalse(output.contains("Hermes accurate since:"))
        XCTAssertFalse(output.contains("Hermes profile default"))
    }

    /// Exercises the existing public command entry rather than a producer-only history mock.
    /// Parent runs this XCTest suite serially because stdout is process-wide.
    private func captureStatus(
        paths: AgentPaths,
        fixture: HermesM1Fixture,
        environment: [String: String]) async throws -> String {
        let outputURL = fixture.root.appendingPathComponent("status-output")
        try Data().write(to: outputURL)
        let handle = try FileHandle(forWritingTo: outputURL)
        defer { try? handle.close() }
        let saved = dup(STDOUT_FILENO)
        guard saved >= 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
        defer {
            _ = dup2(saved, STDOUT_FILENO)
            _ = close(saved)
        }
        guard dup2(handle.fileDescriptor, STDOUT_FILENO) >= 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
        try await TokiAgentCommand.status(paths: paths, home: fixture.home, environment: environment)
        return try String(contentsOf: outputURL, encoding: .utf8)
    }
}
