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
}

extension PiFamilyReaderTests {
    func test_piCountsOutOfRangeEventsAgainstParseLimit() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("toki-pi-window-limit-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let session = root.appendingPathComponent("session.jsonl")
        let content = [
            #"{"type":"session","id":"window-limit","cwd":"/tmp/project"}"#,
            piFamilyMessage(
                id: "old-message",
                timestamp: "2026-08-01T12:00:00Z",
                input: 100,
                output: 50),
            piFamilyMessage(
                id: "selected-message",
                timestamp: "2026-08-20T12:00:00Z",
                input: 9,
                output: 4),
        ].joined(separator: "\n")
        try Data(content.utf8).write(to: session)
        let limits = PiCompatibleReadLimits(
            maximumFileCount: 1,
            maximumFileBytes: 10 * 1024,
            maximumLineBytes: 2 * 1024,
            maximumEventCount: 1)

        XCTAssertThrowsError(try PiCompatibleReader(
            source: .pi,
            sessionRoots: [root],
            readLimits: limits)
            .readUsage(
                from: piFamilyDate("2026-08-20T00:00:00Z"),
                to: piFamilyDate("2026-08-21T00:00:00Z")))
    }

    func test_revisionSpanningDateBoundaryIsCountedInOnlyOneWindow() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("toki-pi-window-revision-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let session = root.appendingPathComponent("session.jsonl")
        let content = [
            #"{"type":"session","id":"window-revision","cwd":"/tmp/project"}"#,
            piFamilyMessage(
                id: "shared-message",
                timestamp: "2026-08-01T12:00:00Z",
                input: 100,
                output: 50),
            piFamilyMessage(
                id: "shared-message",
                timestamp: "2026-08-20T12:00:00Z",
                input: 9,
                output: 4),
        ].joined(separator: "\n")
        try Data(content.utf8).write(to: session)

        let reader = PiCompatibleReader(source: .pi, sessionRoots: [root])
        let firstDayUsage = try reader.readUsage(
            from: piFamilyDate("2026-08-01T00:00:00Z"),
            to: piFamilyDate("2026-08-02T00:00:00Z"))
        let piUsage = try reader
            .readUsage(
                from: piFamilyDate("2026-08-20T00:00:00Z"),
                to: piFamilyDate("2026-08-21T00:00:00Z"))
        let senpiUsage = try await SenpiReader(sessionRootsOverride: [root])
            .readUsage(
                from: piFamilyDate("2026-08-20T00:00:00Z"),
                to: piFamilyDate("2026-08-21T00:00:00Z"))

        XCTAssertEqual(firstDayUsage.totalTokens, 150)
        XCTAssertEqual(piUsage.totalTokens, 0)
        XCTAssertEqual(senpiUsage.totalTokens, 0)
        XCTAssertEqual(firstDayUsage.totalTokens + piUsage.totalTokens, 150)
    }

    func test_responseIDAndProviderSurviveIdlessRevisionMerge() {
        let usage = PiReader.usage(
            fromJSONLLines: [
                #"{"type":"session","id":"pi-revisions","cwd":"/tmp/project"}"#,
                """
                {"type":"message","timestamp":"2026-08-20T12:00:00Z","message":\
                {"role":"assistant","model":"custom-model","provider":"custom-provider",\
                "responseId":"shared-response","usage":{"input":3,"output":2}}}
                """,
                """
                {"type":"message","timestamp":"2026-08-20T12:00:01Z","message":\
                {"role":"assistant","model":"custom-model","responseId":"shared-response",\
                "usage":{"input":9,"output":6}}}
                """,
            ],
            streamID: "pi-revisions",
            from: piFamilyDate("2026-08-20T00:00:00Z"),
            to: piFamilyDate("2026-08-21T00:00:00Z"))

        XCTAssertEqual(usage.totalTokens, 15)
        XCTAssertEqual(usage.tokenEvents.count, 1)
        XCTAssertEqual(usage.tokenEvents.first?.provider, "custom-provider")
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
        XCTAssertEqual(
            usage.activityEvents.first { $0.streamID == "parent" }?.agentKind,
            .main)
    }

