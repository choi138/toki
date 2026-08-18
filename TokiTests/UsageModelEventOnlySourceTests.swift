import Foundation
import TokiUsageCore
import XCTest
@testable import Toki

/// Guards the model breakdown against losing a source that reports usage without naming a model.
///
/// `buildModelStats` deliberately trusts authoritative `perModelBySource` rows over token events
/// whose source labels disagree, so a source that contributes only events disappears once another
/// source maps the same model key. The fix keeps that policy and instead has such readers record a
/// per-model row, which is what this file pins.
@MainActor
final class UsageModelEventOnlySourceTests: XCTestCase {
    func test_unattributedSourceKeepsItsRowWhenAnotherSourceMapsTheSameKey() {
        let interval = eventOnlyInterval
        let key = UsageModelGrouping.mixedOrUnattributedKey
        var usage = RawTokenUsage(
            inputTokens: 130,
            perModel: [
                key: PerModelUsage(totalTokens: 100, sources: ["Hermes"]),
            ],
            perModelBySource: [
                ModelSourceUsageKey(modelID: key, source: "Hermes"): PerModelUsage(
                    totalTokens: 100,
                    sources: ["Hermes"]),
                // The row an unattributed reader now contributes for itself.
                ModelSourceUsageKey(modelID: key, source: "OpenClaw"): PerModelUsage(
                    totalTokens: 30,
                    sources: ["OpenClaw"]),
            ])
        usage.recordTokenEvent(
            timestamp: interval.start.addingTimeInterval(60),
            source: "OpenClaw",
            model: nil,
            inputTokens: 30,
            outputTokens: 0)

        let rows = UsageReportBuilder.buildModelStats(
            from: usage,
            startDate: interval.start,
            endDate: interval.end)
            .filter { $0.modelID == key }

        XCTAssertEqual(Set(rows.flatMap(\.sources)), ["Hermes", "OpenClaw"])
        XCTAssertEqual(rows.reduce(0) { $0 + $1.totalTokens }, 130)
    }

    func test_unattributedSourceRowSurvivesIntoTheModelReport() throws {
        let interval = eventOnlyInterval
        let key = UsageModelGrouping.mixedOrUnattributedKey
        var usage = RawTokenUsage(
            inputTokens: 130,
            perModel: [
                key: PerModelUsage(totalTokens: 130, sources: ["Hermes", "OpenClaw"]),
            ],
            perModelBySource: [
                ModelSourceUsageKey(modelID: key, source: "Hermes"): PerModelUsage(
                    totalTokens: 100,
                    sources: ["Hermes"]),
                ModelSourceUsageKey(modelID: key, source: "OpenClaw"): PerModelUsage(
                    totalTokens: 30,
                    sources: ["OpenClaw"]),
            ])
        usage.recordTokenEvent(
            timestamp: interval.start.addingTimeInterval(60),
            source: "OpenClaw",
            model: nil,
            inputTokens: 30,
            outputTokens: 0)

        let report = try XCTUnwrap(UsageReportBuilder.buildModelReports(
            from: usage,
            startDate: interval.start,
            endDate: interval.end)[key])

        XCTAssertEqual(report.usageData.totalTokens, 130)
        XCTAssertEqual(
            Set(report.usageData.sourceStats.map(\.source)),
            ["Hermes", "OpenClaw"])
    }

    /// Regression guard for the policy the reader fix deliberately preserves: events whose source
    /// disagrees with the authoritative row must not add a second row.
    func test_mismatchedEventSourceStillDefersToTheAuthoritativeRow() {
        let interval = eventOnlyInterval
        var usage = RawTokenUsage(
            inputTokens: 50,
            perModel: [
                "shared-model": PerModelUsage(totalTokens: 50, sources: ["Codex"]),
            ],
            perModelBySource: [
                ModelSourceUsageKey(modelID: "shared-model", source: "Codex"): PerModelUsage(
                    totalTokens: 50,
                    sources: ["Codex"]),
            ])
        usage.recordTokenEvent(
            timestamp: interval.start.addingTimeInterval(60),
            source: "Claude Code",
            model: "shared-model",
            inputTokens: 50,
            outputTokens: 0)

        let rows = UsageReportBuilder.buildModelStats(
            from: usage,
            startDate: interval.start,
            endDate: interval.end)
            .filter { $0.modelID == "shared-model" }

        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows.reduce(0) { $0 + $1.totalTokens }, 50)
        XCTAssertEqual(rows.first?.sources, ["Codex"])
    }
}

private let eventOnlyInterval = DateInterval(
    start: Date(timeIntervalSince1970: 1_750_000_000),
    duration: 86400)
