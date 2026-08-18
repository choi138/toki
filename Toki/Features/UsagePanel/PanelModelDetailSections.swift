import Foundation
import SwiftUI
import TokiUsageCore

struct PanelModelDetailSessionsSection: View {
    private static let visibleLimit = 20

    let sessions: [SessionUsageStat]

    var body: some View {
        VStack(spacing: 0) {
            PanelModelDetailSectionHeader(
                title: "Recent sessions",
                countLabel: sessions.isEmpty ? nil : "\(sessions.count)")

            if sessions.isEmpty {
                PanelModelDetailEmptyRow("No session attribution was recorded for this model.")
            } else {
                ForEach(sessions.prefix(Self.visibleLimit)) { session in
                    PanelModelDetailSessionRow(session: session)
                }

                if sessions.count > Self.visibleLimit {
                    PanelModelDetailFootnote(
                        "Showing the \(Self.visibleLimit) most recent of \(sessions.count) sessions.")
                }
            }
        }
    }
}

private struct PanelModelDetailSessionRow: View {
    let session: SessionUsageStat

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Circle()
                .fill(panelAccentColor(forSource: session.source).opacity(0.72))
                .frame(width: 6, height: 6)
                .padding(.top, 5)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 3) {
                Text(session.projectName)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Color.white.opacity(0.7))
                    .lineLimit(1)
                Text(session.sessionLabel)
                    .font(.system(size: 9, weight: .medium, design: .monospaced))
                    .foregroundStyle(Color.white.opacity(0.3))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text("\(timeRange) · \(session.source) · \(panelModelDetailQualityLabel(session.quality))")
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(Color.white.opacity(0.34))
                    .lineLimit(1)
            }

            Spacer(minLength: 10)

            VStack(alignment: .trailing, spacing: 4) {
                Text(session.totalTokens.formattedTokens())
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                    .foregroundStyle(Color.white.opacity(0.76))
                Text(session.cost > 0 ? session.cost.formattedCost() : "—")
                    .font(.system(size: 9, weight: .semibold, design: .rounded))
                    .foregroundStyle(Color.white.opacity(0.34))
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 10)
        .overlay(alignment: .bottom) {
            PanelModelDetailDivider().padding(.leading, 34)
        }
        .help(session.projectPath ?? session.sessionLabel)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(
            Text("\(session.projectName), \(session.sessionLabel), \(session.totalTokens) tokens, \(timeRange)"))
    }

    private var timeRange: String {
        let start = Self.dateTimeFormatter.string(from: session.firstActivityAt)
        let end: String = if Calendar.autoupdatingCurrent.isDate(
            session.firstActivityAt,
            inSameDayAs: session.lastActivityAt) {
            Self.timeFormatter.string(from: session.lastActivityAt)
        } else {
            Self.dateTimeFormatter.string(from: session.lastActivityAt)
        }
        return "\(start)–\(end)"
    }

    private static let dateTimeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "MMM d, HH:mm"
        return formatter
    }()

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        return formatter
    }()
}

struct PanelModelDetailActivitySection: View {
    private static let visibleLimit = 8

    let buckets: [UsageTimeBucket]
    let availability: PanelModelHourlyAvailability

    var body: some View {
        VStack(spacing: 0) {
            PanelModelDetailSectionHeader(
                title: "Peak activity",
                countLabel: buckets.isEmpty ? nil : "\(buckets.count) active hours")

            if buckets.isEmpty {
                PanelModelDetailEmptyRow(emptyMessage)
            } else {
                ForEach(Array(buckets.prefix(Self.visibleLimit).enumerated()), id: \.element.id) { index, bucket in
                    PanelModelDetailActivityRow(
                        bucket: bucket,
                        rank: index + 1,
                        maxTokens: maxTokens)
                }

                if buckets.count > Self.visibleLimit {
                    PanelModelDetailFootnote(
                        "Showing the top \(Self.visibleLimit) of \(buckets.count) active hours.")
                }
            }
        }
    }

    private var emptyMessage: String {
        switch availability {
        case .available:
            "No attributed hourly activity was recorded for this model."
        case .unsupportedRange:
            "Hourly activity is not broken down for a range this long."
        }
    }

    private var maxTokens: Int {
        max(1, buckets.first?.totalTokens ?? 0)
    }
}

private struct PanelModelDetailActivityRow: View {
    let bucket: UsageTimeBucket
    let rank: Int
    let maxTokens: Int

