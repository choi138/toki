import Foundation

/// Pure, SwiftUI-free derivation of the project timeline breakdown.
///
/// "Attributed" matches `UsageData.attributedCost`: project rows whose
/// `quality` is not `.unknown`. "Untracked" is everything else, so the two
/// are complementary:
///
///     attributed.tokens + untracked.tokens == usage.totalTokens
///     attributed.cost   + untracked.cost   == usage.cost
struct ProjectTimelineBreakdown {
    let visibleProjects: [ProjectUsageStat]
    let otherProjects: ProjectUsageSummaryValues?
    let untrackedUsage: ProjectUsageSummaryValues?

    /// Maximum number of project rows shown individually before collapsing
    /// the remainder into "Other Projects".
    static let visibleProjectLimit = 4
}

struct ProjectUsageSummaryValues: Equatable {
    let title: String
    let detail: String
    let totalTokens: Int
    let cost: Double
}

extension ProjectTimelineBreakdown {
    static func derive(from usage: UsageData) -> ProjectTimelineBreakdown {
        let attributed = usage.projectStats.filter { $0.quality != .unknown }
        let visible = Array(attributed.prefix(visibleProjectLimit))
        let hidden = Array(attributed.dropFirst(visibleProjectLimit))

        return ProjectTimelineBreakdown(
            visibleProjects: visible,
            otherProjects: otherProjectsSummary(from: hidden),
            untrackedUsage: untrackedUsageSummary(
                usage: usage,
                attributed: attributed))
    }

    private static func otherProjectsSummary(
        from hidden: [ProjectUsageStat]) -> ProjectUsageSummaryValues? {
        guard !hidden.isEmpty else { return nil }
        let totalTokens = hidden.reduce(0) { $0 + $1.totalTokens }
        let cost = hidden.reduce(0) { $0 + $1.cost }
        guard totalTokens > 0 || cost > 0 else { return nil }
        let sessionCount = hidden.reduce(0) { $0 + $1.sessionCount }
        return ProjectUsageSummaryValues(
            title: "Other Projects",
            detail: countDetail(projectCount: hidden.count, sessionCount: sessionCount),
            totalTokens: totalTokens,
            cost: cost)
    }

    private static func untrackedUsageSummary(
        usage: UsageData,
        attributed: [ProjectUsageStat]) -> ProjectUsageSummaryValues? {
        let attributedTokens = attributed.reduce(0) { $0 + $1.totalTokens }
        let attributedCost = attributed.reduce(0) { $0 + $1.cost }
        let untrackedTokens = max(0, usage.totalTokens - attributedTokens)
        guard untrackedTokens > 0 else { return nil }

        let untrackedProjects = usage.projectStats.filter { $0.quality == .unknown }
        let detail: String
        if untrackedProjects.isEmpty {
            detail = "No project event data"
        } else {
            let sessionCount = untrackedProjects.reduce(0) { $0 + $1.sessionCount }
            detail = countDetail(
                projectCount: untrackedProjects.count,
                sessionCount: sessionCount)
        }

        return ProjectUsageSummaryValues(
            title: "Untracked Usage",
            detail: detail,
            totalTokens: untrackedTokens,
            cost: max(0, usage.cost - attributedCost))
    }

    private static func countDetail(projectCount: Int, sessionCount: Int) -> String {
        "\(formattedCount(projectCount, singular: "project")) · \(formattedCount(sessionCount, singular: "session"))"
    }

    private static func formattedCount(_ value: Int, singular: String) -> String {
        value == 1 ? "1 \(singular)" : "\(value) \(singular)s"
    }
}
