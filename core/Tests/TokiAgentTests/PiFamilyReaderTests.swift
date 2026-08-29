import Foundation
import XCTest
@testable import TokiUsageReaders

final class PiFamilyReaderTests: XCTestCase {
    func test_fourSourcesPreserveWireTotalsWithDistinctLabels() {
        let lines = [
            #"{"type":"session","id":"shared-session","cwd":"/tmp/project"}"#,
            piFamilyMessage(
                id: "shared-message",
                input: 11,
                output: 7,
                cacheRead: 5,
                cacheWrite: 3,
                reasoning: 2),
        ]

        let usages = [
            SenpiReader.usage(
                fromJSONLLines: lines,
                streamID: "senpi",
                from: piFamilyDate("2026-08-20T00:00:00Z"),
                to: piFamilyDate("2026-08-21T00:00:00Z")),
            PiReader.usage(
                fromJSONLLines: lines,
                streamID: "pi",
                from: piFamilyDate("2026-08-20T00:00:00Z"),
                to: piFamilyDate("2026-08-21T00:00:00Z")),
            OMPReader.usage(
                fromJSONLLines: lines,
                streamID: "omp",
                from: piFamilyDate("2026-08-20T00:00:00Z"),
                to: piFamilyDate("2026-08-21T00:00:00Z")),
            KimchiReader.usage(
                fromJSONLLines: lines,
                streamID: "kimchi",
                from: piFamilyDate("2026-08-20T00:00:00Z"),
                to: piFamilyDate("2026-08-21T00:00:00Z")),
        ]

        XCTAssertEqual(usages.map(\.totalTokens), [26, 26, 26, 26])
        XCTAssertEqual(
            usages.compactMap { $0.tokenEvents.first?.source },
            ["Senpi", "Pi", "Oh My Pi", "Kimchi"])
        XCTAssertEqual(usages.map(\.reasoningTokens), [2, 0, 0, 0])
        XCTAssertEqual(usages.map(\.outputTokens), [5, 7, 7, 7])
    }

    func test_piOfficialSessionOverridePrecedesAgentOverride() {
        let home = URL(fileURLWithPath: "/tmp/toki-home")
        let direct = LocalUsageReaderPaths(
            homeDirectory: home,
            environment: [
                "PI_CODING_AGENT_DIR": "/tmp/pi-agent",
                "PI_CODING_AGENT_SESSION_DIR": "/tmp/pi-sessions",
            ])
        let agent = LocalUsageReaderPaths(
            homeDirectory: home,
            environment: ["PI_CODING_AGENT_DIR": "/tmp/pi-agent"])
        let defaults = LocalUsageReaderPaths(
            homeDirectory: home,
            environment: [
                "PI_CODING_AGENT_DIR": "relative-agent",
                "PI_CODING_AGENT_SESSION_DIR": "relative-sessions",
            ])

        XCTAssertEqual(direct.piSessions.path, "/tmp/pi-sessions")
        XCTAssertEqual(agent.piSessions.path, "/tmp/pi-agent/sessions")
        XCTAssertEqual(defaults.piSessions.path, "/tmp/toki-home/.pi/agent/sessions")
        XCTAssertEqual(defaults.ompSessions.path, "/tmp/toki-home/.omp/agent/sessions")
        XCTAssertEqual(
            defaults.kimchiSessions.path,
            "/tmp/toki-home/.config/kimchi/harness/sessions")
    }

    func test_piReaderIncludesInRangeRecordFromOldMtimeFile() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("toki-pi-old-mtime-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let session = root.appendingPathComponent("session.jsonl")
        try writePiFamilySession(
            to: session,
            sessionID: "restored-session",
            messageID: "restored-message",
            input: 9,
            output: 4)
        try FileManager.default.setAttributes(
            [.modificationDate: piFamilyDate("2026-08-01T00:00:00Z")],
            ofItemAtPath: session.path)

        let usage = try await PiReader(sessionsURLOverride: root).readUsage(
            from: piFamilyDate("2026-08-20T00:00:00Z"),
            to: piFamilyDate("2026-08-21T00:00:00Z"))

        XCTAssertEqual(usage.totalTokens, 13)
        XCTAssertEqual(usage.tokenEvents.count, 1)
    }

    func test_piRejectsEmptyGeneratedSubagentSuffix() {
        let usage = PiReader.usage(
            fromJSONLLines: [
                #"{"type":"session","id":"pi-session","cwd":"/tmp/project"}"#,
                #"{"type":"session_info","name":"subagent-reviewer-deadbeef-"}"#,
                """
                {"type":"message","id":"message-1","timestamp":"2026-08-20T12:00:00Z","message":\
                {"role":"assistant","model":"gpt-5.6-sol","provider":"openai",\
                "usage":{"input":3,"output":2}}}
                """,
            ],
            streamID: "/tmp/pi-session.jsonl",
            from: piFamilyDate("2026-08-20T00:00:00Z"),
            to: piFamilyDate("2026-08-21T00:00:00Z"))

        XCTAssertEqual(usage.activityEvents.first?.agentKind, .main)
    }