    var body: some View {
        HStack(spacing: 10) {
            Text("\(rank)")
                .font(.system(size: 9, weight: .bold, design: .rounded))
                .foregroundStyle(Color.white.opacity(0.3))
                .frame(width: 14, alignment: .trailing)

            VStack(alignment: .leading, spacing: 5) {
                Text(timeRange)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(Color.white.opacity(0.52))
                    .lineLimit(1)

                GeometryReader { proxy in
                    ZStack(alignment: .leading) {
                        RoundedRectangle(cornerRadius: 2, style: .continuous)
                            .fill(Color.white.opacity(0.055))
                        RoundedRectangle(cornerRadius: 2, style: .continuous)
                            .fill(Color(red: 0.45, green: 0.75, blue: 1.0).opacity(0.62))
                            .frame(width: proxy.size.width * barFraction)
                    }
                }
                .frame(height: 4)
                .accessibilityHidden(true)
            }

            Spacer(minLength: 10)

            VStack(alignment: .trailing, spacing: 3) {
                Text(bucket.totalTokens.formattedTokens())
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                    .foregroundStyle(Color.white.opacity(0.76))
                Text(bucket.cost > 0 ? bucket.cost.formattedCost() : "—")
                    .font(.system(size: 9, weight: .semibold, design: .rounded))
                    .foregroundStyle(Color.white.opacity(0.32))
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 9)
        .overlay(alignment: .bottom) {
            PanelModelDetailDivider().padding(.leading, 34)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(
            Text("\(timeRange), \(bucket.totalTokens) tokens"))
    }

    private var barFraction: CGFloat {
        guard maxTokens > 0 else { return 0 }
        return min(1, CGFloat(bucket.totalTokens) / CGFloat(maxTokens))
    }

    private var timeRange: String {
        let start = Self.dateTimeFormatter.string(from: bucket.startDate)
        let end = Self.timeFormatter.string(from: bucket.endDate)
        return "\(start)–\(end)"
    }

    private static let dateTimeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "MMM d, HH:mm"
        return formatter
    }()

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        return formatter
    }()
}

struct PanelModelDetailTokenSection: View {
    let components: [PanelModelTokenComponent]
    let totalTokens: Int

    var body: some View {
        VStack(spacing: 0) {
            PanelModelDetailSectionHeader(title: "Token composition")

            if components.isEmpty {
                PanelModelDetailEmptyRow("No token composition is available for this model.")
            } else {
                PanelModelTokenCompositionBar(
                    components: components,
                    totalTokens: totalTokens)
                    .padding(.horizontal, 18)
                    .padding(.bottom, 7)

                ForEach(components) { component in
                    PanelModelTokenComponentRow(
                        component: component,
                        totalTokens: totalTokens)
                }
            }
        }
    }
}

private struct PanelModelTokenCompositionBar: View {
    let components: [PanelModelTokenComponent]
    let totalTokens: Int

    var body: some View {
        GeometryReader { proxy in
            let spacing = CGFloat(max(0, components.count - 1)) * 2
            let availableWidth = max(0, proxy.size.width - spacing)

            HStack(spacing: 2) {
                ForEach(components) { component in
                    RoundedRectangle(cornerRadius: 2, style: .continuous)
                        .fill(panelModelTokenColor(component.kind).opacity(0.72))
                        .frame(width: availableWidth * componentFraction(component))
                }
            }
        }
        .frame(height: 5)
        .accessibilityHidden(true)
    }

    private func componentFraction(_ component: PanelModelTokenComponent) -> Double {
        guard totalTokens > 0 else { return 0 }
        return Double(component.tokens) / Double(totalTokens)
    }
}

private struct PanelModelTokenComponentRow: View {
    let component: PanelModelTokenComponent
    let totalTokens: Int

    var body: some View {
        HStack(spacing: 9) {
            Circle()
                .fill(panelModelTokenColor(component.kind).opacity(0.72))
                .frame(width: 6, height: 6)
                .accessibilityHidden(true)
            Text(component.kind.title)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(Color.white.opacity(0.5))
            Spacer(minLength: 10)
            Text(component.tokens.formattedTokens())
                .font(.system(size: 10, weight: .semibold, design: .rounded))
                .foregroundStyle(Color.white.opacity(0.7))
            Text(panelModelDetailPercentage(component.tokens, of: totalTokens) ?? "—")
                .font(.system(size: 9, weight: .semibold, design: .rounded))
                .foregroundStyle(Color.white.opacity(0.32))
                .frame(width: 34, alignment: .trailing)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 7)
        .overlay(alignment: .bottom) {
            PanelModelDetailDivider().padding(.leading, 33)
        }
        .accessibilityElement(children: .combine)
    }
}

struct PanelModelDetailContextSection: View {
    let stats: [ContextOnlyModelStat]