    func test_ompDeduplicatesIdlessResponsesAcrossParentAndChildSessions() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("toki-omp-idless-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let parent = root.appendingPathComponent("project/parent.jsonl")
        let child = root.appendingPathComponent("project/parent/Child.jsonl")
        try writePiFamilyIdlessSession(to: parent, sessionID: "parent", responseID: "copied")
        try writePiFamilyIdlessSession(to: child, sessionID: "child", responseID: "copied")

        let usage = try await OMPReader(sessionsURLOverride: root)
            .readUsage(
                from: piFamilyDate("2026-08-20T00:00:00Z"),
                to: piFamilyDate("2026-08-21T00:00:00Z"))

        XCTAssertEqual(usage.inputTokens, 3)
        XCTAssertEqual(usage.outputTokens, 2)
        XCTAssertEqual(usage.tokenEvents.count, 1)
        XCTAssertEqual(usage.activityEvents.first?.agentKind, .main)
    }

    func test_ompPreservesMainAttributionForCopiedChildWithParentSessionID() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("toki-omp-shared-session-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let parent = root.appendingPathComponent("project/parent.jsonl")
        let child = root.appendingPathComponent("project/parent/Child.jsonl")
        try writePiFamilySession(
            to: parent,
            sessionID: "parent",
            messageID: "copied",
            input: 3,
            output: 2)
        try writePiFamilySession(
            to: child,
            sessionID: "parent",
            messageID: "copied",
            input: 3,
            output: 2)

        let usage = try await OMPReader(sessionsURLOverride: root)
            .readUsage(
                from: piFamilyDate("2026-08-20T00:00:00Z"),
                to: piFamilyDate("2026-08-21T00:00:00Z"))

        XCTAssertEqual(usage.tokenEvents.count, 1)
        XCTAssertEqual(usage.activityEvents.first?.agentKind, .main)
    }

    func test_ompDeduplicatesCopiedChildWhenOneProjectPathIsMissing() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("toki-omp-missing-cwd-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let parent = root.appendingPathComponent("project/parent.jsonl")
        let child = root.appendingPathComponent("project/parent/Child.jsonl")
        try writePiFamilySession(
            to: parent,
            sessionID: "parent",
            messageID: "copied",
            input: 3,
            output: 2)
        try writePiFamilySession(
            to: child,
            sessionID: "child",
            messageID: "copied",
            input: 3,
            output: 2,
            cwd: nil)

        let usage = try await OMPReader(sessionsURLOverride: root)
            .readUsage(
                from: piFamilyDate("2026-08-20T00:00:00Z"),
                to: piFamilyDate("2026-08-21T00:00:00Z"))

        XCTAssertEqual(usage.inputTokens, 3)
        XCTAssertEqual(usage.outputTokens, 2)
        XCTAssertEqual(usage.tokenEvents.count, 1)
        XCTAssertEqual(usage.tokenEvents.first?.attribution?.projectPath, "/tmp/project")
    }

    func test_ompKeepsCopiedIDsFromConflictingProjectPathsIndependent() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("toki-omp-conflicting-cwd-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let parent = root.appendingPathComponent("project/parent.jsonl")
        let child = root.appendingPathComponent("project/parent/Child.jsonl")
        try writePiFamilySession(
            to: parent,
            sessionID: "parent",
            messageID: "shared",
            input: 3,
            output: 2,
            cwd: "/tmp/project-a")
        try writePiFamilySession(
            to: child,
            sessionID: "child",
            messageID: "shared",
            input: 3,
            output: 2,
            cwd: "/tmp/project-b")

        let usage = try await OMPReader(sessionsURLOverride: root)
            .readUsage(
                from: piFamilyDate("2026-08-20T00:00:00Z"),
                to: piFamilyDate("2026-08-21T00:00:00Z"))

        XCTAssertEqual(usage.inputTokens, 6)
        XCTAssertEqual(usage.outputTokens, 4)
        XCTAssertEqual(usage.tokenEvents.count, 2)
    }

