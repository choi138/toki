import Foundation
import TokiUsageCore
import XCTest
@testable import TokiUsageReaders

final class PiFamilyFollowUpTests: XCTestCase {
    func test_ompDefaultProfileHonorsAgentAndConfigRelocation() {
        let home = URL(fileURLWithPath: "/tmp/toki-home")
        let agentOverride = LocalUsageReaderPaths(
            homeDirectory: home,
            environment: ["PI_CODING_AGENT_DIR": "/tmp/omp-agent"])
        let configOverride = LocalUsageReaderPaths(
            homeDirectory: home,
            environment: ["PI_CONFIG_DIR": ".custom-omp"])

        XCTAssertEqual(agentOverride.ompSessions.path, "/tmp/omp-agent/sessions")
        XCTAssertEqual(
            configOverride.ompSessions.path,
            "/tmp/toki-home/.custom-omp/agent/sessions")
    }

    func test_ompNamedProfileRelocatesAndIgnoresAgentOverride() {
        let home = URL(fileURLWithPath: "/tmp/toki-home")
        let named = LocalUsageReaderPaths(
            homeDirectory: home,
            environment: [
                "OMP_PROFILE": "work",
                "PI_CODING_AGENT_DIR": "/tmp/ignored-agent",
            ])
        let legacy = LocalUsageReaderPaths(
            homeDirectory: home,
            environment: ["PI_PROFILE": "legacy"])
        let explicitDefault = LocalUsageReaderPaths(
            homeDirectory: home,
            environment: [
                "OMP_PROFILE": "",
                "PI_PROFILE": "ignored",
            ])

        XCTAssertEqual(
            named.ompSessions.path,
            "/tmp/toki-home/.omp/profiles/work/agent/sessions")
        XCTAssertEqual(
            legacy.ompSessions.path,
            "/tmp/toki-home/.omp/profiles/legacy/agent/sessions")
        XCTAssertEqual(
            explicitDefault.ompSessions.path,
            "/tmp/toki-home/.omp/agent/sessions")
    }

    func test_sharedPiAndOMPDirectoryRegistersOnlyOMPReader() {
        let readers = LocalUsageReaderRegistry.readers(
            home: URL(fileURLWithPath: "/tmp/toki-home"),
            environment: ["PI_CODING_AGENT_DIR": "/tmp/shared-agent"])
        let familyNames = readers.map(\.name).filter {
            [PiReader.sourceName, OMPReader.sourceName, KimchiReader.sourceName].contains($0)
        }

        XCTAssertEqual(familyNames, [OMPReader.sourceName, KimchiReader.sourceName])
    }

    func test_recordedZeroAndInvalidNegativeCostRemainDistinct() {
        let zero = KimchiReader.usage(
            fromJSONLLines: [
                #"{"type":"session","id":"kimchi-zero"}"#,
                costMessage(id: "zero", total: "0"),
            ],
            streamID: "kimchi-zero",
            from: date("2026-08-20T00:00:00Z"),
            to: date("2026-08-21T00:00:00Z"))
        let negative = KimchiReader.usage(
            fromJSONLLines: [
                #"{"type":"session","id":"kimchi-negative"}"#,
                costMessage(id: "negative", total: "-0.01"),
            ],
            streamID: "kimchi-negative",
            from: date("2026-08-20T00:00:00Z"),
            to: date("2026-08-21T00:00:00Z"))

        XCTAssertEqual(zero.tokenEvents.first?.cost, 0)
        XCTAssertEqual(zero.tokenEvents.first?.costIsKnown, true)
        XCTAssertEqual(negative.tokenEvents.first?.cost, 0)
        XCTAssertEqual(negative.tokenEvents.first?.costIsKnown, false)
    }

    func test_revisionMergePreservesFallbackProviderAndKnownCostInBothOrders() {
        let larger = usageRecord(
            inputTokens: 100,
            provider: nil,
            cost: 0,
            costIsKnown: false)
        let enriched = usageRecord(
            inputTokens: 90,
            provider: "openai",
            cost: 0.25,
            costIsKnown: true)

        for merged in [larger.merged(with: enriched), enriched.merged(with: larger)] {
            XCTAssertEqual(merged.inputTokens, 100)
            XCTAssertEqual(merged.provider, "openai")
            XCTAssertEqual(merged.cost, 0.25, accuracy: 0.000001)
            XCTAssertTrue(merged.costIsKnown)
        }
    }

