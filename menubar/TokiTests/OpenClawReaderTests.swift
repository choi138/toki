import Foundation
import TokiUsageCore
import XCTest
@testable import Toki
@testable import TokiUsageReaders

final class OpenClawReaderTests: XCTestCase {
    func test_openClawReader_requiresTimestampInsideRangeForUsageRows() {
        let usage = OpenClawReader.usage(
            fromJSONLLines: [
                openClawAssistantLine(input: 100, output: 20),
                openClawAssistantLine(timestamp: "2026-04-09T23:59:59Z", input: 200, output: 30),
                openClawAssistantLine(timestamp: "2026-04-10T12:00:00Z", input: 300, output: 40),
                openClawAssistantLine(createdAt: "2026-04-10T13:00:00Z", input: 400, output: 50),
                openClawAssistantLine(timestamp: "2026-04-11T00:00:00Z", input: 500, output: 60),
            ],
            streamID: "openclaw-session",
            from: tokiTestISODate("2026-04-10T00:00:00Z"),
            to: tokiTestISODate("2026-04-11T00:00:00Z"))

        XCTAssertEqual(usage.inputTokens, 700)
        XCTAssertEqual(usage.outputTokens, 90)
        XCTAssertEqual(usage.tokenEvents.map(\.totalTokens), [340, 450])
        XCTAssertEqual(
            usage.tokenEvents.map(\.timestamp),
            [
                tokiTestISODate("2026-04-10T12:00:00Z"),
                tokiTestISODate("2026-04-10T13:00:00Z"),
            ])
    }

    /// Model-less OpenClaw usage needs a per-model row or it is dropped from the model
    /// breakdown as soon as another source reports the same mixed/unattributed key.
    func test_openClawReader_recordsUnattributedUsageUnderTheMixedModelKey() throws {
        let usage = OpenClawReader.usage(
            fromJSONLLines: [
                openClawAssistantLine(timestamp: "2026-04-10T12:00:00Z", input: 300, output: 40),
                openClawAssistantLine(createdAt: "2026-04-10T13:00:00Z", input: 400, output: 50),
            ],
            streamID: "openclaw-session",
            from: tokiTestISODate("2026-04-10T00:00:00Z"),
            to: tokiTestISODate("2026-04-11T00:00:00Z"))

        let modelUsage = try XCTUnwrap(usage.perModel[UsageModelGrouping.mixedOrUnattributedKey])

        XCTAssertEqual(modelUsage.totalTokens, usage.totalTokens)
        XCTAssertEqual(modelUsage.sources, ["OpenClaw"])
    }

    /// The per-model row must carry the observed active time too. Attributing activity to the
    /// mixed key is what keeps it there: an authoritative row without active time replaces the
    /// event-derived estimate and silently reports zero elapsed time for the source.
    func test_openClawReader_attributesActiveTimeToTheMixedModelKey() throws {
        let start = tokiTestISODate("2026-04-10T00:00:00Z")
        let end = tokiTestISODate("2026-04-11T00:00:00Z")
        let usage = OpenClawReader.usage(
            fromJSONLLines: [
                openClawAssistantLine(timestamp: "2026-04-10T12:00:00Z", input: 300, output: 40),
                openClawAssistantLine(timestamp: "2026-04-10T12:01:00Z", input: 400, output: 50),
            ],
            streamID: "openclaw-session",
            from: start,
            to: end)

        let modelUsage = try XCTUnwrap(usage.perModel[UsageModelGrouping.mixedOrUnattributedKey])
        let row = try XCTUnwrap(UsageReportBuilder.buildModelStats(
            from: usage,
            startDate: start,
            endDate: end)
            .first { $0.modelID == UsageModelGrouping.mixedOrUnattributedKey })

        XCTAssertGreaterThan(usage.activeSeconds, 0)
        XCTAssertEqual(modelUsage.activeSeconds, usage.activeSeconds, accuracy: 0.001)
        XCTAssertEqual(row.activeSeconds, usage.activeSeconds, accuracy: 0.001)
        XCTAssertGreaterThan(row.wallClockSeconds, 0)
    }

    /// Synthetic nested envelope derived from the pinned upstream OpenClaw parser.
    /// This exercises the public reader through the native model-report consumer.
    func test_openClawReader_nestedModelAndUnknownPriceReachReportRows() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("toki-openclaw-report-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let sessions = root.appendingPathComponent("main/sessions")
        try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
        let lines = [
            #"{"type":"message","id":"priced","message":{"role":"assistant","model":"claude-opus-4-6","#
                + #""provider":"anthropic","timestamp":"2026-04-10T12:00:00Z","usage":{"input":100,"output":50,"#
                + #""reasoningTokens":20,"cost":{"total":0.25}}}}"#,
            #"{"type":"message","id":"unknown","message":{"role":"assistant","model":"fixture-unpriced-model","#
                + #""timestamp":"2026-04-10T12:01:00Z","usage":{"input":7,"output":3}}}"#,
        ]
        try Data(lines.joined(separator: "\n").utf8).write(to: sessions.appendingPathComponent("session.jsonl"))
        let start = tokiTestISODate("2026-04-10T00:00:00Z")
        let end = tokiTestISODate("2026-04-11T00:00:00Z")
        let usage = try await OpenClawReader(agentsURLOverride: root).readUsage(from: start, to: end)
        let rows = UsageReportBuilder.buildModelStats(from: usage, startDate: start, endDate: end)
        let known = try XCTUnwrap(rows.first { $0.modelID == "claude-opus-4-6" })
        let unknown = try XCTUnwrap(rows.first { $0.modelID == "fixture-unpriced-model" })
        XCTAssertEqual(known.totalTokens, 150)
        XCTAssertEqual(known.cost, 0.25, accuracy: 0.000001)
        XCTAssertEqual(known.providers, ["anthropic"])
        XCTAssertTrue(known.isPriceKnown)
        XCTAssertGreaterThan(known.activeSeconds, 0)
        XCTAssertGreaterThan(known.wallClockSeconds, 0)
        XCTAssertEqual(unknown.totalTokens, 10)
        XCTAssertFalse(unknown.isPriceKnown)
        XCTAssertEqual(rows.reduce(0) { $0 + $1.totalTokens }, usage.totalTokens)
        XCTAssertFalse(rows.contains { $0.modelID == UsageModelGrouping.mixedOrUnattributedKey })
    }
}

private func openClawAssistantLine(
    timestamp: String? = nil,
    createdAt: String? = nil,
    input: Int,
    output: Int) -> String {
    var fields = [#""role":"assistant""#]
    if let timestamp {
        fields.append(#""timestamp":"\#(timestamp)""#)
    }
    if let createdAt {
        fields.append(#""created_at":"\#(createdAt)""#)
    }
    fields.append(#""usage":{"input_tokens":\#(input),"output_tokens":\#(output)}"#)
    return "{\(fields.joined(separator: ","))}"
}
