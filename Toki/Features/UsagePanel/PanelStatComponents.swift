import SwiftUI

struct PanelSectionCaption: View {
    let title: String

    var body: some View {
        HStack {
            Text(title.uppercased())
                .font(.system(size: 9, weight: .semibold))
                .foregroundColor(Color.white.opacity(0.24))
                .tracking(1.2)
            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.top, 12)
        .padding(.bottom, 4)
    }
}

struct ModelStatRowView: View, Equatable {
    let stat: ModelStat

    var body: some View {
        HStack(alignment: .center, spacing: 6) {
            Circle()
                .fill(panelAccentColor(forModelID: stat.id).opacity(0.5))
                .frame(width: 5, height: 5)
            VStack(alignment: .leading, spacing: 3) {
                Text(displayName)
                    .font(.system(size: 11))
                    .foregroundColor(Color.white.opacity(0.45))
                    .lineLimit(1)
                Text(stat.panelTimeSummary)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundColor(Color.white.opacity(0.3))
                    .lineLimit(1)
            }
            Spacer()
            Text(stat.totalTokens.formattedTokens())
                .font(.system(size: 11, weight: .semibold, design: .rounded))
                .foregroundColor(Color.white.opacity(0.7))
                .frame(width: 44, alignment: .trailing)
            Text(stat.panelCostSummary)
                .font(.system(size: 11, weight: .semibold, design: .rounded))
                .foregroundColor(
                    stat.hasKnownPanelCost
                        ? Color(red: 0.4, green: 0.9, blue: 0.6)
                        : Color.white.opacity(0.25))
                .frame(width: 56, alignment: .trailing)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 7)
    }

    private var displayName: String {
        let baseName = stat.id.hasPrefix("claude-") ? String(stat.id.dropFirst(7)) : stat.id
        guard !stat.sources.isEmpty else { return baseName }
        return "\(baseName) · \(sourceLabel)"
    }

    private var sourceLabel: String {
        if stat.sources.count == 1 { return stat.sources[0] }
        let head = stat.sources.prefix(2).joined(separator: ", ")
        let remainder = stat.sources.count - 2
        return remainder > 0 ? "\(head) +\(remainder)" : head
    }
}

extension ModelStat {
    var panelTimeSummary: String {
        if activeSeconds > 0 {
            return "\(activeSeconds.formattedWorkDuration()) used"
        }
        return cost > 0 ? "cost only" : "0s used"
    }

    var panelCostSummary: String {
        if hasKnownPanelCost {
            return cost.formattedCost()
        }
        if !isPriceKnown, totalTokens > 0 {
            return "unpriced"
        }
        return "—"
    }

    var hasKnownPanelCost: Bool {
        isPriceKnown && cost.isFinite && cost >= 0
    }
}

struct ContextOnlyModelStatRowView: View, Equatable {
    let stat: ContextOnlyModelStat

    var body: some View {
        HStack(alignment: .center, spacing: 6) {
            Circle()
                .fill(panelAccentColor(forModelID: stat.model).opacity(0.5))
                .frame(width: 5, height: 5)
            Text(displayName)
                .font(.system(size: 11))
                .foregroundColor(Color.white.opacity(0.45))
                .lineLimit(1)
            Spacer()
            Text(stat.contextTokens.formattedTokens())
                .font(.system(size: 11, weight: .semibold, design: .rounded))
                .foregroundColor(Color.white.opacity(0.7))
                .frame(width: 44, alignment: .trailing)
            Text("context")
                .font(.system(size: 11, weight: .semibold, design: .rounded))
                .foregroundColor(Color.white.opacity(0.25))
                .frame(width: 56, alignment: .trailing)
                .lineLimit(1)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 7)
    }

    private var displayName: String {
        let baseName = stat.model.hasPrefix("claude-") ? String(stat.model.dropFirst(7)) : stat.model
        return "\(baseName) · \(stat.source)"
    }
}

struct PanelTokenTotalsView: View {
    let summaries: [TokenTotalSummary]
    let isLoading: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            PanelSectionCaption(title: "Period Totals")

            HStack(spacing: 0) {
                ForEach(Array(TokenTotalPeriod.allCases.enumerated()), id: \.element) { index, period in
                    PanelTokenTotalMetric(
                        label: shortLabel(for: period),
                        value: totalTokens(for: period).formattedTokens(),
                        accent: accentColor(for: period),
                        isLoading: showsSkeleton)

                    if index < TokenTotalPeriod.allCases.count - 1 {
                        Rectangle()
                            .fill(Color.white.opacity(0.07))
                            .frame(width: 0.5, height: 34)
                    }
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 9)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color.white.opacity(0.045)))
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(Color.white.opacity(0.08), lineWidth: 0.5))
            .padding(.horizontal, 16)
        }
        .padding(.bottom, 12)
    }

    private var showsSkeleton: Bool {
        isLoading && summaries.isEmpty
    }

    private func totalTokens(for period: TokenTotalPeriod) -> Int {
        summaries.first { $0.period == period }?.totalTokens ?? 0
    }

    private func shortLabel(for period: TokenTotalPeriod) -> String {
        switch period {
        case .last7Days:
            "7D"
        case .last30Days:
            "30D"
        case .allTime:
            "All"
        }
    }

    private func accentColor(for period: TokenTotalPeriod) -> Color {
        switch period {
        case .last7Days:
            Color(red: 0.45, green: 0.88, blue: 0.78)
        case .last30Days:
            Color(red: 0.52, green: 0.72, blue: 1.0)
        case .allTime:
            Color(red: 1.0, green: 0.72, blue: 0.42)
        }
    }
}

private struct PanelTokenTotalMetric: View {
    let label: String
    let value: String
    let accent: Color
    let isLoading: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 4) {
                Circle()
                    .fill(accent.opacity(isLoading ? 0.15 : 0.55))
                    .frame(width: 5, height: 5)
                Text(label)
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundColor(Color.white.opacity(isLoading ? 0.2 : 0.4))
                    .lineLimit(1)
            }

            if isLoading {
                SkeletonBar(width: 44, height: 12, cornerRadius: 4)
            } else {
                Text(value)
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                    .foregroundColor(Color.white.opacity(0.86))
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 6)
    }
}

func panelAccentColor(forModelID id: String) -> Color {
    if id.hasPrefix("claude-") { return Color(red: 0.55, green: 0.45, blue: 1.0) }
    if id.hasPrefix("gpt-") { return Color(red: 0.4, green: 0.9, blue: 0.5) }
    if id.hasPrefix("gemini-") { return Color(red: 0.3, green: 0.7, blue: 1.0) }
    if id.hasPrefix("grok-") { return Color(red: 1.0, green: 0.8, blue: 0.2) }
    return Color.white.opacity(0.5)
}
