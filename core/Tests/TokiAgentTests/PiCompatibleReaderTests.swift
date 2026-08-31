import Foundation
import TokiUsageCore
import XCTest
@testable import TokiUsageReaders

final class PiCompatibleReaderTests: XCTestCase {
    private let start = piTestDate("2026-08-01T00:00:00Z")
    private let end = piTestDate("2026-08-02T00:00:00Z")

    func test_fourSourcesDecodeTheSameWireUsageWithDistinctLabels() {
        let lines = [
            sessionLine(),
            assistantLine(
                id: "shared-message",
                timestamp: "2026-08-01T12:00:00Z",
                model: "claude-opus-5",
                provider: "anthropic",
                input: 11,
                output: 7,
                cacheRead: 5,
                cacheWrite: 3,
                reasoning: 2,
                cost: 0.25),
        ]

        let usages = [
            SenpiReader.usage(fromJSONLLines: lines, streamID: "senpi", from: start, to: end),
            PiReader.usage(fromJSONLLines: lines, streamID: "pi", from: start, to: end),
            OMPReader.usage(fromJSONLLines: lines, streamID: "omp", from: start, to: end),
            KimchiReader.usage(fromJSONLLines: lines, streamID: "kimchi", from: start, to: end),
        ]

        XCTAssertEqual(usages.map(\.inputTokens), [11, 11, 11, 11])
        XCTAssertEqual(usages.map(\.outputTokens), [7, 7, 7, 7])
        XCTAssertEqual(usages.map(\.cacheReadTokens), [5, 5, 5, 5])
        XCTAssertEqual(usages.map(\.cacheWriteTokens), [3, 3, 3, 3])
        XCTAssertEqual(usages.map(\.reasoningTokens), [2, 2, 2, 2])
        XCTAssertEqual(usages.map(\.totalTokens), [28, 28, 28, 28])
        XCTAssertEqual(usages.map(\.cost), [0.25, 0.25, 0.25, 0.25])
        XCTAssertEqual(usages.compactMap { $0.tokenEvents.first?.costIsKnown }, [true, true, true, true])
        XCTAssertEqual(
            usages.compactMap { $0.tokenEvents.first?.source },
            ["Senpi", "Pi", "Oh My Pi", "Kimchi"])
    }

    func test_dateRangeIsStartInclusiveAndEndExclusive() {
        let lines = [
            sessionLine(),
            assistantLine(id: "before", timestamp: "2026-07-31T23:59:59Z", input: 100, output: 1),
            assistantLine(id: "start", timestamp: "2026-08-01T00:00:00Z", input: 2, output: 3),
            assistantLine(id: "end", timestamp: "2026-08-02T00:00:00Z", input: 200, output: 1),
        ]

        let usage = PiReader.usage(
            fromJSONLLines: lines,
            streamID: "range",
            from: start,
            to: end)

        XCTAssertEqual(usage.inputTokens, 2)
        XCTAssertEqual(usage.outputTokens, 3)
        XCTAssertEqual(usage.tokenEvents.count, 1)
    }

    func test_negativeAndMissingTokensClampToZeroWithoutReasoningDoubleCount() {
        let message = [
            #"{"type":"message","id":"negative","timestamp":"2026-08-01T12:00:00Z","message":"#,
            #"{"role":"assistant","model":"gpt-5","usage":"#,
            #"{"input":-5,"output":9,"cacheRead":-3,"reasoning":4}}}"#,
        ].joined()
        let lines = [
            sessionLine(),
            message,
        ]

        let usage = SenpiReader.usage(
            fromJSONLLines: lines,
            streamID: "negative",
            from: start,
            to: end)

        XCTAssertEqual(usage.inputTokens, 0)
        XCTAssertEqual(usage.outputTokens, 9)
        XCTAssertEqual(usage.cacheReadTokens, 0)
        XCTAssertEqual(usage.cacheWriteTokens, 0)
        XCTAssertEqual(usage.reasoningTokens, 4)
        XCTAssertEqual(usage.totalTokens, 13)
    }

