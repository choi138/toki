import Foundation
import XCTest
@testable import TokiUsageReaders

final class PiCompatibleReplicaEnrichmentTests: XCTestCase {
    func test_copiedMessageRetainsCostEnrichmentWithoutDoubleCounting() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("toki-pi-enrichment-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let parent = root.appendingPathComponent("parent/session.jsonl")
        let child = root.appendingPathComponent("child/session.jsonl")
        try writeSession(to: parent, input: 7, output: 5, cost: nil)
        try writeSession(to: child, input: 4, output: 3, cost: 0.25)

        let usage = try await PiReader(sessionsURLOverride: root).readUsage(
            from: replicaDate("2026-08-01T00:00:00Z"),
            to: replicaDate("2026-08-02T00:00:00Z"))

        XCTAssertEqual(usage.totalTokens, 12)
        XCTAssertEqual(usage.cost, 0.25, accuracy: 0.000_001)
        XCTAssertEqual(usage.tokenEvents.count, 1)
        XCTAssertEqual(usage.tokenEvents.first?.costIsKnown, true)
    }

    func test_idlessResponseReconcilesProviderAcrossFiles() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("toki-pi-provider-enrichment-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try writeResponseSession(
            to: root.appendingPathComponent("parent/session.jsonl"),
            provider: nil,
            input: 7,
            output: 5)
        try writeResponseSession(
            to: root.appendingPathComponent("child/session.jsonl"),
            provider: "custom-provider",
            input: 4,
            output: 3)

        let usage = try PiCompatibleReader(
            source: .pi,
            sessionRoots: [root],
            readLimits: PiCompatibleReadLimits(
                maximumFileCount: 2,
                maximumFileBytes: 10 * 1024,
                maximumLineBytes: 2 * 1024,
                maximumEventCount: 1))
            .readUsage(
                from: replicaDate("2026-08-01T00:00:00Z"),
                to: replicaDate("2026-08-02T00:00:00Z"))

        XCTAssertEqual(usage.totalTokens, 12)
        XCTAssertEqual(usage.tokenEvents.count, 1)
        XCTAssertEqual(usage.tokenEvents.first?.provider, "custom-provider")
    }

    private func writeSession(to url: URL, input: Int, output: Int, cost: Double?) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true)
        var usage = #"{"input":\#(input),"output":\#(output)"#
        if let cost {
            usage += #", "cost":{"total":\#(cost)}"#
        }
        usage += "}"
        let lines = [
            #"{"type":"session","id":"shared-session","timestamp":"2026-08-01T08:00:00Z"}"#,
            [
                #"{"type":"message","id":"shared-message","timestamp":"2026-08-01T12:00:00Z","#,
                #""message":{"role":"assistant","model":"gpt-5","provider":"openai","usage":"#,
                usage,
                "}}",
            ].joined(),
        ]
        try Data(lines.joined(separator: "\n").utf8).write(to: url)
    }

    private func writeResponseSession(
        to url: URL,
        provider: String?,
        input: Int,
        output: Int) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true)
        var messageFields = [
            #""role":"assistant""#,
            #""model":"custom-model""#,
            #""responseId":"shared-response""#,
            #""usage":{"input":\#(input),"output":\#(output)}"#,
        ]
        if let provider {
            messageFields.append(#""provider":"\#(provider)""#)
        }
        let lines = [
            #"{"type":"session","id":"shared-session","timestamp":"2026-08-01T08:00:00Z"}"#,
            #"{"type":"message","timestamp":"2026-08-01T12:00:00Z","message":{"#
                + messageFields.joined(separator: ",") + "}}",
        ]
        try Data(lines.joined(separator: "\n").utf8).write(to: url)
    }
}

private func replicaDate(_ value: String) -> Date {
    ISO8601DateFormatter().date(from: value)!
}
