import Foundation
import TokiUsageCore
import XCTest
@testable import Toki

/// Covers per-source bounds on detailed model attribution: one source must not consume another
/// source's authoritative row just because the model aggregate still fits.
@MainActor
final class UsageModelSourceAttributionTests: XCTestCase {
    func test_oneSourceOverflowingItsRowRejectsDetailedAttribution() throws {
        let interval = sourceAttributionInterval
        var usage = RawTokenUsage(
            inputTokens: 100,
            perModel: [
                "shared-model": PerModelUsage(
                    totalTokens: 100,
                    sources: ["Claude Code", "Codex"]),
            ],
            perModelBySource: [
                ModelSourceUsageKey(modelID: "shared-model", source: "Codex"): PerModelUsage(
                    totalTokens: 50,
                    sources: ["Codex"]),
                ModelSourceUsageKey(modelID: "shared-model", source: "Claude Code"): PerModelUsage(
                    totalTokens: 50,
                    sources: ["Claude Code"]),
            ])
        // Codex reports 80 detailed tokens against its own 50-token row while Claude Code
        // underruns, so the model aggregate still fits within 100.
        usage.recordTokenEvent(
            timestamp: interval.start.addingTimeInterval(60),
            source: "Codex",
            model: "shared-model",
            inputTokens: 80,
            outputTokens: 0)
        usage.recordTokenEvent(
            timestamp: interval.start.addingTimeInterval(120),
            source: "Claude Code",
            model: "shared-model",
            inputTokens: 20,
            outputTokens: 0)

        let report = try XCTUnwrap(UsageReportBuilder.buildModelReports(
            from: usage,
            startDate: interval.start,
            endDate: interval.end)["shared-model"])
        let codexTokens = report.usageData.sourceStats
            .first { $0.source == "Codex" }?
            .totalTokens

        XCTAssertEqual(report.usageData.totalTokens, 100)
        XCTAssertEqual(codexTokens, 50)
        XCTAssertTrue(report.usageData.projectStats.isEmpty)
        XCTAssertFalse(report.usageData.isModelAttributionComplete)
    }

    func test_eventsWithinEverySourceRowKeepDetailedAttribution() throws {
        let interval = sourceAttributionInterval
        var usage = RawTokenUsage(
            inputTokens: 100,
            perModel: [
                "shared-model": PerModelUsage(
                    totalTokens: 100,
                    sources: ["Claude Code", "Codex"]),
            ],
            perModelBySource: [
                ModelSourceUsageKey(modelID: "shared-model", source: "Codex"): PerModelUsage(
                    totalTokens: 50,
                    sources: ["Codex"]),
                ModelSourceUsageKey(modelID: "shared-model", source: "Claude Code"): PerModelUsage(
                    totalTokens: 50,
                    sources: ["Claude Code"]),
            ])
        usage.recordTokenEvent(
            timestamp: interval.start.addingTimeInterval(60),
            source: "Codex",
            model: "shared-model",
            inputTokens: 50,
            outputTokens: 0)
        usage.recordTokenEvent(
            timestamp: interval.start.addingTimeInterval(120),
            source: "Claude Code",
            model: "shared-model",
            inputTokens: 50,
            outputTokens: 0)

        let report = try XCTUnwrap(UsageReportBuilder.buildModelReports(
            from: usage,
            startDate: interval.start,
            endDate: interval.end)["shared-model"])

        XCTAssertEqual(report.usageData.totalTokens, 100)
        XCTAssertTrue(report.usageData.isModelAttributionComplete)
        XCTAssertEqual(
            report.usageData.sourceStats.first { $0.source == "Codex" }?.totalTokens,
            50)
    }
}

private let sourceAttributionInterval = DateInterval(
    start: Date(timeIntervalSince1970: 1_750_000_000),
    duration: 86400)