    func test_oversizedTokenTotalsAreDroppedWithoutOverflowing() {
        let message = [
            #"{"type":"message","id":"oversized","timestamp":"2026-08-01T12:00:00Z","message":"#,
            #"{"role":"assistant","model":"gpt-5","usage":"#,
            #"{"input":9223372036854775807,"output":9223372036854775807}}}"#,
        ].joined()

        let usage = PiReader.usage(
            fromJSONLLines: [sessionLine(), message],
            streamID: "oversized",
            from: start,
            to: end)

        XCTAssertEqual(usage.totalTokens, 0)
        XCTAssertTrue(usage.tokenEvents.isEmpty)
    }

    func test_malformedMiddleAndTruncatedTrailingLinesKeepValidMessages() {
        let lines = [
            sessionLine(),
            assistantLine(id: "first", timestamp: "2026-08-01T12:00:00Z", input: 3, output: 4),
            "not-json",
            assistantLine(id: "second", timestamp: "2026-08-01T12:01:00Z", input: 5, output: 6),
            #"{"type":"message","id":"truncated","message":{"role":"assistant""#,
        ]

        let usage = KimchiReader.usage(
            fromJSONLLines: lines,
            streamID: "damaged",
            from: start,
            to: end)

        XCTAssertEqual(usage.inputTokens, 8)
        XCTAssertEqual(usage.outputTokens, 10)
        XCTAssertEqual(usage.tokenEvents.count, 2)
    }

    func test_sameResponseIDAcrossExplicitSessionsRemainsIndependent() {
        let lines = [
            sessionLine(id: "session-a"),
            assistantLine(
                id: "message-a",
                responseID: "shared-response",
                timestamp: "2026-08-01T12:00:00Z",
                input: 3,
                output: 2),
            sessionLine(id: "session-b"),
            assistantLine(
                id: "message-b",
                responseID: "shared-response",
                timestamp: "2026-08-01T12:00:00Z",
                input: 3,
                output: 2),
        ]

        let usage = PiReader.usage(
            fromJSONLLines: lines,
            streamID: "session-scope",
            from: start,
            to: end)

        XCTAssertEqual(usage.inputTokens, 6)
        XCTAssertEqual(usage.outputTokens, 4)
        XCTAssertEqual(usage.tokenEvents.count, 2)
    }

    func test_conflictingResponseIDRecordsWithinSessionRemainIndependent() {
        let lines = [
            sessionLine(id: "collision-session"),
            assistantLine(
                id: "message-a",
                responseID: "colliding-response",
                timestamp: "2026-08-01T12:00:00Z",
                input: 3,
                output: 2),
            assistantLine(
                id: "message-b",
                responseID: "colliding-response",
                timestamp: "2026-08-01T12:01:00Z",
                input: 7,
                output: 5),
        ]

        let usage = PiReader.usage(
            fromJSONLLines: lines,
            streamID: "response-collision",
            from: start,
            to: end)

        XCTAssertEqual(usage.inputTokens, 10)
        XCTAssertEqual(usage.outputTokens, 7)
        XCTAssertEqual(usage.tokenEvents.count, 2)
    }

    func test_duplicateDiscoveryReadsOnePhysicalFileOnce() async throws {
        let fixture = try SessionFixture()
        defer { fixture.remove() }
        let file = fixture.root.appendingPathComponent("project/session.jsonl")
        try fixture.writeSession(to: file, messageID: "single", input: 7, output: 4)
        let linkedRoot = fixture.root.deletingLastPathComponent()
            .appendingPathComponent("toki-pi-link-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: linkedRoot) }
        try FileManager.default.createSymbolicLink(at: linkedRoot, withDestinationURL: fixture.root)
        let reader = PiReader(sessionRootsOverride: [fixture.root, fixture.root, linkedRoot])

        let usage = try await reader.readUsage(from: start, to: end)

        XCTAssertEqual(usage.inputTokens, 7)
        XCTAssertEqual(usage.outputTokens, 4)
        XCTAssertEqual(usage.tokenEvents.count, 1)
    }
}

extension PiCompatibleReaderTests {
    func test_piPreservesHeaderMessageAndInfersTrustedProviderFamily() {
        let lines = [
            sessionLine(id: "pi-session", cwd: "/tmp/pi-project"),
            assistantLine(
                id: "pi-message",
                timestamp: "2026-08-01T12:00:00Z",
                model: "gpt-5",
                provider: nil,
                input: 10,
                output: 4),
        ]

        let messages = PiCompatibleSessionParser.messages(fromJSONLLines: lines, source: .pi)
        let unknownProvider = PiCompatibleSessionParser.messages(
            fromJSONLLines: [
                sessionLine(id: "unknown-provider"),
                assistantLine(
                    id: "unknown-message",
                    timestamp: "2026-08-01T12:00:00Z",
                    model: "custom-local-model",
                    provider: nil,
                    input: 1,
                    output: 1),
            ],
            source: .pi)
        let usage = PiReader.usage(fromJSONLLines: lines, streamID: "pi", from: start, to: end)

        XCTAssertEqual(messages.first?.provider, "openai")
        guard let unknownMessage = unknownProvider.first else {
            return XCTFail("Expected unknown-provider message")
        }
        XCTAssertNil(unknownMessage.provider)
        XCTAssertEqual(messages.first?.model, "gpt-5")
        XCTAssertEqual(messages.first?.sessionID, "pi-session")
        XCTAssertEqual(messages.first?.cwd, "/tmp/pi-project")
        XCTAssertEqual(usage.tokenEvents.first?.attribution?.projectPath, "/tmp/pi-project")
    }