    var body: some View {
        VStack(spacing: 0) {
            PanelModelDetailSectionHeader(
                title: "Context-only records",
                countLabel: stats.isEmpty ? nil : "\(stats.count)")

            Text("Context-window sizes are shown separately and never added to usage totals.")
                .font(.system(size: 10))
                .foregroundStyle(Color.white.opacity(0.36))
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 18)
                .padding(.bottom, 9)

            if stats.isEmpty {
                PanelModelDetailEmptyRow("No positive context-window size was recorded.")
            } else {
                ForEach(stats, id: \.id) { stat in
                    HStack(spacing: 9) {
                        Circle()
                            .fill(panelAccentColor(forSource: stat.source).opacity(0.72))
                            .frame(width: 6, height: 6)
                            .accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(stat.source)
                                .font(.system(size: 11, weight: .medium))
                                .foregroundStyle(Color.white.opacity(0.68))
                            Text("Context window · excluded from totals")
                                .font(.system(size: 9, weight: .medium))
                                .foregroundStyle(Color.white.opacity(0.32))
                        }
                        Spacer(minLength: 10)
                        Text(stat.contextTokens.formattedTokens())
                            .font(.system(size: 11, weight: .semibold, design: .rounded))
                            .foregroundStyle(Color.white.opacity(0.74))
                    }
                    .padding(.horizontal, 18)
                    .padding(.vertical, 9)
                    .overlay(alignment: .bottom) {
                        PanelModelDetailDivider().padding(.leading, 33)
                    }
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(
                        Text("\(stat.source), \(stat.contextTokens) context tokens, excluded from totals"))
                }
            }
        }
    }
}

struct PanelModelDetailSectionHeader: View {
    let title: String
    var countLabel: String?

    var body: some View {
        HStack(alignment: .lastTextBaseline, spacing: 8) {
            Text(title)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Color.white.opacity(0.78))
            Spacer(minLength: 8)
            if let countLabel {
                Text(countLabel)
                    .font(.system(size: 9, weight: .semibold, design: .rounded))
                    .foregroundStyle(Color.white.opacity(0.3))
            }
        }
        .padding(.horizontal, 18)
        .padding(.top, 20)
        .padding(.bottom, 8)
    }
}

struct PanelModelDetailEmptyRow: View {
    let message: String

    init(_ message: String) {
        self.message = message
    }

    var body: some View {
        Text(message)
            .font(.system(size: 10))
            .foregroundStyle(Color.white.opacity(0.34))
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 18)
            .padding(.vertical, 11)
            .background(Color.white.opacity(0.018))
            .accessibilityLabel(Text(message))
    }
}

private struct PanelModelDetailFootnote: View {
    let message: String

    init(_ message: String) {
        self.message = message
    }

    var body: some View {
        Text(message)
            .font(.system(size: 9, weight: .medium))
            .foregroundStyle(Color.white.opacity(0.3))
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 18)
            .padding(.vertical, 8)
    }
}

struct PanelModelDetailDivider: View {
    var body: some View {
        Rectangle()
            .fill(Color.white.opacity(0.07))
            .frame(height: 0.5)
    }
}

struct PanelModelDetailVerticalDivider: View {
    var body: some View {
        Rectangle()
            .fill(Color.white.opacity(0.07))
            .frame(width: 0.5, height: 42)
    }
}

func panelModelDetailQualityLabel(_ quality: AttributionQuality) -> String {
    switch quality {
    case .exact:
        "Exact"
    case .inferred:
        "Inferred"
    case .unknown:
        "Unattributed"
    }
}

func panelModelDetailSourceLabel(_ sources: [String]) -> String {
    guard !sources.isEmpty else { return "Unknown source" }
    if sources.count == 1 { return sources[0] }
    let head = sources.prefix(2).joined(separator: ", ")
    let remainder = sources.count - 2
    return remainder > 0 ? "\(head) +\(remainder)" : head
}

func panelModelDetailPercentage(_ value: Int, of total: Int) -> String? {
    guard value > 0, total > 0 else { return nil }
    let percentage = min(100, Double(value) / Double(total) * 100)
    if percentage < 1 {
        return "<1%"
    }
    return "\(Int(percentage.rounded()))%"
}

private func panelModelTokenColor(_ kind: PanelModelTokenKind) -> Color {
    switch kind {
    case .input:
        Color(red: 0.45, green: 0.75, blue: 1.0)
    case .output:
        Color(red: 0.4, green: 0.9, blue: 0.6)
    case .cacheRead:
        Color(red: 0.68, green: 0.58, blue: 1.0)
    case .cacheWrite:
        Color(red: 1.0, green: 0.72, blue: 0.35)
    case .reasoning:
        Color(red: 1.0, green: 0.52, blue: 0.72)
    case .unclassified:
        Color.white.opacity(0.42)
    }
}