    func test_idlessRevisionMetadataEnrichmentMergesOneResponse() {
        let usage = PiReader.usage(
            fromJSONLLines: [
                #"{"type":"session","id":"revision-session"}"#,
                """
                {"type":"message","timestamp":"2026-08-20T12:00:00Z","message":\
                {"role":"assistant","responseId":"revision-response","model":"gpt-5",\
                "usage":{"input":7,"output":3}}}
                """,
                """
                {"type":"message","timestamp":"2026-08-20T12:00:01Z","message":\
                {"role":"assistant","responseId":"revision-response","model":"gpt-5",\
                "provider":"azure","usage":{"input":7,"output":3,"cost":{"total":0.25}}}}
                """,
            ],
            streamID: "/tmp/revision.jsonl",
            from: date("2026-08-20T00:00:00Z"),
            to: date("2026-08-21T00:00:00Z"))

        XCTAssertEqual(usage.totalTokens, 10)
        XCTAssertEqual(usage.cost, 0.25, accuracy: 0.000001)
        XCTAssertEqual(usage.tokenEvents.count, 1)
        XCTAssertEqual(usage.tokenEvents.first?.provider, "azure")
    }
}

final class PiFamilyReaderLimitTests: XCTestCase {
    func test_nonUUIDMessageIDsRemainSessionLocal() async throws {
        let root = temporaryRoot("toki-pi-local-id")
        defer { try? FileManager.default.removeItem(at: root) }
        try writeSession(
            to: root.appendingPathComponent("a.jsonl"),
            sessionID: "session-a",
            messageID: "message-0001",
            input: 1,
            output: 1)
        try writeSession(
            to: root.appendingPathComponent("b.jsonl"),
            sessionID: "session-b",
            messageID: "message-0001",
            input: 9,
            output: 9)

        let usage = try await PiReader(sessionsURLOverride: root).readUsage(
            from: date("2026-08-20T00:00:00Z"),
            to: date("2026-08-21T00:00:00Z"))

        XCTAssertEqual(usage.totalTokens, 20)
        XCTAssertEqual(usage.tokenEvents.count, 2)
    }

