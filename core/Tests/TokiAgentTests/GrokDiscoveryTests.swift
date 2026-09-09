import Foundation
import XCTest
@testable import TokiUsageReaders

final class GrokDiscoveryTests: XCTestCase {
    func test_defaultSessionRootIsDotGrokWhenEnvironmentIsAbsent() {
        let home = URL(fileURLWithPath: "/synthetic/home")
        let paths = LocalUsageReaderPaths(homeDirectory: home, environment: [:])

        XCTAssertEqual(paths.grokSessions.path, "/synthetic/home/.grok/sessions")
        XCTAssertEqual(GrokReader.defaultSessionRoots(home: home, environment: [:]), [paths.grokSessions])
    }

    func test_grokHomeEnvironmentVariableSelectsSessionRoot() throws {
        let fixture = try GrokFixture()
        defer { fixture.remove() }
        let explicitHome = fixture.home.appendingPathComponent("explicit")
        let paths = LocalUsageReaderPaths(
            homeDirectory: fixture.home,
            environment: ["GROK_HOME": explicitHome.path])

        XCTAssertEqual(paths.grokSessions, explicitHome.appendingPathComponent("sessions"))
    }

    func test_relativeGrokHomeIsIgnoredInFavorOfHomeDirectory() throws {
        let fixture = try GrokFixture()
        defer { fixture.remove() }
        let paths = LocalUsageReaderPaths(
            homeDirectory: fixture.home,
            environment: ["GROK_HOME": "relative/path"])

        XCTAssertEqual(paths.grokSessions, fixture.sessionsRoot)
    }

    func test_subagentUsageRecordsAreNotDiscoveredAsSessions() throws {
        let fixture = try GrokFixture()
        defer { fixture.remove() }
        let directory = try fixture.writeSession(turns: [fixture.turn(endedAt: GrokFixture.date)])
        let nested = directory.appendingPathComponent("subagents/nested-session")
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        try FileManager.default.copyItem(
            at: directory.appendingPathComponent("usage.json"),
            to: nested.appendingPathComponent("usage.json"))

        let sessions = try GrokSessionDiscovery.sessions(in: [fixture.sessionsRoot], limits: .default)

        XCTAssertEqual(sessions.count, 1)
        XCTAssertEqual(sessions.first?.sessionID, "session-1")
    }

    func test_symbolicLinkedSessionDirectoriesAreSkipped() throws {
        let fixture = try GrokFixture()
        defer { fixture.remove() }
        let directory = try fixture.writeSession(turns: [fixture.turn(endedAt: GrokFixture.date)])
        try FileManager.default.createSymbolicLink(
            at: directory.deletingLastPathComponent().appendingPathComponent("linked-session"),
            withDestinationURL: directory)

        let sessions = try GrokSessionDiscovery.sessions(in: [fixture.sessionsRoot], limits: .default)

        XCTAssertEqual(sessions.map(\.sessionID), ["session-1"])
    }

    func test_hiddenProjectDirectoriesAreSkipped() throws {
        let fixture = try GrokFixture()
        defer { fixture.remove() }
        try fixture.writeSession(turns: [fixture.turn(endedAt: GrokFixture.date)])
        let hidden = fixture.sessionsRoot.appendingPathComponent(".trash/session-hidden")
        try FileManager.default.createDirectory(at: hidden, withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: hidden.appendingPathComponent("usage.json"))

        let sessions = try GrokSessionDiscovery.sessions(in: [fixture.sessionsRoot], limits: .default)

        XCTAssertEqual(sessions.map(\.sessionID), ["session-1"])
    }

    func test_absentSessionRootReportsNoUsage() async throws {
        let fixture = try GrokFixture()
        defer { fixture.remove() }
        let reader = GrokReader(sessionRootsOverride: [fixture.sessionsRoot])

        let usage = try await reader.readUsage(
            from: GrokFixture.date.addingTimeInterval(-3600),
            to: GrokFixture.date.addingTimeInterval(3600))

        XCTAssertEqual(usage.totalTokens, 0)
        XCTAssertTrue(usage.tokenEvents.isEmpty)
    }

    func test_sessionCountAboveLimitIsRejected() throws {
        let fixture = try GrokFixture()
        defer { fixture.remove() }
        for index in 0..<2 {
            try fixture.writeSession(id: "session-\(index)", turns: [fixture.turn(endedAt: GrokFixture.date)])
        }
        let limits = PiCompatibleReadLimits(
            maximumFileCount: 1,
            maximumFileBytes: PiCompatibleReadLimits.default.maximumFileBytes,
            maximumLineBytes: PiCompatibleReadLimits.default.maximumLineBytes,
            maximumEventCount: PiCompatibleReadLimits.default.maximumEventCount,
            maximumEntryCount: PiCompatibleReadLimits.default.maximumEntryCount)

        XCTAssertThrowsError(try GrokSessionDiscovery.sessions(in: [fixture.sessionsRoot], limits: limits))
    }

    func test_selectedSourceLocationsCoverRootAndSessionFiles() throws {
        let fixture = try GrokFixture()
        defer { fixture.remove() }
        try fixture.writeSession(turns: [fixture.turn(endedAt: GrokFixture.date)])
        let reader = GrokReader(sessionRootsOverride: [fixture.sessionsRoot])

        let locations = try reader.selectedSourceLocations()

        XCTAssertEqual(locations.count, 3)
        XCTAssertEqual(locations.first, .directoryPresence(fixture.sessionsRoot))
        XCTAssertTrue(locations.dropFirst().allSatisfy {
            ["usage.json", "summary.json"].contains($0.url.lastPathComponent)
        })
    }

    func test_registryRegistersGrokReaderAgainstResolvedSessionRoot() throws {
        let fixture = try GrokFixture()
        defer { fixture.remove() }
        try fixture.writeSession(turns: [fixture.turn(endedAt: GrokFixture.date)])

        let descriptor = try XCTUnwrap(LocalUsageReaderRegistry.agentDescriptors(
            home: fixture.home, environment: [:]).first { $0.name == GrokReader.sourceName })

        XCTAssertEqual(descriptor.collectorRevision, 1)
        XCTAssertEqual(descriptor.sourceLocations, [.directoryPresence(fixture.sessionsRoot)])
        XCTAssertEqual(try descriptor.resolvedSourceLocations().count, 3)
    }
}