    func test_ompAcceptsLeadingTitlesAndRejectsUnknownPreHeaderRecords() {
        let message = piFamilyMessage(id: "omp-message", input: 4, output: 2)
        let titled = OMPReader.usage(
            fromJSONLLines: [
                #"{"type":"title","title":"first"}"#,
                #"{"type":"title","title":"second"}"#,
                #"{"type":"session","id":"omp-session"}"#,
                message,
            ],
            streamID: "omp-titled",
            from: piFamilyDate("2026-08-20T00:00:00Z"),
            to: piFamilyDate("2026-08-21T00:00:00Z"))
        let rejected = OMPReader.usage(
            fromJSONLLines: [
                #"{"type":"foreign","value":1}"#,
                #"{"type":"session","id":"omp-rejected"}"#,
                message,
            ],
            streamID: "omp-rejected",
            from: piFamilyDate("2026-08-20T00:00:00Z"),
            to: piFamilyDate("2026-08-21T00:00:00Z"))

        XCTAssertEqual(titled.totalTokens, 6)
        XCTAssertFalse(titled.tokenEvents.isEmpty)
        XCTAssertFalse(rejected.hasReportableData)
    }

    func test_ompRecursesAndDeduplicatesCopiedParentChildUsage() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("toki-omp-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let parent = root.appendingPathComponent("project/parent.jsonl")
        let child = root.appendingPathComponent("project/parent/Child.jsonl")
        let advisor = root.appendingPathComponent("project/parent/__advisor.review.jsonl")
        try writePiFamilySession(to: parent, sessionID: "parent", messageID: "copied", input: 3, output: 2)
        try writePiFamilySession(to: child, sessionID: "child", messageID: "copied", input: 3, output: 2)
        try writePiFamilySession(to: advisor, sessionID: "advisor", messageID: "advisor", input: 5, output: 4)

        let usage = try await OMPReader(sessionsURLOverride: root)
            .readUsage(
                from: piFamilyDate("2026-08-20T00:00:00Z"),
                to: piFamilyDate("2026-08-21T00:00:00Z"))

        XCTAssertEqual(usage.inputTokens, 8)
        XCTAssertEqual(usage.outputTokens, 6)
        XCTAssertEqual(usage.tokenEvents.count, 2)
    }

    func test_kimchiPreservesRecordedProviderAndModel() {
        let usage = KimchiReader.usage(
            fromJSONLLines: [
                #"{"type":"session","id":"kimchi-session","cwd":"/tmp/kimchi"}"#,
                piFamilyMessage(
                    id: "kimchi-message",
                    model: "kimi-k2.6",
                    provider: "kimchi-dev",
                    input: 9,
                    output: 6),
            ],
            streamID: "kimchi",
            from: piFamilyDate("2026-08-20T00:00:00Z"),
            to: piFamilyDate("2026-08-21T00:00:00Z"))

        XCTAssertEqual(usage.tokenEvents.first?.source, "Kimchi")
        XCTAssertEqual(usage.tokenEvents.first?.model, "kimi-k2.6")
        XCTAssertEqual(usage.tokenEvents.first?.provider, "kimchi-dev")
    }
}

private func piFamilyDate(_ value: String) -> Date {
    ISO8601DateFormatter().date(from: value) ?? .distantPast
}

private func piFamilyMessage(
    id: String,
    model: String = "gpt-5.6-sol",
    provider: String = "openai",
    input: Int,
    output: Int,
    cacheRead: Int = 0,
    cacheWrite: Int = 0,
    reasoning: Int? = nil) -> String {
    var usage = [
        #""input":\#(input)"#,
        #""output":\#(output)"#,
        #""cacheRead":\#(cacheRead)"#,
        #""cacheWrite":\#(cacheWrite)"#,
    ]
    if let reasoning {
        usage.append(#""reasoning":\#(reasoning)"#)
    }
    return """
    {"type":"message","id":"\(id)","timestamp":"2026-08-20T12:00:00Z","message":\
    {"role":"assistant","model":"\(model)","provider":"\(provider)",\
    "usage":{\(usage.joined(separator: ","))}}}
    """
}

private func writePiFamilySession(
    to url: URL,
    sessionID: String,
    messageID: String,
    input: Int,
    output: Int) throws {
    try FileManager.default.createDirectory(
        at: url.deletingLastPathComponent(),
        withIntermediateDirectories: true)
    let content = [
        #"{"type":"session","id":"\#(sessionID)","cwd":"/tmp/project"}"#,
        piFamilyMessage(id: messageID, input: input, output: output),
    ].joined(separator: "\n")
    try Data(content.utf8).write(to: url)
}
