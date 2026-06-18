import SwiftUI

struct PanelProjectTimelineView: View {
    private static let visibleProjectLimit = 4
    private static let visibleSessionLimit = 8

    let usage: UsageData
    let isLoading: Bool

    var body: some View {
        VStack(spacing: 0) {
            if isLoading {
                PanelProjectTimelineSummaryView(rows: loadingSummaryRows, isLoading: true)
                PanelSectionCaption(title: "Top Projects")
                ForEach(0..<3, id: \.self) { index in
                    PanelProjectSkeletonRow(width: CGFloat(92 + index * 8))
                }
                PanelSectionCaption(title: "Sessions")
                ForEach(0..<5, id: \.self) { index in
                    PanelProjectSkeletonRow(width: CGFloat(80 + index * 10))
                }
            } else if usage.projectStats.isEmpty, usage.sessionStats.isEmpty, untrackedUsageSummary == nil {
                Text("No project data")
                    .font(.system(size: 12))
                    .foregroundColor(Color.white.opacity(0.3))
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, 24)
            } else {
                PanelProjectTimelineSummaryView(rows: summaryRows)

                if !usage.projectStats.isEmpty || untrackedUsageSummary != nil {
                    PanelSectionCaption(title: "Top Projects")
                    ForEach(visibleProjects) { project in
                        PanelProjectUsageRowView(project: project)
                            .equatable()
                    }
                    if let otherProjectsSummary {
                        PanelProjectUsageSummaryRowView(summary: otherProjectsSummary)
                    }
                    if let untrackedUsageSummary {
                        PanelProjectUsageSummaryRowView(summary: untrackedUsageSummary)
                    }
                }

                if !usage.sessionStats.isEmpty {
                    PanelSectionCaption(title: "Sessions")
                    ForEach(usage.sessionStats.prefix(Self.visibleSessionLimit)) { session in
                        PanelSessionUsageRowView(session: session)
                            .equatable()
                    }
                }
            }
        }
        .padding(.vertical, 6)
    }

    private var summaryRows: [PanelProjectTimelineSummaryRow] {
        [
            PanelProjectTimelineSummaryRow(
                label: "Top Project",
                value: topProjectLabel,
                accent: topProjectAccent),
            PanelProjectTimelineSummaryRow(
                label: "Project Total",
                value: projectTotalLabel,
                accent: Color(red: 0.4, green: 0.9, blue: 0.6)),
            PanelProjectTimelineSummaryRow(
                label: "Top Session",
                value: topSessionLabel,
                accent: Color(red: 0.45, green: 0.75, blue: 1.0)),
            PanelProjectTimelineSummaryRow(
                label: "Other Projects",
                value: otherProjectsLabel,
                accent: Color.white.opacity(0.5)),
            PanelProjectTimelineSummaryRow(
                label: "Attributed",
                value: attributedCostLabel,
                accent: Color(red: 0.4, green: 0.9, blue: 0.6)),
            PanelProjectTimelineSummaryRow(
                label: "Sessions",
                value: "\(usage.sessionStats.count)",
                accent: Color(red: 1.0, green: 0.8, blue: 0.35)),
        ]
    }

    private var loadingSummaryRows: [PanelProjectTimelineSummaryRow] {
        [
            PanelProjectTimelineSummaryRow(label: "Top Project", value: "", accent: Color.white.opacity(0.5)),
            PanelProjectTimelineSummaryRow(label: "Project Total", value: "", accent: Color.white.opacity(0.5)),
            PanelProjectTimelineSummaryRow(label: "Top Session", value: "", accent: Color.white.opacity(0.5)),
            PanelProjectTimelineSummaryRow(label: "Other Projects", value: "", accent: Color.white.opacity(0.5)),
            PanelProjectTimelineSummaryRow(label: "Attributed", value: "", accent: Color.white.opacity(0.5)),
            PanelProjectTimelineSummaryRow(label: "Sessions", value: "", accent: Color.white.opacity(0.5)),
        ]
    }

    private var visibleProjects: ArraySlice<ProjectUsageStat> {
        usage.projectStats.prefix(Self.visibleProjectLimit)
    }

    private var hiddenProjects: ArraySlice<ProjectUsageStat> {
        usage.projectStats.dropFirst(Self.visibleProjectLimit)
    }

    private var projectStatsTotalTokens: Int {
        usage.projectStats.reduce(0) { $0 + $1.totalTokens }
    }

    private var projectStatsCost: Double {
        usage.projectStats.reduce(0) { $0 + $1.cost }
    }

    private var projectTotalLabel: String {
        projectStatsTotalTokens > 0 ? projectStatsTotalTokens.formattedTokens() : "-"
    }

    private var otherProjectsLabel: String {
        guard let otherProjectsSummary else { return "-" }
        return otherProjectsSummary.totalTokens.formattedTokens()
    }

    private var topProject: ProjectUsageStat? {
        usage.projectStats.first { $0.quality != .unknown } ?? usage.projectStats.first
    }

    private var topProjectLabel: String {
        topProject?.name ?? "-"
    }

    private var topProjectAccent: Color {
        guard let source = topProject?.sources.first else { return Color.white.opacity(0.5) }
        return panelAccentColor(forSource: source)
    }

    private var topSessionLabel: String {
        guard let session = usage.sessionStats.first else { return "-" }
        return session.cost > 0 ? session.cost.formattedCost() : session.totalTokens.formattedTokens()
    }

    private var attributedCostLabel: String {
        guard usage.cost > 0 else {
            return usage.attributedSessionCount > 0 ? "\(usage.attributedSessionCount)" : "-"
        }

        let percentage = (usage.attributedCost / usage.cost * 100).rounded()
        return "\(Int(percentage))%"
    }

    private var otherProjectsSummary: ProjectUsageSummary? {
        let projects = Array(hiddenProjects)
        guard !projects.isEmpty else { return nil }

        let totalTokens = projects.reduce(0) { $0 + $1.totalTokens }
        let cost = projects.reduce(0) { $0 + $1.cost }
        let sessionCount = projects.reduce(0) { $0 + $1.sessionCount }
        guard totalTokens > 0 || cost > 0 else { return nil }

        return ProjectUsageSummary(
            title: "Other Projects",
            detail: otherProjectsDetail(
                projectCount: projects.count,
                sessionCount: sessionCount),
            totalTokens: totalTokens,
            cost: cost,
            accent: Color.white.opacity(0.5))
    }

    private var untrackedUsageSummary: ProjectUsageSummary? {
        let totalTokens = usage.totalTokens - projectStatsTotalTokens
        guard totalTokens > 0 else { return nil }

        return ProjectUsageSummary(
            title: "Untracked Usage",
            detail: "No project event data",
            totalTokens: totalTokens,
            cost: max(0, usage.cost - projectStatsCost),
            accent: Color.white.opacity(0.35))
    }

    private func otherProjectsDetail(projectCount: Int, sessionCount: Int) -> String {
        "\(projectCount.formattedCount(singular: "project")) · \(sessionCount.formattedCount(singular: "session"))"
    }
}