    func test_piEventLimitCountsAcceptedRecordsBeforeDeduplication() async throws {
        let root = temporaryRoot("toki-pi-event-limit")
        defer { try? FileManager.default.removeItem(at: root) }
        let repeated = message(
            id: "550e8400-e29b-41d4-a716-446655440000",
            input: 1,
            output: 1)
        try writeLines(
            [#"{"type":"session","id":"limited-session"}"#, repeated, repeated],
            to: root.appendingPathComponent("limited.jsonl"))
        let reader = PiReader(
            sessionsURLOverride: root,
            readLimits: PiCompatibleReadLimits(
                maximumFileCount: 1,
                maximumFileBytes: 10000,
                maximumLineBytes: 1000,
                maximumEventCount: 1))

        do {
            _ = try await reader.readUsage(
                from: date("2026-08-20T00:00:00Z"),
                to: date("2026-08-21T00:00:00Z"))
            XCTFail("Expected the second accepted record to exceed the limit")
        } catch {
            XCTAssertEqual(error as? PiCompatibleReaderError, .tooManyEvents(2))
        }
    }

    func test_piFileLimitStopsAtFirstExcessFile() async throws {
        let root = temporaryRoot("toki-pi-file-limit")
        defer { try? FileManager.default.removeItem(at: root) }
        for index in 1...3 {
            try writeSession(
                to: root.appendingPathComponent("\(index).jsonl"),
                sessionID: "session-\(index)",
                messageID: "message-\(index)",
                input: 1,
                output: 1)
        }
        let reader = PiReader(
            sessionsURLOverride: root,
            readLimits: PiCompatibleReadLimits(
                maximumFileCount: 1,
                maximumFileBytes: 10000,
                maximumLineBytes: 1000,
                maximumEventCount: 10))

        do {
            _ = try await reader.readUsage(
                from: date("2026-08-20T00:00:00Z"),
                to: date("2026-08-21T00:00:00Z"))
            XCTFail("Expected bounded discovery to reject the second file")
        } catch {
            XCTAssertEqual(error as? PiCompatibleReaderError, .tooManyFiles(2))
        }
    }

    func test_idlessExactCopiesDeduplicateButReusedResponsesRemainDistinct() async throws {
        let root = temporaryRoot("toki-pi-idless")
        defer { try? FileManager.default.removeItem(at: root) }
        let copied = idlessMessage(
            responseID: "response-copy",
            timestamp: "2026-08-20T12:00:00Z",
            input: 3,
            output: 2)
        try writeLines(
            [#"{"type":"session","id":"session-a"}"#, copied],
            to: root.appendingPathComponent("a.jsonl"))
        try writeLines(
            [#"{"type":"session","id":"session-b"}"#, copied],
            to: root.appendingPathComponent("b.jsonl"))
        try writeLines(
            [
                #"{"type":"session","id":"session-c"}"#,
                idlessMessage(
                    responseID: "response-copy",
                    timestamp: "2026-08-20T13:00:00Z",
                    input: 7,
                    output: 4),
            ],
            to: root.appendingPathComponent("c.jsonl"))

        let usage = try await PiReader(sessionsURLOverride: root).readUsage(
            from: date("2026-08-20T00:00:00Z"),
            to: date("2026-08-21T00:00:00Z"))

        XCTAssertEqual(usage.totalTokens, 16)
        XCTAssertEqual(usage.tokenEvents.count, 2)
    }
}

private func date(_ value: String) -> Date {
    ISO8601DateFormatter().date(from: value) ?? .distantPast
}

private func temporaryRoot(_ prefix: String) -> URL {
    FileManager.default.temporaryDirectory
        .appendingPathComponent("\(prefix)-\(UUID().uuidString)", isDirectory: true)
}

private func costMessage(id: String, total: String) -> String {
    """
    {"type":"message","id":"\(id)","timestamp":"2026-08-20T12:00:00Z","message":\
    {"role":"assistant","model":"kimi-k2.6","provider":"kimchi-dev",\
    "usage":{"input":9,"output":6,"cost":{"total":\(total)}}}}
    """
}

private func message(id: String, input: Int, output: Int) -> String {
    """
    {"type":"message","id":"\(id)","timestamp":"2026-08-20T12:00:00Z","message":\
    {"role":"assistant","model":"gpt-5","provider":"openai",\
    "usage":{"input":\(input),"output":\(output)}}}
    """
}

private func idlessMessage(
    responseID: String,
    timestamp: String,
    input: Int,
    output: Int) -> String {
    """
    {"type":"message","timestamp":"\(timestamp)","message":\
    {"role":"assistant","responseId":"\(responseID)","model":"gpt-5",\
    "provider":"openai","usage":{"input":\(input),"output":\(output)}}}
    """
}

private func usageRecord(
    inputTokens: Int,
    provider: String?,
    cost: Double,
    costIsKnown: Bool) -> PiCompatibleUsageRecord {
    PiCompatibleUsageRecord(
        deduplicationKey: .message("shared-revision"),
        timestamp: date("2026-08-20T12:00:00Z"),
        model: "gpt-5",
        provider: provider,
        inputTokens: inputTokens,
        outputTokens: 0,
        cacheReadTokens: 0,
        cacheWriteTokens: 0,
        reasoningTokens: 0,
        cost: cost,
        costIsKnown: costIsKnown,
        attribution: UsageAttribution(sessionID: "shared-session", quality: .exact),
        agentKind: .main)
}

private func writeSession(
    to url: URL,
    sessionID: String,
    messageID: String,
    input: Int,
    output: Int) throws {
    try writeLines(
        [
            #"{"type":"session","id":"\#(sessionID)","cwd":"/tmp/project"}"#,
            message(id: messageID, input: input, output: output),
        ],
        to: url)
}

private func writeLines(_ lines: [String], to url: URL) throws {
    try FileManager.default.createDirectory(
        at: url.deletingLastPathComponent(),
        withIntermediateDirectories: true)
    try Data(lines.joined(separator: "\n").utf8).write(to: url)
}
