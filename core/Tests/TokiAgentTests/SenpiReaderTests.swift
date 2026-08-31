import Foundation
import TokiUsageCore
import XCTest
@testable import TokiUsageReaders

final class SenpiReaderTests: XCTestCase {
    func test_assistantUsagePreservesAllRecordedFields() {
        let usage = SenpiReader.usage(
            fromJSONLLines: [
                sessionLine(id: "session-123", cwd: "/Users/example/Toki"),
                assistantLine(
                    id: "message-1",
                    timestamp: "2026-08-20T12:00:00Z",
                    model: "claude-opus-5",
                    provider: "anthropic",
                    input: 100,
                    output: 30,
                    cacheRead: 8,
                    cacheWrite: 2,
                    reasoning: 7,
                    cost: 0.005),
            ],
            streamID: "/tmp/session-123.jsonl",
            from: date("2026-08-20T00:00:00Z"),
            to: date("2026-08-21T00:00:00Z"))

        XCTAssertEqual(usage.inputTokens, 100)
        XCTAssertEqual(usage.outputTokens, 23)
        XCTAssertEqual(usage.cacheReadTokens, 8)
        XCTAssertEqual(usage.cacheWriteTokens, 2)
        XCTAssertEqual(usage.reasoningTokens, 7)
        XCTAssertEqual(usage.totalTokens, 140)
        XCTAssertEqual(usage.cost, 0.005, accuracy: 0.000001)
        XCTAssertEqual(usage.perModel["claude-opus-5"]?.totalTokens, 140)
        XCTAssertEqual(usage.perModel["claude-opus-5"]?.sources, ["Senpi"])
        XCTAssertEqual(usage.tokenEvents.first?.model, "claude-opus-5")
        XCTAssertEqual(usage.tokenEvents.first?.provider, "anthropic")
        XCTAssertEqual(usage.tokenEvents.first?.source, "Senpi")
    }

    func test_reasoningRemainsVisibleWithoutInflatingReportedOutput() {
        let usage = SenpiReader.usage(
            fromJSONLLines: [
                sessionLine(),
                assistantLine(
                    id: "reasoning-message",
                    timestamp: "2026-08-20T12:00:00Z",
                    model: "gpt-5.6-sol",
                    provider: "openai",
                    input: 2,
                    output: 43,
                    cacheRead: 0,
                    cacheWrite: 38241,
                    reasoning: 16),
            ],
            streamID: "/tmp/reasoning.jsonl",
            from: date("2026-08-20T00:00:00Z"),
            to: date("2026-08-21T00:00:00Z"))

        XCTAssertEqual(usage.outputTokens, 27)
        XCTAssertEqual(usage.reasoningTokens, 16)
        XCTAssertEqual(usage.totalTokens, 38286)
        XCTAssertEqual(usage.tokenEvents.first?.totalTokens, 38286)
    }

    func test_missingProviderIsPreservedAsUnknownWithoutInventedCost() {
        let usage = SenpiReader.usage(
            fromJSONLLines: [
                sessionLine(),
                assistantLine(
                    id: "providerless",
                    timestamp: "2026-08-20T12:00:00Z",
                    model: "unrecognized-private-model",
                    provider: nil,
                    input: 4,
                    output: 3),
            ],
            streamID: "/tmp/providerless.jsonl",
            from: date("2026-08-20T00:00:00Z"),
            to: date("2026-08-21T00:00:00Z"))

        XCTAssertNil(usage.tokenEvents.first?.provider)
        XCTAssertEqual(usage.cost, 0)
        XCTAssertEqual(usage.tokenEvents.first?.cost, 0)
    }