private struct PanelProjectTimelineSummaryRow {
    let label: String
    let value: String
    let accent: Color
}

private struct PanelProjectTimelineSummaryView: View {
    let rows: [PanelProjectTimelineSummaryRow]
    var isLoading = false

    var body: some View {
        VStack(spacing: 0) {
            PanelSectionCaption(title: "Summary")

            LazyVGrid(
                columns: [
                    GridItem(.flexible(), spacing: 10),
                    GridItem(.flexible(), spacing: 10),
                ],
                spacing: 8) {
                    ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                        HStack(alignment: .center, spacing: 6) {
                            Circle()
                                .fill(row.accent.opacity(isLoading ? 0.15 : 0.58))
                                .frame(width: 5, height: 5)
                            VStack(alignment: .leading, spacing: 3) {
                                Text(row.label)
                                    .font(.system(size: 9, weight: .semibold))
                                    .foregroundColor(Color.white.opacity(isLoading ? 0.18 : 0.28))
                                    .lineLimit(1)
                                if isLoading {
                                    SkeletonBar(width: skeletonWidth(for: row.label), height: 11)
                                } else {
                                    Text(row.value)
                                        .font(.system(size: 12, weight: .semibold, design: .rounded))
                                        .foregroundColor(Color.white.opacity(0.78))
                                        .lineLimit(1)
                                        .minimumScaleFactor(0.75)
                                }
                            }
                            Spacer(minLength: 0)
                        }
                        .frame(minHeight: 34, alignment: .leading)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.top, 2)
                .padding(.bottom, 6)
        }
    }

    private func skeletonWidth(for value: String) -> CGFloat {
        let seed = value.unicodeScalars.reduce(0) { $0 + Int($1.value) }
        return CGFloat(42 + (seed % 28))
    }
}

private struct ProjectUsageSummary {
    let title: String
    let detail: String
    let totalTokens: Int
    let cost: Double
    let accent: Color
}

private struct PanelProjectUsageSummaryRowView: View {
    let summary: ProjectUsageSummary

    var body: some View {
        HStack(alignment: .center, spacing: 6) {
            Circle()
                .fill(summary.accent.opacity(0.55))
                .frame(width: 5, height: 5)
            VStack(alignment: .leading, spacing: 3) {
                Text(summary.title)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(Color.white.opacity(0.46))
                    .lineLimit(1)
                Text(summary.detail)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundColor(Color.white.opacity(0.28))
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            Text(summary.totalTokens.formattedTokens())
                .font(.system(size: 11, weight: .semibold, design: .rounded))
                .foregroundColor(Color.white.opacity(0.64))
                .frame(width: 44, alignment: .trailing)
            Text(summary.cost > 0 ? summary.cost.formattedCost() : "-")
                .font(.system(size: 11, weight: .semibold, design: .rounded))
                .foregroundColor(summary.cost > 0 ? Color(red: 0.4, green: 0.9, blue: 0.6) : Color.white.opacity(0.25))
                .frame(width: 56, alignment: .trailing)
                .lineLimit(1)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 7)
    }
}

private struct PanelProjectUsageRowView: View, Equatable {
    let project: ProjectUsageStat