    func test_ompKeepsMatchingIDsFromIndependentSessionTrees() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("toki-omp-independent-trees-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let main = root.appendingPathComponent("project/main.jsonl")
        let otherParent = root.appendingPathComponent("project/other.jsonl")
        let child = root.appendingPathComponent("project/other/Child.jsonl")
        try writePiFamilySession(
            to: main,
            sessionID: "main",
            messageID: "shared",
            input: 3,
            output: 2)
        try writePiFamilySessionHeader(to: otherParent, sessionID: "other")
        try writePiFamilySession(
            to: child,
            sessionID: "child",
            messageID: "shared",
            input: 7,
            output: 5)

        let usage = try await OMPReader(sessionsURLOverride: root)
            .readUsage(
                from: piFamilyDate("2026-08-20T00:00:00Z"),
                to: piFamilyDate("2026-08-21T00:00:00Z"))

        XCTAssertEqual(usage.inputTokens, 10)
        XCTAssertEqual(usage.outputTokens, 7)
        XCTAssertEqual(usage.tokenEvents.count, 2)
    }

    func test_ompKeepsDifferentUsageWithinParentChildTree() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("toki-omp-different-usage-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let parent = root.appendingPathComponent("project/parent.jsonl")
        let child = root.appendingPathComponent("project/parent/Child.jsonl")
        try writePiFamilySession(
            to: parent,
            sessionID: "parent",
            messageID: "shared",
            input: 3,
            output: 2)
        try writePiFamilySession(
            to: child,
            sessionID: "child",
            messageID: "shared",
            input: 7,
            output: 5)

        let usage = try await OMPReader(sessionsURLOverride: root)
            .readUsage(
                from: piFamilyDate("2026-08-20T00:00:00Z"),
                to: piFamilyDate("2026-08-21T00:00:00Z"))

        XCTAssertEqual(usage.inputTokens, 10)
        XCTAssertEqual(usage.outputTokens, 7)
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
    timestamp: String = "2026-08-20T12:00:00Z",
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
    {"type":"message","id":"\(id)","timestamp":"\(timestamp)","message":\
    {"role":"assistant","model":"\(model)","provider":"\(provider)",\
    "usage":{\(usage.joined(separator: ","))}}}
    """
}

private func writePiFamilySession(
    to url: URL,
    sessionID: String,
    messageID: String,
    input: Int,
    output: Int,
    cwd: String? = "/tmp/project") throws {
    try FileManager.default.createDirectory(
        at: url.deletingLastPathComponent(),
        withIntermediateDirectories: true)
    var sessionFields = [#""type":"session""#, #""id":"\#(sessionID)""#]
    if let cwd {
        sessionFields.append(#""cwd":"\#(cwd)""#)
    }
    let content = [
        "{\(sessionFields.joined(separator: ","))}",
        piFamilyMessage(id: messageID, input: input, output: output),
    ].joined(separator: "\n")
    try Data(content.utf8).write(to: url)
}

private func writePiFamilyIdlessSession(
    to url: URL,
    sessionID: String,
    responseID: String) throws {
    try FileManager.default.createDirectory(
        at: url.deletingLastPathComponent(),
        withIntermediateDirectories: true)
    let content = [
        #"{"type":"session","id":"\#(sessionID)","cwd":"/tmp/project"}"#,
        """
        {"type":"message","timestamp":"2026-08-20T12:00:00Z","message":\
        {"role":"assistant","model":"gpt-5.6-sol","provider":"openai",\
        "responseId":"\(responseID)","usage":{"input":3,"output":2}}}
        """,
    ].joined(separator: "\n")
    try Data(content.utf8).write(to: url)
}

private func writePiFamilySessionHeader(to url: URL, sessionID: String) throws {
    try FileManager.default.createDirectory(
        at: url.deletingLastPathComponent(),
        withIntermediateDirectories: true)
    try Data(#"{"type":"session","id":"\#(sessionID)"}"#.utf8).write(to: url)
}