    func test_sessionHeaderControlsExactAndUnknownAttribution() {
        let exact = SenpiReader.usage(
            fromJSONLLines: [
                sessionLine(id: "senpi-exact", cwd: "/Users/example/Toki"),
                assistantLine(
                    id: "exact-message",
                    timestamp: "2026-08-20T12:00:00Z",
                    model: "gpt-5.6-sol",
                    input: 1,
                    output: 1),
            ],
            streamID: "/tmp/fallback.jsonl",
            from: date("2026-08-20T00:00:00Z"),
            to: date("2026-08-21T00:00:00Z"))
        let unknown = SenpiReader.usage(
            fromJSONLLines: [
                sessionLine(id: "senpi-unknown", cwd: nil),
                assistantLine(
                    id: "unknown-message",
                    timestamp: "2026-08-20T12:00:00Z",
                    model: "gpt-5.6-sol",
                    input: 1,
                    output: 1),
            ],
            streamID: "/tmp/unknown.jsonl",
            from: date("2026-08-20T00:00:00Z"),
            to: date("2026-08-21T00:00:00Z"))

        XCTAssertEqual(exact.tokenEvents.first?.attribution?.projectPath, "/Users/example/Toki")
        XCTAssertEqual(exact.tokenEvents.first?.attribution?.projectName, "Toki")
        XCTAssertEqual(exact.tokenEvents.first?.attribution?.sessionID, "senpi-exact")
        XCTAssertEqual(exact.tokenEvents.first?.attribution?.quality, .exact)
        XCTAssertEqual(exact.activityEvents.first?.streamID, "senpi-exact")
        XCTAssertNil(unknown.tokenEvents.first?.attribution?.projectPath)
        XCTAssertEqual(unknown.tokenEvents.first?.attribution?.sessionID, "senpi-unknown")
        XCTAssertEqual(unknown.tokenEvents.first?.attribution?.quality, .unknown)
    }

    func test_controlRecordsMissingUsageAndMissingModelAreIgnored() {
        let usage = SenpiReader.usage(
            fromJSONLLines: [
                sessionLine(),
                #"{"type":"custom","id":"custom-1","# +
                    #""timestamp":"2026-08-20T12:00:00Z"}"#,
                #"{"type":"custom_message","id":"custom-2","# +
                    #""timestamp":"2026-08-20T12:00:01Z"}"#,
                #"{"type":"compaction","id":"compact-1","# +
                    #""timestamp":"2026-08-20T12:00:02Z"}"#,
                #"{"type":"thinking_level_change","id":"thinking-1","# +
                    #""timestamp":"2026-08-20T12:00:03Z"}"#,
                #"{"type":"session_info","id":"info-1","name":"Human readable title","# +
                    #""timestamp":"2026-08-20T12:00:04Z"}"#,
                #"{"type":"message","id":"user-1","timestamp":"2026-08-20T12:00:05Z","# +
                    #""message":{"role":"user"}}"#,
                #"{"type":"message","id":"no-usage","timestamp":"2026-08-20T12:00:06Z","# +
                    #""message":{"role":"assistant","model":"gpt-5.6-sol"}}"#,
                #"{"type":"message","id":"no-model","timestamp":"2026-08-20T12:00:07Z","# +
                    #""message":{"role":"assistant","usage":{"input":9,"output":9}}}"#,
            ],
            streamID: "/tmp/control.jsonl",
            from: date("2026-08-20T00:00:00Z"),
            to: date("2026-08-21T00:00:00Z"))

        XCTAssertEqual(usage.totalTokens, 0)
        XCTAssertTrue(usage.tokenEvents.isEmpty)
        XCTAssertTrue(usage.activityEvents.isEmpty)
    }

    func test_malformedFramingOnlyDropsAffectedLines() {
        let usage = SenpiReader.usage(
            fromJSONLLines: [
                "",
                sessionLine(),
                "not valid json",
                assistantLine(
                    id: "complete",
                    timestamp: "2026-08-20T12:00:00Z",
                    model: "gpt-5.6-sol",
                    input: 7,
                    output: 11),
                #"{"type":"message","id":"truncated","message":{"role":"assistant""#,
            ],
            streamID: "/tmp/malformed.jsonl",
            from: date("2026-08-20T00:00:00Z"),
            to: date("2026-08-21T00:00:00Z"))

        XCTAssertEqual(usage.inputTokens, 7)
        XCTAssertEqual(usage.outputTokens, 11)
        XCTAssertEqual(usage.tokenEvents.map(\.model), ["gpt-5.6-sol"])
    }

