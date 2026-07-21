import TokiUsageCore
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

        let attributedCost = breakdown.visibleProjects.reduce(0) { $0 + $1.cost }
            + (breakdown.otherProjects?.cost ?? 0)
        let totalCost = attributedCost + (breakdown.untrackedUsage?.cost ?? 0)
        XCTAssertEqual(totalCost, usage.cost, accuracy: 0.0001)
    }

    func test_costOnlyGap_surfacesAsUntracked() throws {
        // Tokens fully attributed, but cost under-attributed: the cost-side
        // gap must still surface as untracked usage (not be hidden).
        let exact = makeStat(name: "p0", quality: .exact, tokens: 100, cost: 1.0)
        let usage = makeUsage(projectStats: [exact], totalTokens: 100, cost: 3.0)
        let breakdown = ProjectTimelineBreakdown.derive(from: usage)

        XCTAssertEqual(breakdown.visibleProjects.count, 1)
        XCTAssertNil(breakdown.otherProjects)
        let untracked = try XCTUnwrap(breakdown.untrackedUsage)
        XCTAssertEqual(untracked.totalTokens, 0)
        XCTAssertEqual(untracked.cost, 2.0, accuracy: 0.0001)
    }

    func test_costOnlyGap_marksIsCostOnlyAndLabelsDetail() throws {
        let exact = makeStat(name: "p0", quality: .exact, tokens: 100, cost: 1.0)
        let usage = makeUsage(projectStats: [exact], totalTokens: 100, cost: 3.0)
        let untracked = try XCTUnwrap(ProjectTimelineBreakdown.derive(from: usage).untrackedUsage)
        XCTAssertTrue(untracked.isCostOnly)
        XCTAssertEqual(untracked.detail, "Cost-only attribution gap")
    }

    func test_reconcilesWhenTokensSpreadAcrossBuckets() {
        // Tokens spread across input/output/cache/reasoning (not input-only),
        // mirroring real reader output, must still reconcile to usage.totalTokens.
        let exact = makeStat(name: "p0", quality: .exact, tokens: 100, cost: 1.0)
        let usage = makeUsage(
            projectStats: [exact],
            inputTokens: 80,
            outputTokens: 60,
            cacheReadTokens: 30,
            cacheWriteTokens: 10,
            reasoningTokens: 20,
            cost: 5.0)
        XCTAssertEqual(usage.totalTokens, 200)
        let breakdown = ProjectTimelineBreakdown.derive(from: usage)
        let attributedTokens = breakdown.visibleProjects.reduce(0) { $0 + $1.totalTokens }
            + (breakdown.otherProjects?.totalTokens ?? 0)
        let totalTokens = attributedTokens + (breakdown.untrackedUsage?.totalTokens ?? 0)
        XCTAssertEqual(totalTokens, usage.totalTokens)
        let attributedCost = breakdown.visibleProjects.reduce(0) { $0 + $1.cost }
            + (breakdown.otherProjects?.cost ?? 0)
        let totalCost = attributedCost + (breakdown.untrackedUsage?.cost ?? 0)
        XCTAssertEqual(totalCost, usage.cost, accuracy: 0.0001)
    }

    // MARK: - Helpers

    private func makeUsage(
        projectStats: [ProjectUsageStat],
        totalTokens: Int,
        cost: Double) -> UsageData {
        makeUsage(
            projectStats: projectStats,
            inputTokens: totalTokens,
            outputTokens: 0,
            cacheReadTokens: 0,
            cacheWriteTokens: 0,
            reasoningTokens: 0,
            cost: cost)
    }

    /// Builds usage with tokens spread across all buckets, mirroring real
    /// reader output (input + output + cache + reasoning), so reconciliation
    /// tests exercise the full `totalTokens` breakdown rather than input-only.
    private func makeUsage(
        projectStats: [ProjectUsageStat],
        inputTokens: Int,
        outputTokens: Int,
        cacheReadTokens: Int,
        cacheWriteTokens: Int,
        reasoningTokens: Int,
        cost: Double) -> UsageData {
        UsageData(
            date: startDate,
            endDate: endDate,
            inputTokens: inputTokens,
            outputTokens: outputTokens,
            cacheReadTokens: cacheReadTokens,
            cacheWriteTokens: cacheWriteTokens,
            reasoningTokens: reasoningTokens,
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
        // Spread tokens across input and output so totalTokens is a real sum,
        // not a single bucket; mirrors how readers populate ProjectUsageStat.
        let input = tokens / 2
        let output = tokens - input
        return ProjectUsageStat(
            id: name,
            name: name,
            path: nil,
            quality: quality,
            sources: ["Codex"],
            sessionCount: sessionCount,
            inputTokens: input,
            outputTokens: output,
            cacheReadTokens: 0,
            cacheWriteTokens: 0,
            reasoningTokens: 0,
            cost: cost,
            firstActivityAt: nil,
            lastActivityAt: nil)
    }
}