    func test_piRecognizesOnlyGeneratedSubagentNames() {
        let valid = [
            sessionLine(),
            sessionInfoLine(name: "subagent-context-builder-208242ce-1"),
            assistantLine(id: "valid", timestamp: "2026-08-01T12:00:00Z", input: 1, output: 1),
        ]
        let title = [
            sessionLine(),
            sessionInfoLine(name: "Refactor authentication module"),
            assistantLine(id: "title", timestamp: "2026-08-01T12:00:00Z", input: 1, output: 1),
        ]
        let uuid = [
            sessionLine(),
            sessionInfoLine(name: "subagent-reviewer-550e8400-e29b-41d4-a716-446655440000"),
            assistantLine(id: "uuid", timestamp: "2026-08-01T12:00:00Z", input: 1, output: 1),
        ]

        let validMessages = PiCompatibleSessionParser.messages(fromJSONLLines: valid, source: .pi)
        let titleMessages = PiCompatibleSessionParser.messages(fromJSONLLines: title, source: .pi)
        let uuidMessages = PiCompatibleSessionParser.messages(fromJSONLLines: uuid, source: .pi)

        XCTAssertEqual(validMessages.first?.agentName, "context-builder")
        XCTAssertEqual(validMessages.first?.agentKind, .subagent)
        XCTAssertEqual(uuidMessages.first?.agentName, "reviewer")
        XCTAssertEqual(uuidMessages.first?.agentKind, .subagent)
        XCTAssertNil(titleMessages.first?.agentName)
        XCTAssertEqual(titleMessages.first?.agentKind, .main)
    }
}

extension PiCompatibleReaderTests {
    func test_ompAllowsLeadingTitlesButRejectsUnknownPreHeaderRecords() {
        let message = assistantLine(
            id: "omp-message",
            timestamp: "2026-08-01T12:00:00Z",
            input: 4,
            output: 2)
        let titled = [
            #"{"type":"title","title":"first"}"#,
            #"{"type":"title","title":"second"}"#,
            sessionLine(id: "omp-session"),
            message,
        ]
        let unknown = [
            #"{"type":"foreign","value":1}"#,
            sessionLine(id: "foreign-session"),
            message,
        ]

        XCTAssertEqual(
            PiCompatibleSessionParser.messages(fromJSONLLines: titled, source: .ohMyPi).count,
            1)
        XCTAssertTrue(
            PiCompatibleSessionParser.messages(fromJSONLLines: unknown, source: .ohMyPi).isEmpty)
    }

    func test_ompRecursivelyReadsChildAndAdvisorFiles() async throws {
        let fixture = try SessionFixture()
        defer { fixture.remove() }
        try fixture.writeSession(
            to: fixture.root.appendingPathComponent("project/parent.jsonl"),
            messageID: "parent",
            input: 1,
            output: 1)
        try fixture.writeSession(
            to: fixture.root.appendingPathComponent("project/parent/Builder.jsonl"),
            messageID: "child",
            input: 2,
            output: 2)
        try fixture.writeSession(
            to: fixture.root.appendingPathComponent("project/parent/__advisor.review.jsonl"),
            messageID: "advisor",
            input: 3,
            output: 3)

        let usage = try await OMPReader(sessionsURLOverride: fixture.root)
            .readUsage(from: start, to: end)

        XCTAssertEqual(usage.inputTokens, 6)
        XCTAssertEqual(usage.outputTokens, 6)
        XCTAssertEqual(usage.tokenEvents.count, 3)
    }

