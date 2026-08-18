import Foundation
import SwiftUI

struct PanelModelDetailView: View {
    let presentation: PanelModelDetailPresentation

    var body: some View {
        VStack(spacing: 0) {
            PanelModelDetailHeader(presentation: presentation)
            PanelModelDetailDivider()

            ScrollView(.vertical) {
                LazyVStack(alignment: .leading, spacing: 0) {
                    if presentation.hasIncompleteAttribution,
                       let usage = presentation.report?.usageData {
                        PanelModelDetailAttributionNotice(unclassifiedTokens: usage.unclassifiedTokens)
                    }

                    if presentation.isContextOnly {
                        PanelModelDetailContextOnlyNotice()
                    }

                    if let report = presentation.report {
                        PanelModelDetailSummarySection(report: report)
                        PanelModelDetailProjectsSection(
                            projects: presentation.projects,
                            totalTokens: report.usageData.totalTokens)
                        PanelModelDetailSourcesSection(
                            sources: presentation.sources,
                            totalTokens: report.usageData.totalTokens)
                        PanelModelDetailSessionsSection(sessions: presentation.sessions)
                        PanelModelDetailActivitySection(
                            buckets: presentation.activeBuckets,
                            availability: presentation.hourlyAvailability)
                        PanelModelDetailTokenSection(
                            components: presentation.tokenComponents,
                            totalTokens: report.usageData.totalTokens)
                    }

                    if presentation.isContextOnly || !presentation.contextOnlyStats.isEmpty {
                        PanelModelDetailContextSection(stats: presentation.contextOnlyStats)
                    }
                }
                .padding(.bottom, 20)
            }
        }
        .frame(width: 460, height: 600)
        .background(Color(red: 0.09, green: 0.09, blue: 0.11))
        .preferredColorScheme(.dark)
    }
}

private struct PanelModelDetailHeader: View {
    @Environment(\.dismiss) private var dismiss

    let presentation: PanelModelDetailPresentation

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Circle()
                .fill(panelAccentColor(forModelID: presentation.modelID).opacity(0.8))
                .frame(width: 8, height: 8)
                .padding(.top, 5)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 4) {
                Text(panelModelDisplayName(presentation.modelID))
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Color.white.opacity(0.92))
                    .lineLimit(1)

                if let rawModelID = panelModelRawIdentifier(presentation.modelID) {
                    Text(rawModelID)
                        .font(.system(size: 10, weight: .medium, design: .monospaced))
                        .foregroundStyle(Color.white.opacity(0.34))
                        .lineLimit(1)
                        .truncationMode(.middle)
                }

                Text("\(presentation.scopeTitle) · \(dateRangeText)")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(Color.white.opacity(0.38))
                    .lineLimit(1)
            }

            Spacer(minLength: 12)

            Button(action: dismiss.callAsFunction) {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Color.white.opacity(0.46))
                    .frame(width: 22, height: 22)
                    .contentShape(Rectangle())
                    .accessibilityHidden(true)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text("Close model details"))
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 14)
    }

    private var dateRangeText: String {
        Self.dateRangeFormatter.string(
            from: presentation.startDate,
            to: presentation.displayEndDate)
    }

    private static let dateRangeFormatter: DateIntervalFormatter = {
        let formatter = DateIntervalFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        return formatter
    }()
}

private struct PanelModelDetailAttributionNotice: View {
    let unclassifiedTokens: Int

    var body: some View {
        PanelModelDetailNotice(
            systemImage: "exclamationmark.triangle.fill",
            title: "Some detail is partial",
            message: "Total usage is accurate. Project, session, and hourly details include only attributed usage.",
            detail: unclassifiedTokens > 0
                ? "\(unclassifiedTokens.formattedTokens()) tokens could not be tied to a detailed record."
                : nil,
            accent: Color(red: 1.0, green: 0.72, blue: 0.35))
    }
}

