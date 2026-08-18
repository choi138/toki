import Foundation
import TokiUsageCore
import XCTest
@testable import Toki
@testable import TokiUsageReaders

/// Every reader must leave a per-model row for usage it cannot attribute to a named model.
///
/// Report building trusts authoritative per-model rows over token events whose source labels
/// disagree, so a source that contributes only events vanishes from the model breakdown as soon as
/// another source reports the same key. The row must carry active time too, otherwise it replaces
/// the event-derived estimate with zero elapsed time.
final class ReaderUnattributedModelTests: XCTestCase {
    func test_groupingKeyFoldsMissingAndBlankModelNames() {
        XCTAssertEqual(
            UsageModelGrouping.groupingKey(for: nil),
            UsageModelGrouping.mixedOrUnattributedKey)
        XCTAssertEqual(
            UsageModelGrouping.groupingKey(for: "   "),
            UsageModelGrouping.mixedOrUnattributedKey)
        XCTAssertEqual(UsageModelGrouping.groupingKey(for: "gpt-5"), "gpt-5")
    }

    func test_accumulatePerModelUsageFoldsUnnamedModelsIntoTheMixedKey() {
        var usage = RawTokenUsage()
        usage.accumulatePerModelUsage(model: nil, source: "Probe", totalTokens: 40, cost: 0.5)
        usage.accumulatePerModelUsage(model: "gpt-5", source: "Probe", totalTokens: 10)

        let mixed = usage.perModel[UsageModelGrouping.mixedOrUnattributedKey]

        XCTAssertEqual(mixed?.totalTokens, 40)
        XCTAssertEqual(mixed?.cost, 0.5)
        XCTAssertEqual(mixed?.sources, ["Probe"])
        XCTAssertEqual(usage.perModel["gpt-5"]?.totalTokens, 10)
    }

    func test_geminiLegacyFormatKeepsUnattributedUsageInModelRows() async throws {
        let base = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("toki-gemini-legacy-\(UUID().uuidString)")
        let chats = base.appendingPathComponent("session/chats")
        try FileManager.default.createDirectory(at: chats, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }

        let file = chats.appendingPathComponent("history.json")
        // The legacy format carries usageMetadata with no model name.
        try #"[{"usageMetadata":{"promptTokenCount":300,"candidatesTokenCount":40}}]"#
            .write(to: file, atomically: true, encoding: .utf8)
        let fileDate = tokiTestISODate("2026-04-10T12:00:00Z")
        try FileManager.default.setAttributes(
            [.modificationDate: fileDate],
            ofItemAtPath: file.path)

        let start = tokiTestISODate("2026-04-10T00:00:00Z")
        let end = tokiTestISODate("2026-04-11T00:00:00Z")
        let usage = try await GeminiReader(chatsBaseURLOverride: base)
            .readUsage(from: start, to: end)

        XCTAssertEqual(usage.totalTokens, 340, "legacy Gemini fixture was not picked up")

        let row = try XCTUnwrap(UsageReportBuilder.buildModelStats(
            from: usage,
            startDate: start,
            endDate: end)
            .first { $0.modelID == UsageModelGrouping.mixedOrUnattributedKey })

        XCTAssertEqual(row.totalTokens, 340)
        XCTAssertEqual(row.sources, ["Gemini CLI"])
    }
}
