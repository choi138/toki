import Foundation
import TokiUsageCore
import XCTest
@testable import TokiUsageReaders

final class OpenClawDiscoveryTests: XCTestCase {
    func test_defaultAndAllLegacyRootsAreBoundedAndExplicitOverrideStaysIsolated() async throws {
        let fixture = try OpenClawFixture()
        defer { fixture.remove() }
        let roots = OpenClawReader.defaultAgentsRoots(home: fixture.root)
        XCTAssertEqual(roots.map { $0.deletingLastPathComponent().lastPathComponent }, [
            ".openclaw", ".clawdbot", ".moltbot", ".moldbot",
        ])
        for root in roots {
            let file = root.appendingPathComponent("main/sessions/session.jsonl")
            try FileManager.default.createDirectory(
                at: file.deletingLastPathComponent(),
                withIntermediateDirectories: true)
            try Data(OpenClawFixture.event().utf8).write(to: file)
        }
        let all = try await OpenClawReader(agentsRoots: roots)
            .readUsage(from: OpenClawFixture.start, to: OpenClawFixture.end)
        let isolated = try await fixture.read()
        XCTAssertEqual(all.totalTokens, 1440)
        XCTAssertEqual(Set(all.activityEvents.map(\.streamID)).count, 4)
        XCTAssertEqual(isolated.totalTokens, 360)
    }

    func test_archivedDoctorQuarantineAndImportCopiesAreRead() async throws {
        let fixture = try OpenClawFixture()
        defer { fixture.remove() }
        for (index, file) in [
            "session.jsonl.deleted.123",
            "session.jsonl.reset.123",
            "session.jsonl.pre-doctor-openai-repair-123.bak",
            "session.jsonl.broken-empty-input-123",
            "session-sqlite-import-archive/archive-tier.history.jsonl",
        ].enumerated() {
            try fixture.jsonl([OpenClawFixture.event(id: "event\(index)")], filename: file)
        }
        let usage = try await fixture.read()
        XCTAssertEqual(usage.totalTokens, 1800)
        XCTAssertEqual(usage.tokenEvents.count, 5)
    }

    func test_bindingSidecarsAndOnlyCanonicalCheckpointsAreExcluded() async throws {
        let fixture = try OpenClawFixture()
        defer { fixture.remove() }
        let uuid = "01234567-89ab-4cde-8fab-0123456789ab"
        for file in [
            "session.jsonl.codex-app-server.json",
            "session.jsonl.codex-app-server.json.migrated",
            "session.checkpoint.\(uuid).jsonl",
            "session.checkpoint.\(uuid).jsonl.deleted.123.zst",
        ] {
            try fixture.jsonl([OpenClawFixture.event()], filename: file)
        }
        try fixture.jsonl([OpenClawFixture.event(id: "real")], filename: "checkpoint-not-a-uuid.jsonl")
        let usage = try await fixture.read()
        XCTAssertEqual(usage.totalTokens, 360)
    }

    func test_onlyExactDatabaseAtAgentDepthIsOpenedAndCodexHomeIsExcluded() async throws {
        let fixture = try OpenClawFixture()
        defer { fixture.remove() }
        for path in [
            "main/agent/incognito-openclaw-agent.sqlite",
            "main/agent/other.sqlite",
            "main/sessions/openclaw-agent.sqlite",
            "main/agent/openclaw-agent.sqlite-wal",
            "main/agent/codex-home/history.jsonl",
            "main/agent/codex-home/sessions/session.jsonl",
        ] {
            let file = fixture.agents.appendingPathComponent(path)
            try FileManager.default.createDirectory(
                at: file.deletingLastPathComponent(),
                withIntermediateDirectories: true)
            try Data("not a usage source".utf8).write(to: file)
        }
        let usage = try await fixture.read()
        XCTAssertEqual(usage.totalTokens, 0)
    }

    func test_childSymlinksDoNotEscapeExplicitRoot() async throws {
        let fixture = try OpenClawFixture()
        defer { fixture.remove() }
        let other = fixture.root.appendingPathComponent("outside-agents")
        try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
        try Data(OpenClawFixture.event().utf8).write(to: other.appendingPathComponent("session.jsonl"))
        try FileManager.default.createSymbolicLink(
            at: fixture.agents.appendingPathComponent("linked-agent"), withDestinationURL: other)
        let usage = try await fixture.read()
        XCTAssertEqual(usage.totalTokens, 0)
    }

    func test_compressedArchiveAndWhollyUnknownJSONLExposeErrors() async throws {
        for filename in ["session.jsonl.zst", "session.jsonl"] {
            let fixture = try OpenClawFixture()
            defer { fixture.remove() }
            try fixture.jsonl(["{\"future_schema\":true}"], filename: filename)
            do {
                _ = try await fixture.read()
                XCTFail("Unsupported data must not be successful empty usage")
            } catch {
                XCTAssertEqual(
                    error as? OpenClawReadError,
                    filename.hasSuffix(".zst") ? .unsupportedArchive : .unrecognizedTranscript)
            }
        }
    }

    func test_missingAndEmptyRootsReturnEmptyUsage() async throws {
        let fixture = try OpenClawFixture()
        defer { fixture.remove() }
        let reader = OpenClawReader(agentsRoots: [fixture.agents, fixture.root.appendingPathComponent("missing")])
        let usage = try await reader.readUsage(from: OpenClawFixture.start, to: OpenClawFixture.end)
        XCTAssertEqual(usage.totalTokens, 0)
        XCTAssertTrue(usage.perModel.isEmpty)
        XCTAssertTrue(usage.activityEvents.isEmpty)
    }
}