private struct PanelModelDetailContextOnlyNotice: View {
    var body: some View {
        PanelModelDetailNotice(
            systemImage: "info.circle.fill",
            title: "Context record only",
            message: "This is a context-window size, not measured model usage. "
                + "It is excluded from token and cost totals.",
            detail: nil,
            accent: Color(red: 0.45, green: 0.75, blue: 1.0))
    }
}

private struct PanelModelDetailNotice: View {
    let systemImage: String
    let title: String
    let message: String
    let detail: String?
    let accent: Color

    var body: some View {
        HStack(alignment: .top, spacing: 9) {
            Image(systemName: systemImage)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(accent.opacity(0.82))
                .frame(width: 14)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Color.white.opacity(0.72))
                Text(message)
                    .font(.system(size: 10))
                    .foregroundStyle(Color.white.opacity(0.46))
                    .fixedSize(horizontal: false, vertical: true)
                if let detail {
                    Text(detail)
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(accent.opacity(0.68))
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 18)
        .padding(.vertical, 11)
        .background(accent.opacity(0.055))
        .accessibilityElement(children: .combine)
    }
}

private struct PanelModelDetailSummarySection: View {
    let report: UsageModelReport

    var body: some View {
        VStack(spacing: 0) {
            PanelModelDetailSectionHeader(title: "Overview")

            HStack(spacing: 0) {
                PanelModelDetailMetric(
                    label: "Total tokens",
                    value: report.usageData.totalTokens.formattedTokens(),
                    detail: report.usageData.isModelAttributionComplete ? "Fully attributed" : "Authoritative total")
                PanelModelDetailVerticalDivider()
                PanelModelDetailMetric(
                    label: "Cost",
                    value: report.summary.panelCostSummary,
                    detail: report.summary.hasKnownPanelCost ? "Estimated spend" : "Pricing unavailable")
                PanelModelDetailVerticalDivider()
                PanelModelDetailMetric(
                    label: "Elapsed",
                    value: elapsedValue,
                    detail: elapsedDetail)
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 12)
            .background(Color.white.opacity(0.025))
        }
    }

    private var elapsedValue: String {
        guard report.summary.reportedSeconds > 0 else { return "—" }
        return report.summary.reportedSeconds.formattedWorkDuration()
    }

    private var elapsedDetail: String {
        let multiplier = report.summary.parallelMultiplier
        if multiplier.isFinite, multiplier >= 1.2 {
            return "x\(String(format: "%.1f", multiplier)) parallel"
        }
        return report.summary.reportedSeconds > 0 ? "Tracked use" : "Not reported"
    }
}

private struct PanelModelDetailMetric: View {
    let label: String
    let value: String
    let detail: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(Color.white.opacity(0.34))
            Text(value)
                .font(.system(size: 15, weight: .semibold, design: .rounded))
                .foregroundStyle(Color.white.opacity(0.86))
                .lineLimit(1)
                .minimumScaleFactor(0.75)
            Text(detail)
                .font(.system(size: 9, weight: .medium))
                .foregroundStyle(Color.white.opacity(0.28))
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 10)
        .accessibilityElement(children: .combine)
    }
}

private struct PanelModelDetailProjectsSection: View {
    let projects: [ProjectUsageStat]
    let totalTokens: Int

    var body: some View {
        VStack(spacing: 0) {
            PanelModelDetailSectionHeader(
                title: "Projects",
                countLabel: projects.isEmpty ? nil : "\(projects.count)")

            if projects.isEmpty {
                PanelModelDetailEmptyRow("No project attribution was recorded for this model.")
            } else {
                ForEach(projects) { project in
                    PanelModelDetailProjectRow(
                        project: project,
                        totalTokens: totalTokens)
                }
            }
        }
    }
}

