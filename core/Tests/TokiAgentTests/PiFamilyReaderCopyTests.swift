import Foundation
import XCTest
@testable import TokiUsageReaders

extension PiFamilyReaderLimitTests {
    func test_idlessExactCopiesDeduplicateButReusedResponsesRemainDistinct() async throws {
        let root = copyTemporaryRoot("toki-pi-idless")
        defer { try? FileManager.default.removeItem(at: root) }
        let copied = copyIdlessMessage(
            responseID: "response-copy",
            timestamp: "2026-08-20T12:00:00Z",
            input: 3,
            output: 2)
        try copyWriteLines(
            [#"{"type":"session","id":"session-a"}"#, copied],
            to: root.appendingPathComponent("a.jsonl"))
        try copyWriteLines(
            [#"{"type":"session","id":"session-b"}"#, copied],
            to: root.appendingPathComponent("b.jsonl"))
        try copyWriteLines(
            [
                #"{"type":"session","id":"session-c"}"#,
                copyIdlessMessage(
                    responseID: "response-copy",
                    timestamp: "2026-08-20T13:00:00Z",
                    input: 7,
                    output: 4),
            ],
            to: root.appendingPathComponent("c.jsonl"))

        let usage = try await PiReader(sessionsURLOverride: root).readUsage(
            from: copyDate("2026-08-20T00:00:00Z"),
            to: copyDate("2026-08-21T00:00:00Z"))

        XCTAssertEqual(usage.totalTokens, 16)
        XCTAssertEqual(usage.tokenEvents.count, 2)
    }

    func test_copiedResponseKeepsOriginalIdentityAfterEnrichment() async throws {
        let root = copyTemporaryRoot("toki-pi-copy-enrichment")
        defer { try? FileManager.default.removeItem(at: root) }
        let original = copyIdlessMessage(
            responseID: "response-copy",
            timestamp: "2026-08-20T12:00:00Z",
            input: 3,
            output: 2)
        let enriched = """
        {"type":"message","timestamp":"2026-08-20T12:00:01Z","message":\
        {"role":"assistant","responseId":"response-copy","model":"gpt-5",\
        "provider":"azure","usage":{"input":3,"output":2,"cost":{"total":0.25}}}}
        """
        try copyWriteLines(
            [#"{"type":"session","id":"session-a"}"#, original],
            to: root.appendingPathComponent("a.jsonl"))
        try copyWriteLines(
            [#"{"type":"session","id":"session-b"}"#, original, enriched],
            to: root.appendingPathComponent("b.jsonl"))

        let usage = try await PiReader(sessionsURLOverride: root).readUsage(
            from: copyDate("2026-08-20T00:00:00Z"),
            to: copyDate("2026-08-21T00:00:00Z"))

        XCTAssertEqual(usage.totalTokens, 5)
        XCTAssertEqual(usage.tokenEvents.count, 1)
        XCTAssertEqual(usage.cost, 0.25, accuracy: 0.000001)
        XCTAssertEqual(usage.tokenEvents.first?.provider, "azure")
    }

    func test_sameResponseIdentityWithDifferentPayloadsRemainsDistinct() async throws {
        let root = copyTemporaryRoot("toki-pi-copy-payload")
        defer { try? FileManager.default.removeItem(at: root) }
        try copyWriteLines(
            [
                #"{"type":"session","id":"session-a"}"#,
                copyIdlessMessage(
                    responseID: "response-reused",
                    timestamp: "2026-08-20T12:00:00Z",
                    input: 3,
                    output: 2),
            ],
            to: root.appendingPathComponent("a.jsonl"))
        try copyWriteLines(
            [
                #"{"type":"session","id":"session-b"}"#,
                copyIdlessMessage(
                    responseID: "response-reused",
                    timestamp: "2026-08-20T12:00:00Z",
                    input: 7,
                    output: 4),
            ],
            to: root.appendingPathComponent("b.jsonl"))

        let usage = try await PiReader(sessionsURLOverride: root).readUsage(
            from: copyDate("2026-08-20T00:00:00Z"),
            to: copyDate("2026-08-21T00:00:00Z"))

        XCTAssertEqual(usage.totalTokens, 16)
        XCTAssertEqual(usage.tokenEvents.count, 2)
    }
}

private func copyDate(_ value: String) -> Date {
    ISO8601DateFormatter().date(from: value) ?? .distantPast
}

private func copyTemporaryRoot(_ prefix: String) -> URL {
    FileManager.default.temporaryDirectory
        .appendingPathComponent("\(prefix)-\(UUID().uuidString)", isDirectory: true)
}

private func copyIdlessMessage(
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

private func copyWriteLines(_ lines: [String], to url: URL) throws {
    try FileManager.default.createDirectory(
        at: url.deletingLastPathComponent(),
        withIntermediateDirectories: true)
    try Data(lines.joined(separator: "\n").utf8).write(to: url)
}