    var body: some View {
        HStack(alignment: .center, spacing: 6) {
            Circle()
                .fill(accent.opacity(0.55))
                .frame(width: 5, height: 5)
            VStack(alignment: .leading, spacing: 3) {
                Text(project.name)
                    .font(.system(size: 11))
                    .foregroundColor(Color.white.opacity(0.5))
                    .lineLimit(1)
                Text(detailText)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundColor(Color.white.opacity(0.3))
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            Text(project.totalTokens.formattedTokens())
                .font(.system(size: 11, weight: .semibold, design: .rounded))
                .foregroundColor(Color.white.opacity(0.7))
                .frame(width: 44, alignment: .trailing)
            Text(project.cost > 0 ? project.cost.formattedCost() : "-")
                .font(.system(size: 11, weight: .semibold, design: .rounded))
                .foregroundColor(project.cost > 0 ? Color(red: 0.4, green: 0.9, blue: 0.6) : Color.white.opacity(0.25))
                .frame(width: 56, alignment: .trailing)
                .lineLimit(1)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 7)
    }

    private var detailText: String {
        let sessionText = project.sessionCount == 1 ? "1 session" : "\(project.sessionCount) sessions"
        return "\(sourceLabel) · \(sessionText) · \(project.quality.rawValue)"
    }

    private var sourceLabel: String {
        if project.sources.isEmpty { return "Unknown" }
        if project.sources.count == 1 { return project.sources[0] }
        let head = project.sources.prefix(2).joined(separator: ", ")
        let remainder = project.sources.count - 2
        return remainder > 0 ? "\(head) +\(remainder)" : head
    }

    private var accent: Color {
        guard let source = project.sources.first else { return Color.white.opacity(0.5) }
        return panelAccentColor(forSource: source)
    }
}

private extension Int {
    func formattedCount(singular: String) -> String {
        self == 1 ? "1 \(singular)" : "\(self) \(singular)s"
    }
}

private struct PanelSessionUsageRowView: View, Equatable {
    let session: SessionUsageStat

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Circle()
                    .fill(panelAccentColor(forSource: session.source).opacity(0.55))
                    .frame(width: 5, height: 5)
                Text(timeRange)
                    .font(.system(size: 10, weight: .semibold, design: .rounded))
                    .foregroundColor(Color.white.opacity(0.34))
                    .frame(width: 66, alignment: .leading)
                    .lineLimit(1)
                Text(session.projectName)
                    .font(.system(size: 11))
                    .foregroundColor(Color.white.opacity(0.5))
                    .lineLimit(1)
                Spacer(minLength: 6)
                Text(session.cost > 0 ? session.cost.formattedCost() : "-")
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                    .foregroundColor(session.cost > 0 ? Color(red: 0.4, green: 0.9, blue: 0.6) : Color.white
                        .opacity(0.25))
                    .frame(width: 50, alignment: .trailing)
                    .lineLimit(1)
            }

            HStack(spacing: 6) {
                Text(session.source)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundColor(Color.white.opacity(0.3))
                    .lineLimit(1)
                Text(modelLabel)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundColor(Color.white.opacity(0.26))
                    .lineLimit(1)
                Spacer(minLength: 6)
                Text(session.totalTokens.formattedTokens())
                    .font(.system(size: 10, weight: .semibold, design: .rounded))
                    .foregroundColor(Color.white.opacity(0.58))
                    .lineLimit(1)
                Text(session.quality.rawValue)
                    .font(.system(size: 10, weight: .semibold, design: .rounded))
                    .foregroundColor(Color.white.opacity(session.quality == .unknown ? 0.24 : 0.42))
                    .lineLimit(1)
            }
            .padding(.leading, 11)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 7)
    }

    private var timeRange: String {
        let start = Self.hourFormatter.string(from: session.firstActivityAt)
        let end = Self.hourFormatter.string(from: session.lastActivityAt)
        return "\(start)-\(end)"
    }

    private var modelLabel: String {
        guard !session.models.isEmpty else { return session.sessionLabel }
        if session.models.count == 1 { return session.models[0] }
        let head = session.models.prefix(1).joined()
        return "\(head) +\(session.models.count - 1)"
    }

    private static let hourFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "HH:mm"
        return formatter
    }()
}

private struct PanelProjectSkeletonRow: View {
    let width: CGFloat

    var body: some View {
        HStack(alignment: .center, spacing: 6) {
            Circle()
                .fill(Color.white.opacity(0.08))
                .frame(width: 5, height: 5)
            VStack(alignment: .leading, spacing: 4) {
                SkeletonBar(width: width, height: 10)
                SkeletonBar(width: max(52, width - 20), height: 8)
            }
            Spacer()
            SkeletonBar(width: 36, height: 10)
            SkeletonBar(width: 38, height: 10)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 7)
    }
}
