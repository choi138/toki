import TokiUsageCore
import XCTest
@testable import Toki

final class UsageProjectTimelineReportTests: XCTestCase {
    func test_usageReportBuildsProjectAndSessionStats() {
        let startDate = tokiTestISODate("2026-04-10T00:00:00Z")
        let endDate = tokiTestISODate("2026-04-11T00:00:00Z")
        var rawUsage = RawTokenUsage()
        rawUsage.inputTokens = 120
        rawUsage.outputTokens = 40
        rawUsage.recordTokenEvent(
            timestamp: tokiTestISODate("2026-04-10T10:00:00Z"),
            source: "Codex",
            model: "gpt-5.4",
            inputTokens: 100,
            outputTokens: 30,
            cost: 0.20,
            attribution: UsageAttribution(
                projectPath: "/Users/example/Toki",
                sessionID: "session-a",
                quality: .exact))
        rawUsage.recordTokenEvent(
            timestamp: tokiTestISODate("2026-04-10T10:05:00Z"),
            source: "Claude Code",
            model: "claude-sonnet-4-6",
            inputTokens: 20,
            outputTokens: 10,
            cost: 0.10,
            attribution: UsageAttribution(
                projectPath: "/Users/example/Toki",
                sessionID: "session-b",
                quality: .inferred))

        let report = UsageReportBuilder.report(
            from: rawUsage,
            date: startDate,
            endDate: endDate,
            sourceStats: [])

        XCTAssertEqual(report.projectStats.count, 1)
        XCTAssertEqual(report.projectStats.first?.name, "Toki")
        XCTAssertEqual(report.projectStats.first?.totalTokens, 160)
        XCTAssertEqual(report.projectStats.first?.sessionCount, 2)
        XCTAssertEqual(report.projectStats.first?.quality, .exact)
        XCTAssertEqual(report.sessionStats.map(\.sessionID), ["session-a", "session-b"])
        XCTAssertEqual(report.sessionStats.first?.projectName, "Toki")
        XCTAssertEqual(report.attributedCost, 0.30, accuracy: 0.000001)
    }

    func test_usageReportUsesUniqueIDsForPathlessProjectStats() {
        let startDate = tokiTestISODate("2026-04-10T00:00:00Z")
        let endDate = tokiTestISODate("2026-04-11T00:00:00Z")
        var rawUsage = RawTokenUsage()
        rawUsage.inputTokens = 30
        rawUsage.recordTokenEvent(
            timestamp: tokiTestISODate("2026-04-10T10:00:00Z"),
            source: "Claude Code",
            model: "claude-sonnet-4-6",
            inputTokens: 10,
            outputTokens: 0,
            attribution: UsageAttribution(
                projectName: "Users-me-my-app",
                sessionID: "session-a",
                quality: .inferred))
        rawUsage.recordTokenEvent(
            timestamp: tokiTestISODate("2026-04-10T11:00:00Z"),
            source: "Claude Code",
            model: "claude-sonnet-4-6",
            inputTokens: 20,
            outputTokens: 0,
            attribution: UsageAttribution(
                projectName: "Users-me-other-app",
                sessionID: "session-b",
                quality: .inferred))

        let report = UsageReportBuilder.report(
            from: rawUsage,
            date: startDate,
            endDate: endDate,
            sourceStats: [])

        XCTAssertEqual(report.projectStats.count, 2)
        XCTAssertEqual(Set(report.projectStats.map(\.id)).count, 2)
        XCTAssertTrue(report.projectStats.allSatisfy { $0.path == nil })
    }

    func test_usageReportRefreshesSessionMetadataWhenAttributionImproves() {
        let startDate = tokiTestISODate("2026-04-10T00:00:00Z")
        let endDate = tokiTestISODate("2026-04-11T00:00:00Z")
        var rawUsage = RawTokenUsage()
        rawUsage.inputTokens = 30
        rawUsage.recordTokenEvent(
            timestamp: tokiTestISODate("2026-04-10T10:00:00Z"),
            source: "Codex",
            model: "gpt-5.4",
            inputTokens: 10,
            outputTokens: 0,
            attribution: UsageAttribution(
                sessionID: "session-a",
                quality: .unknown))
        rawUsage.recordTokenEvent(
            timestamp: tokiTestISODate("2026-04-10T10:05:00Z"),
            source: "Codex",
            model: "gpt-5.4",
            inputTokens: 20,
            outputTokens: 0,
            attribution: UsageAttribution(
                projectPath: "/Users/example/Toki",
                sessionID: "session-a",
                quality: .exact))

        let report = UsageReportBuilder.report(
            from: rawUsage,
            date: startDate,
            endDate: endDate,
            sourceStats: [])

        XCTAssertEqual(report.sessionStats.count, 1)
        XCTAssertEqual(report.sessionStats.first?.projectName, "Toki")
        XCTAssertEqual(report.sessionStats.first?.projectPath, "/Users/example/Toki")
        XCTAssertEqual(report.sessionStats.first?.quality, .exact)
        XCTAssertEqual(report.projectStats.count, 1)
        XCTAssertEqual(report.projectStats.first?.name, "Toki")
        XCTAssertEqual(report.projectStats.first?.totalTokens, 30)
    }

    func test_usageReportNamespacesProjectSessionCountsBySource() {
        let startDate = tokiTestISODate("2026-04-10T00:00:00Z")
        let endDate = tokiTestISODate("2026-04-11T00:00:00Z")
        var rawUsage = RawTokenUsage()
        rawUsage.inputTokens = 30
        rawUsage.recordTokenEvent(
            timestamp: tokiTestISODate("2026-04-10T10:00:00Z"),
            source: "Codex",
            model: "gpt-5.4",
            inputTokens: 10,
            outputTokens: 0,
            attribution: UsageAttribution(
                projectPath: "/Users/example/Toki",
                sessionID: "session-a",
                quality: .exact))
        rawUsage.recordTokenEvent(
            timestamp: tokiTestISODate("2026-04-10T10:05:00Z"),
            source: "Claude Code",
            model: "claude-sonnet-4-6",
            inputTokens: 20,
            outputTokens: 0,
            attribution: UsageAttribution(
                projectPath: "/Users/example/Toki",
                sessionID: "session-a",
                quality: .exact))

        let report = UsageReportBuilder.report(
            from: rawUsage,
            date: startDate,
            endDate: endDate,
            sourceStats: [])

        XCTAssertEqual(report.projectStats.count, 1)
        XCTAssertEqual(report.projectStats.first?.sessionCount, 2)
    }
}