    func test_ompDeduplicatesCopiedParentChildMessages() async throws {
        let fixture = try SessionFixture()
        defer { fixture.remove() }
        try fixture.writeSession(
            to: fixture.root.appendingPathComponent("project/parent.jsonl"),
            messageID: "copied",
            sessionID: "copied-session",
            input: 8,
            output: 5)
        try fixture.writeSession(
            to: fixture.root.appendingPathComponent("project/parent/Child.jsonl"),
            messageID: "copied",
            sessionID: "copied-session",
            input: 8,
            output: 5)

        let usage = try await OMPReader(sessionsURLOverride: fixture.root)
            .readUsage(from: start, to: end)

        XCTAssertEqual(usage.inputTokens, 8)
        XCTAssertEqual(usage.outputTokens, 5)
        XCTAssertEqual(usage.tokenEvents.count, 1)
    }
}

extension PiCompatibleReaderTests {
    func test_gjcSkipsUnknownPreHeaderRecordsAndUsesStreamFallbackSession() {
        let lines = [
            #"{"type":"metadata","version":1}"#,
            assistantLine(
                id: "headerless",
                timestamp: "2026-08-01T12:00:00Z",
                input: 6,
                output: 4),
        ]

        let usage = GJCReader.usage(
            fromJSONLLines: lines,
            streamID: "/tmp/fallback-session.jsonl",
            from: start,
            to: end)

        XCTAssertEqual(usage.inputTokens, 6)
        XCTAssertEqual(usage.outputTokens, 4)
        XCTAssertEqual(usage.tokenEvents.first?.attribution?.sessionID, "fallback-session")
    }

    func test_gjcKeepsUsageWhenOptionalMessageMetadataHasWrongType() {
        let message = [
            #"{"type":"message","id":"lossy","timestamp":"2026-08-01T12:00:00Z","message":"#,
            #"{"role":"assistant","model":{"unexpected":true},"provider":42,"usage":"#,
            #"{"input":7,"output":5}}}"#,
        ].joined()

        let usage = GJCReader.usage(
            fromJSONLLines: [sessionLine(id: "lossy-session"), message],
            streamID: "/tmp/lossy-session.jsonl",
            from: start,
            to: end)

        XCTAssertEqual(usage.inputTokens, 7)
        XCTAssertEqual(usage.outputTokens, 5)
        XCTAssertNil(usage.tokenEvents.first?.model)
        XCTAssertNil(usage.tokenEvents.first?.provider)
    }

    func test_responseIDDedupRemainsProviderScoped() {
        let lines = [
            sessionLine(),
            assistantLine(
                id: "openai-message",
                responseID: "shared-provider-id",
                timestamp: "2026-08-01T12:00:00Z",
                model: "gpt-5",
                provider: "openai",
                input: 3,
                output: 2),
            assistantLine(
                id: "anthropic-message",
                responseID: "shared-provider-id",
                timestamp: "2026-08-01T12:01:00Z",
                model: "claude-opus-5",
                provider: "anthropic",
                input: 5,
                output: 4),
        ]

        let usage = PiReader.usage(
            fromJSONLLines: lines,
            streamID: "provider-dedup",
            from: start,
            to: end)

        XCTAssertEqual(usage.inputTokens, 8)
        XCTAssertEqual(usage.outputTokens, 6)
        XCTAssertEqual(usage.tokenEvents.count, 2)
    }