    func test_dateRangeIsHalfOpen() {
        let usage = SenpiReader.usage(
            fromJSONLLines: [
                sessionLine(),
                assistantLine(
                    id: "before",
                    timestamp: "2026-08-19T23:59:59Z",
                    model: "gpt-5.6-sol",
                    input: 100,
                    output: 1),
                assistantLine(
                    id: "start",
                    timestamp: "2026-08-20T00:00:00Z",
                    model: "gpt-5.6-sol",
                    input: 2,
                    output: 3),
                assistantLine(
                    id: "end",
                    timestamp: "2026-08-21T00:00:00Z",
                    model: "gpt-5.6-sol",
                    input: 200,
                    output: 1),
            ],
            streamID: "/tmp/bounds.jsonl",
            from: date("2026-08-20T00:00:00Z"),
            to: date("2026-08-21T00:00:00Z"))

        XCTAssertEqual(usage.totalTokens, 5)
        XCTAssertEqual(usage.tokenEvents.map(\.timestamp), [date("2026-08-20T00:00:00Z")])
    }
}

extension SenpiReaderTests {
    func test_controlRecordBeforeSessionHeaderDoesNotDiscardLaterUsage() {
        let usage = SenpiReader.usage(
            fromJSONLLines: [
                #"{"type":"custom","id":"before-header"}"#,
                sessionLine(),
                assistantLine(
                    id: "after-header",
                    timestamp: "2026-08-20T12:00:00Z",
                    model: "gpt-5.6-sol",
                    input: 7,
                    output: 5),
            ],
            streamID: "/tmp/pre-header-control.jsonl",
            from: date("2026-08-20T00:00:00Z"),
            to: date("2026-08-21T00:00:00Z"))

        XCTAssertEqual(usage.totalTokens, 12)
        XCTAssertEqual(usage.tokenEvents.count, 1)
    }

    func test_readerDiscoversDelegatedChildrenAndDeduplicatesOverlappingRoots() async throws {
        let fixture = try SenpiReaderFixture()
        defer { fixture.remove() }
        let project = fixture.root.appendingPathComponent("project")
        let childSessions = project.appendingPathComponent(
            ".omo/senpi-task/children/task-1/sessions/task-1")
        try FileManager.default.createDirectory(at: childSessions, withIntermediateDirectories: true)
        let session = childSessions.appendingPathComponent("child.jsonl")
        try fixture.writeSession(to: session, messageID: "child-message", input: 5, output: 3)
        let reader = SenpiReader(sessionRootsOverride: [project, childSessions, project])

        let usage = try await reader.readUsage(
            from: date("2026-08-20T00:00:00Z"),
            to: date("2026-08-21T00:00:00Z"))

        XCTAssertEqual(usage.totalTokens, 8)
        XCTAssertEqual(usage.tokenEvents.count, 1)
        XCTAssertEqual(usage.activityEvents.first?.agentKind, .subagent)
    }

    func test_readerDeduplicatesCopiedMessagesAcrossParentAndChildFiles() async throws {
        let fixture = try SenpiReaderFixture()
        defer { fixture.remove() }
        let parent = fixture.root.appendingPathComponent("parent.jsonl")
        let childDirectory = fixture.root.appendingPathComponent(".omo/senpi-task/children/task")
        try FileManager.default.createDirectory(at: childDirectory, withIntermediateDirectories: true)
        let child = childDirectory.appendingPathComponent("child.jsonl")
        try fixture.writeSession(
            to: parent,
            sessionID: "copied-session",
            messageID: "copied-message",
            input: 10,
            output: 5)
        try fixture.writeSession(
            to: child,
            sessionID: "child-session",
            messageID: "copied-message",
            input: 10,
            output: 5)
        let reader = SenpiReader(sessionRootsOverride: [fixture.root, childDirectory])

        let usage = try await reader.readUsage(
            from: date("2026-08-20T00:00:00Z"),
            to: date("2026-08-21T00:00:00Z"))

        XCTAssertEqual(usage.totalTokens, 15)
        XCTAssertEqual(usage.tokenEvents.count, 1)
    }

