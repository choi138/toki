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
        try writeSession(to: parent, cost: nil)
        try writeSession(to: child, cost: 0.25)

        let usage = try await PiReader(sessionsURLOverride: root).readUsage(
            from: replicaDate("2026-08-01T00:00:00Z"),
            to: replicaDate("2026-08-02T00:00:00Z"))

        XCTAssertEqual(usage.totalTokens, 12)
        XCTAssertEqual(usage.cost, 0.25, accuracy: 0.000_001)
        XCTAssertEqual(usage.tokenEvents.count, 1)
        XCTAssertEqual(usage.tokenEvents.first?.costIsKnown, true)
    }

    private func writeSession(to url: URL, cost: Double?) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true)
        var usage = #"{"input":7,"output":5"#
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
}

private func replicaDate(_ value: String) -> Date {
    ISO8601DateFormatter().date(from: value)!
}