private struct PanelModelDetailProjectRow: View {
    let project: ProjectUsageStat
    let totalTokens: Int

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Circle()
                .fill(accent.opacity(0.72))
                .frame(width: 6, height: 6)
                .padding(.top, 5)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 3) {
                Text(project.name)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Color.white.opacity(0.72))
                    .lineLimit(1)
                Text(project.path ?? sourceLabel)
                    .font(.system(size: 9, weight: .medium, design: project.path == nil ? .default : .monospaced))
                    .foregroundStyle(Color.white.opacity(0.3))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(metadata)
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(Color.white.opacity(0.34))
                    .lineLimit(1)
            }

            Spacer(minLength: 10)

            VStack(alignment: .trailing, spacing: 4) {
                Text(project.totalTokens.formattedTokens())
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                    .foregroundStyle(Color.white.opacity(0.78))
                Text(amountDetail)
                    .font(.system(size: 9, weight: .semibold, design: .rounded))
                    .foregroundStyle(Color.white.opacity(0.36))
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 10)
        .overlay(alignment: .bottom) {
            PanelModelDetailDivider().padding(.leading, 34)
        }
        .help(project.path ?? project.name)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(accessibilityLabel))
    }

    private var accent: Color {
        guard let source = project.sources.first else { return Color.white.opacity(0.5) }
        return panelAccentColor(forSource: source)
    }

    private var sourceLabel: String {
        panelModelDetailSourceLabel(project.sources)
    }

    private var metadata: String {
        let sessions = project.sessionCount == 1 ? "1 session" : "\(project.sessionCount) sessions"
        let values = project.path == nil
            ? [sessions, panelModelDetailQualityLabel(project.quality)]
            : [sourceLabel, sessions, panelModelDetailQualityLabel(project.quality)]
        return values.joined(separator: " · ")
    }

    private var amountDetail: String {
        [
            panelModelDetailPercentage(project.totalTokens, of: totalTokens),
            project.cost > 0 ? project.cost.formattedCost() : nil,
        ]
        .compactMap { $0 }
        .joined(separator: " · ")
    }

    private var accessibilityLabel: String {
        "\(project.name), \(project.totalTokens) tokens, \(metadata)"
    }
}

private struct PanelModelDetailSourcesSection: View {
    let sources: [SourceStat]
    let totalTokens: Int

    var body: some View {
        VStack(spacing: 0) {
            PanelModelDetailSectionHeader(
                title: "Sources",
                countLabel: sources.isEmpty ? nil : "\(sources.count)")

            if sources.isEmpty {
                PanelModelDetailEmptyRow("No source breakdown is available for this model.")
            } else {
                ForEach(sources, id: \.id) { source in
                    PanelModelDetailSourceRow(
                        source: source,
                        totalTokens: totalTokens)
                }
            }
        }
    }
}

private struct PanelModelDetailSourceRow: View {
    let source: SourceStat
    let totalTokens: Int

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            Circle()
                .fill(panelAccentColor(forSource: source.source).opacity(0.72))
                .frame(width: 6, height: 6)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 3) {
                Text(source.source)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Color.white.opacity(0.7))
                Text(timeDetail)
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(Color.white.opacity(0.32))
            }

            Spacer(minLength: 10)

            VStack(alignment: .trailing, spacing: 3) {
                Text(source.totalTokens.formattedTokens())
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                    .foregroundStyle(Color.white.opacity(0.78))
                Text(amountDetail)
                    .font(.system(size: 9, weight: .semibold, design: .rounded))
                    .foregroundStyle(Color.white.opacity(0.36))
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 9)
        .overlay(alignment: .bottom) {
            PanelModelDetailDivider().padding(.leading, 34)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(
            Text("\(source.source), \(source.totalTokens) tokens, \(timeDetail)"))
    }

    private var timeDetail: String {
        guard source.reportedSeconds > 0 else { return "Time not reported" }
        return formattedUsageTimeSummary(
            reportedSeconds: source.reportedSeconds,
            parallelMultiplier: source.parallelMultiplier)
    }

    private var amountDetail: String {
        [
            panelModelDetailPercentage(source.totalTokens, of: totalTokens),
            source.cost > 0 ? source.cost.formattedCost() : nil,
        ]
        .compactMap { $0 }
        .joined(separator: " · ")
    }
}