    func test_readerChoosesOneCoherentRevisionForCopiedMessage() async throws {
        let fixture = try SenpiReaderFixture()
        defer { fixture.remove() }
        let parent = fixture.root.appendingPathComponent("parent.jsonl")
        let childDirectory = fixture.root.appendingPathComponent(".omo/senpi-task/children/task")
        try FileManager.default.createDirectory(at: childDirectory, withIntermediateDirectories: true)
        let child = childDirectory.appendingPathComponent("child.jsonl")
        try fixture.writeSession(
            to: parent,
            sessionID: "revised-session",
            messageID: "revised-message",
            input: 10,
            output: 20)
        try fixture.writeSession(
            to: child,
            sessionID: "child-revised-session",
            messageID: "revised-message",
            input: 20,
            output: 5)
        let reader = SenpiReader(sessionRootsOverride: [fixture.root, childDirectory])

        let usage = try await reader.readUsage(
            from: date("2026-08-20T00:00:00Z"),
            to: date("2026-08-21T00:00:00Z"))

        XCTAssertEqual(usage.inputTokens, 10)
        XCTAssertEqual(usage.outputTokens, 20)
        XCTAssertEqual(usage.totalTokens, 30)
        XCTAssertEqual(usage.tokenEvents.count, 1)
    }

    func test_readerIncludesInRangeRecordFromOldMtimeFile() async throws {
        let fixture = try SenpiReaderFixture()
        defer { fixture.remove() }
        let session = fixture.root.appendingPathComponent("restored.jsonl")
        try fixture.writeSession(to: session, messageID: "restored-message", input: 9, output: 4)
        try FileManager.default.setAttributes(
            [.modificationDate: date("2026-08-01T00:00:00Z")],
            ofItemAtPath: session.path)
        let reader = SenpiReader(sessionRootsOverride: [fixture.root])

        let usage = try await reader.readUsage(
            from: date("2026-08-20T00:00:00Z"),
            to: date("2026-08-21T00:00:00Z"))

        XCTAssertEqual(usage.totalTokens, 13)
        XCTAssertEqual(usage.tokenEvents.count, 1)
    }

    func test_dateFilteringUsesGloballyDeduplicatedMessageRevision() {
        let lines = [
            sessionLine(),
            assistantLine(
                id: "cross-boundary-revision",
                timestamp: "2026-08-20T23:59:59Z",
                model: "gpt-5.6-sol",
                input: 10,
                output: 5),
            assistantLine(
                id: "cross-boundary-revision",
                timestamp: "2026-08-21T00:00:01Z",
                model: "gpt-5.6-sol",
                input: 20,
                output: 10),
        ]

        let firstDay = SenpiReader.usage(
            fromJSONLLines: lines,
            streamID: "/tmp/cross-boundary.jsonl",
            from: date("2026-08-20T00:00:00Z"),
            to: date("2026-08-21T00:00:00Z"))
        let secondDay = SenpiReader.usage(
            fromJSONLLines: lines,
            streamID: "/tmp/cross-boundary.jsonl",
            from: date("2026-08-21T00:00:00Z"),
            to: date("2026-08-22T00:00:00Z"))

        XCTAssertEqual(firstDay.totalTokens, 0)
        XCTAssertEqual(secondDay.totalTokens, 30)
        XCTAssertEqual(firstDay.tokenEvents.count + secondDay.tokenEvents.count, 1)
    }

