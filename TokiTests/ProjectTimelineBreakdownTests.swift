import XCTest
@testable import Toki

final class ProjectTimelineBreakdownTests: XCTestCase {
    private let startDate = tokiTestISODate("2026-04-10T00:00:00Z")
    private let endDate = tokiTestISODate("2026-04-11T00:00:00Z")

    func test_noProjectsAndNoUsage_hasNoBreakdown() {
        let usage = makeUsage(projectStats: [], totalTokens: 0, cost: 0)
        let breakdown = ProjectTimelineBreakdown.derive(from: usage)
        XCTAssertTrue(breakdown.visibleProjects.isEmpty)
        XCTAssertNil(breakdown.otherProjects)
        XCTAssertNil(breakdown.untrackedUsage)
    }

    func test_upToLimitProjects_noOtherProjects() {
        let stats = (0..<4).map { makeStat(name: "p\($0)", quality: .exact, tokens: 100, cost: 1.0) }
        let usage = makeUsage(projectStats: stats, totalTokens: 400, cost: 4.0)
        let breakdown = ProjectTimelineBreakdown.derive(from: usage)
        XCTAssertEqual(breakdown.visibleProjects.count, 4)
        XCTAssertNil(breakdown.otherProjects)
        XCTAssertNil(breakdown.untrackedUsage)
    }

    func test_moreThanLimitProjects_collapsesRemainderIntoOtherProjects() throws {
        let stats = (0..<7).map { makeStat(name: "p\($0)", quality: .exact, tokens: 100, cost: 1.0) }
        let usage = makeUsage(projectStats: stats, totalTokens: 700, cost: 7.0)
        let breakdown = ProjectTimelineBreakdown.derive(from: usage)
        XCTAssertEqual(breakdown.visibleProjects.count, 4)
        let other = try XCTUnwrap(breakdown.otherProjects)
        XCTAssertEqual(other.totalTokens, 300)
        XCTAssertEqual(other.cost, 3.0, accuracy: 0.0001)
        XCTAssertTrue(other.detail.contains("3 projects"))
        XCTAssertNil(breakdown.untrackedUsage)
    }

    func test_usageBeyondAttributedProjects_surfacesAsUntracked() throws {
        let stats = [makeStat(name: "p0", quality: .exact, tokens: 100, cost: 1.0)]
        let usage = makeUsage(projectStats: stats, totalTokens: 350, cost: 3.5)
        let breakdown = ProjectTimelineBreakdown.derive(from: usage)
        XCTAssertEqual(breakdown.visibleProjects.count, 1)
        XCTAssertNil(breakdown.otherProjects)
        let untracked = try XCTUnwrap(breakdown.untrackedUsage)
        XCTAssertEqual(untracked.totalTokens, 250)
        XCTAssertEqual(untracked.cost, 2.5, accuracy: 0.0001)
        XCTAssertEqual(untracked.detail, "No project event data")
    }

    func test_unknownQualityProjects_surfaceAsUntracked() throws {
        let exact = makeStat(name: "p0", quality: .exact, tokens: 100, cost: 1.0)
        let untrackedProject = makeStat(
            name: "Unknown Project",
            quality: .unknown,
            tokens: 200,
            cost: 2.0,
            sessionCount: 2)
        let usage = makeUsage(projectStats: [exact, untrackedProject], totalTokens: 300, cost: 3.0)
        let breakdown = ProjectTimelineBreakdown.derive(from: usage)

        XCTAssertEqual(breakdown.visibleProjects.map(\.name), ["p0"])
        XCTAssertNil(breakdown.otherProjects)
        let untracked = try XCTUnwrap(breakdown.untrackedUsage)
        XCTAssertEqual(untracked.totalTokens, 200)
        XCTAssertEqual(untracked.cost, 2.0, accuracy: 0.0001)
        XCTAssertTrue(untracked.detail.contains("1 project"))
        XCTAssertTrue(untracked.detail.contains("2 sessions"))
    }

    func test_attributedPlusUntrackedReconcilesToTotal() {
        let exact = makeStat(name: "p0", quality: .exact, tokens: 100, cost: 1.0)
        let usage = makeUsage(projectStats: [exact], totalTokens: 450, cost: 4.5)
        let breakdown = ProjectTimelineBreakdown.derive(from: usage)
        let attributedTokens = breakdown.visibleProjects.reduce(0) { $0 + $1.totalTokens }
            + (breakdown.otherProjects?.totalTokens ?? 0)
        let totalTokens = attributedTokens + (breakdown.untrackedUsage?.totalTokens ?? 0)
        XCTAssertEqual(totalTokens, usage.totalTokens)
    }

    // MARK: - Helpers

    private func makeUsage(
        projectStats: [ProjectUsageStat],
        totalTokens: Int,
        cost: Double) -> UsageData {
        UsageData(
            date: startDate,
            endDate: endDate,
            inputTokens: totalTokens,
            outputTokens: 0,
            cacheReadTokens: 0,
            cacheWriteTokens: 0,
            reasoningTokens: 0,
            cost: cost,
            activeSeconds: 0,
            perModel: [],
            projectStats: projectStats)
    }

    private func makeStat(
        name: String,
        quality: AttributionQuality,
        tokens: Int,
        cost: Double,
        sessionCount: Int = 1) -> ProjectUsageStat {
        ProjectUsageStat(
            id: name,
            name: name,
            path: nil,
            quality: quality,
            sources: ["Codex"],
            sessionCount: sessionCount,
            inputTokens: tokens,
            outputTokens: 0,
            cacheReadTokens: 0,
            cacheWriteTokens: 0,
            reasoningTokens: 0,
            cost: cost,
            firstActivityAt: nil,
            lastActivityAt: nil)
    }
}