    func test_kimchiPreservesRecordedProviderModelSourceAndDeduplicatesMessageIDs() async throws {
        let fixture = try SessionFixture()
        defer { fixture.remove() }
        let first = fixture.root.appendingPathComponent("one.jsonl")
        let second = fixture.root.appendingPathComponent("copy/two.jsonl")
        try fixture.writeSession(
            to: first,
            messageID: "kimchi-message",
            sessionID: "kimchi-session",
            model: "kimi-k2.6",
            provider: "kimchi-dev",
            input: 9,
            output: 6)
        try fixture.writeSession(
            to: second,
            messageID: "kimchi-message",
            sessionID: "kimchi-session",
            model: "kimi-k2.6",
            provider: "kimchi-dev",
            input: 9,
            output: 6)

        let messages = PiCompatibleSessionParser.messages(
            fromJSONLLines: [
                sessionLine(id: "kimchi-session"),
                assistantLine(
                    id: "kimchi-message",
                    timestamp: "2026-08-01T12:00:00Z",
                    model: "kimi-k2.6",
                    provider: "kimchi-dev",
                    input: 9,
                    output: 6),
            ],
            source: .kimchi)
        let usage = try await KimchiReader(sessionsURLOverride: fixture.root)
            .readUsage(from: start, to: end)

        XCTAssertEqual(messages.first?.provider, "kimchi-dev")
        XCTAssertEqual(messages.first?.model, "kimi-k2.6")
        XCTAssertEqual(usage.tokenEvents.first?.source, "Kimchi")
        XCTAssertEqual(usage.tokenEvents.first?.provider, "kimchi-dev")
        XCTAssertEqual(usage.tokenEvents.first?.costIsKnown, false)
        XCTAssertEqual(usage.inputTokens, 9)
        XCTAssertEqual(usage.outputTokens, 6)
        XCTAssertEqual(usage.tokenEvents.count, 1)
    }
}

private func piTestDate(_ value: String) -> Date {
    ISO8601DateFormatter().date(from: value) ?? .distantPast
}

private struct SessionFixture {
    let root: URL

    init() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("toki-pi-compatible-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    func writeSession(
        to file: URL,
        messageID: String,
        sessionID: String? = nil,
        model: String = "gpt-5",
        provider: String = "openai",
        input: Int,
        output: Int) throws {
        try FileManager.default.createDirectory(
            at: file.deletingLastPathComponent(),
            withIntermediateDirectories: true)
        let content = [
            sessionLine(id: sessionID ?? file.deletingPathExtension().lastPathComponent),
            assistantLine(
                id: messageID,
                timestamp: "2026-08-01T12:00:00Z",
                model: model,
                provider: provider,
                input: input,
                output: output),
        ].joined(separator: "\n")
        try Data(content.utf8).write(to: file)
    }

    func remove() {
        try? FileManager.default.removeItem(at: root)
    }
}

private func sessionLine(
    id: String = "session-123",
    cwd: String = "/Users/example/Toki") -> String {
    """
    {"type":"session","version":3,"id":"\(id)","timestamp":"2026-08-01T08:00:00Z","cwd":"\(cwd)"}
    """
}

private func sessionInfoLine(name: String) -> String {
    """
    {"type":"session_info","id":"info","parentId":null,"timestamp":"2026-08-01T08:01:00Z","name":"\(name)"}
    """
}

private func assistantLine(
    id: String,
    responseID: String? = nil,
    timestamp: String,
    model: String = "gpt-5",
    provider: String? = "openai",
    input: Int,
    output: Int,
    cacheRead: Int = 0,
    cacheWrite: Int = 0,
    reasoning: Int? = nil,
    cost: Double? = nil) -> String {
    var usageFields = [
        "\"input\":\(input)",
        "\"output\":\(output)",
        "\"cacheRead\":\(cacheRead)",
        "\"cacheWrite\":\(cacheWrite)",
    ]
    if let reasoning {
        usageFields.append("\"reasoning\":\(reasoning)")
    }
    if let cost {
        usageFields.append("\"cost\":{\"total\":\(cost)}")
    }
    var messageFields = [
        "\"role\":\"assistant\"",
        "\"model\":\"\(model)\"",
        "\"usage\":{\(usageFields.joined(separator: ","))}",
    ]
    if let responseID {
        messageFields.append("\"responseId\":\"\(responseID)\"")
    }
    if let provider {
        messageFields.append("\"provider\":\"\(provider)\"")
    }
    return """
    {"type":"message","id":"\(id)","timestamp":"\(timestamp)","message":{\(messageFields.joined(separator: ","))}}
    """
}