    func test_distinctMessagesReusingResponseIDAreBothCounted() {
        let usage = SenpiReader.usage(
            fromJSONLLines: [
                sessionLine(),
                assistantLine(
                    id: "first-message",
                    responseID: "reused-response",
                    timestamp: "2026-08-20T12:00:00Z",
                    model: "gpt-5.6-sol",
                    input: 10,
                    output: 5),
                assistantLine(
                    id: "second-message",
                    responseID: "reused-response",
                    timestamp: "2026-08-20T13:00:00Z",
                    model: "gpt-5.6-sol",
                    input: 20,
                    output: 7),
            ],
            streamID: "/tmp/reused-response.jsonl",
            from: date("2026-08-20T00:00:00Z"),
            to: date("2026-08-21T00:00:00Z"))

        XCTAssertEqual(usage.inputTokens, 30)
        XCTAssertEqual(usage.outputTokens, 12)
        XCTAssertEqual(usage.tokenEvents.count, 2)
    }

    func test_extremeTokenCountersClampBeforeAggregation() {
        let usage = SenpiReader.usage(
            fromJSONLLines: [
                sessionLine(),
                assistantLine(
                    id: "extreme-token-count",
                    timestamp: "2026-08-20T12:00:00Z",
                    model: "gpt-5.6-sol",
                    input: Int.max,
                    output: 1),
            ],
            streamID: "/tmp/extreme-token-count.jsonl",
            from: date("2026-08-20T00:00:00Z"),
            to: date("2026-08-21T00:00:00Z"))

        XCTAssertEqual(usage.inputTokens, 1_000_000_000)
        XCTAssertEqual(usage.outputTokens, 1)
        XCTAssertEqual(usage.totalTokens, 1_000_000_001)
        XCTAssertEqual(usage.tokenEvents.first?.totalTokens, 1_000_000_001)
    }

    func test_readerRejectsJSONLLineBeyondConfiguredBound() async throws {
        let fixture = try SenpiReaderFixture()
        defer { fixture.remove() }
        let file = fixture.root.appendingPathComponent("oversized.jsonl")
        try Data((String(repeating: "x", count: 256) + "\n").utf8).write(to: file)
        let reader = SenpiReader(
            sessionRootsOverride: [fixture.root],
            readLimits: PiCompatibleReadLimits(
                maximumFileCount: 10,
                maximumFileBytes: 1024,
                maximumLineBytes: 128,
                maximumEventCount: 10))

        do {
            _ = try await reader.readUsage(
                from: date("2026-08-20T00:00:00Z"),
                to: date("2026-08-21T00:00:00Z"))
            XCTFail("Expected an oversized-line error")
        } catch let error as PiCompatibleReaderError {
            XCTAssertEqual(error, .lineTooLong(file))
        }
    }

    func test_readerReportsInvalidUTF8InsteadOfReturningEmptyUsage() async throws {
        let fixture = try SenpiReaderFixture()
        defer { fixture.remove() }
        let file = fixture.root.appendingPathComponent("invalid-utf8.jsonl")
        var data = Data((sessionLine() + "\n").utf8)
        data.append(contentsOf: [0xFF, 0x0A])
        try data.write(to: file)
        let reader = SenpiReader(sessionRootsOverride: [fixture.root])

        do {
            _ = try await reader.readUsage(
                from: date("2026-08-20T00:00:00Z"),
                to: date("2026-08-21T00:00:00Z"))
            XCTFail("Expected an invalid-UTF8 error")
        } catch let error as PiCompatibleReaderError {
            XCTAssertEqual(error, .invalidUTF8(file, line: 1))
        }
    }

    func test_readerReturnsEmptyUsageForMissingRoots() async throws {
        let missing = FileManager.default.temporaryDirectory
            .appendingPathComponent("missing-senpi-\(UUID().uuidString)")
        let reader = SenpiReader(sessionRootsOverride: [missing])

        let usage = try await reader.readUsage(
            from: date("2026-08-20T00:00:00Z"),
            to: date("2026-08-21T00:00:00Z"))

        XCTAssertFalse(usage.hasReportableData)
    }

    func test_pathsAcceptOnlyAbsoluteSenpiOverridesAndIncludeDelegatedLayouts() {
        let home = URL(fileURLWithPath: "/tmp/toki-home")
        let paths = LocalUsageReaderPaths(
            homeDirectory: home,
            environment: [
                "PWD": "/tmp/project",
                "SENPI_CODING_AGENT_DIR": "/tmp/senpi-agent",
                "SENPI_CODING_AGENT_SESSION_DIR": "/tmp/direct-sessions",
            ])

        XCTAssertEqual(paths.senpiSessionDirectories.map(\.path), [
            "/tmp/toki-home/.omo/agent/sessions",
            "/tmp/toki-home/.senpi/agent/sessions",
            "/tmp/toki-home/.omo/senpi-task/children",
            "/tmp/toki-home/.omo/senpi-task/sessions",
            "/tmp/senpi-agent/sessions",
            "/tmp/direct-sessions",
            "/tmp/project/.omo/senpi-task/children",
            "/tmp/project/.omo/senpi-task/sessions",
        ])

        let ignored = LocalUsageReaderPaths(
            homeDirectory: home,
            environment: [
                "PWD": "",
                "SENPI_CODING_AGENT_DIR": "relative-agent",
                "SENPI_CODING_AGENT_SESSION_DIR": "",
            ])
        XCTAssertEqual(
            ignored.senpiSessionDirectories.map(\.path),
            [
                "/tmp/toki-home/.omo/agent/sessions",
                "/tmp/toki-home/.senpi/agent/sessions",
                "/tmp/toki-home/.omo/senpi-task/children",
                "/tmp/toki-home/.omo/senpi-task/sessions",
            ])
    }
}

private struct SenpiReaderFixture {
    let root: URL

    init() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("toki-senpi-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    func writeSession(
        to url: URL,
        sessionID: String? = nil,
        messageID: String,
        input: Int,
        output: Int) throws {
        let content = [
            sessionLine(
                id: sessionID ?? url.deletingPathExtension().lastPathComponent,
                cwd: "/tmp/project"),
            assistantLine(
                id: messageID,
                timestamp: "2026-08-20T12:00:00Z",
                model: "gpt-5.6-sol",
                provider: "openai",
                input: input,
                output: output),
        ]
        .joined(separator: "\n")
        try Data(content.utf8).write(to: url)
    }

    func remove() {
        try? FileManager.default.removeItem(at: root)
    }
}

private func sessionLine(
    id: String = "session-123",
    cwd: String? = "/Users/example/Toki") -> String {
    var fields = [
        #""type":"session""#,
        #""id":"\#(id)""#,
        #""timestamp":"2026-08-20T08:00:00Z""#,
    ]
    if let cwd {
        fields.append(#""cwd":"\#(cwd)""#)
    }
    return "{\(fields.joined(separator: ","))}"
}

private func assistantLine(
    id: String,
    responseID: String? = nil,
    timestamp: String,
    model: String,
    provider: String? = nil,
    input: Int,
    output: Int,
    cacheRead: Int = 0,
    cacheWrite: Int = 0,
    reasoning: Int? = nil,
    cost: Double? = nil) -> String {
    var usageFields = [
        #""input":\#(input)"#,
        #""output":\#(output)"#,
        #""cacheRead":\#(cacheRead)"#,
        #""cacheWrite":\#(cacheWrite)"#,
    ]
    if let reasoning {
        usageFields.append(#""reasoning":\#(reasoning)"#)
    }
    if let cost {
        usageFields.append(#""cost":{"total":\#(cost)}"#)
    }
    var messageFields = [
        #""role":"assistant""#,
        #""model":"\#(model)""#,
        #""usage":{\#(usageFields.joined(separator: ","))}"#,
    ]
    if let responseID {
        messageFields.append(#""responseId":"\#(responseID)""#)
    }
    if let provider {
        messageFields.append(#""provider":"\#(provider)""#)
    }
    return """
    {"type":"message","id":"\(id)","timestamp":"\(timestamp)","message":{\(messageFields.joined(separator: ","))}}
    """
}

private func date(_ value: String) -> Date {
    ISO8601DateFormatter().date(from: value)!
}
