import SwiftUI

private let skeletonRowWidths: [CGFloat] = [88, 72, 96, 64, 80]

struct PanelByModelView: View {
    let usage: UsageData
    let isLoading: Bool

    var body: some View {
        VStack(spacing: 0) {
            if isLoading {
                VStack(spacing: 0) {
                    ForEach(Array(skeletonRowWidths.enumerated()), id: \.offset) { _, width in
                        skeletonModelRow(labelWidth: width)
                    }
                }
                .padding(.vertical, 6)
            } else if usage.perModel.isEmpty {
                Text("No data")
                    .font(.system(size: 12))
                    .foregroundColor(Color.white.opacity(0.3))
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, 24)
            } else {
                VStack(spacing: 0) {
                    ForEach(usage.perModel, id: \.id) { stat in
                        ModelStatRowView(stat: stat)
                    }
                }
                .padding(.vertical, 6)
            }
        }
    }

    private func skeletonModelRow(labelWidth: CGFloat) -> some View {
        HStack(alignment: .center, spacing: 6) {
            Circle()
                .fill(Color.white.opacity(0.08))
                .frame(width: 5, height: 5)
            VStack(alignment: .leading, spacing: 4) {
                SkeletonBar(width: labelWidth, height: 10)
                SkeletonBar(width: max(52, labelWidth - 16), height: 8)
            }
            Spacer()
            SkeletonBar(width: 36, height: 10)
            SkeletonBar(width: 32, height: 10)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 7)
    }
}

private struct ModelStatRowView: View {
    let stat: ModelStat

    var body: some View {
        let hasValidCost = stat.cost.isFinite && stat.cost > 0

        HStack(alignment: .center, spacing: 6) {
            Circle()
                .fill(accentColor.opacity(0.5))
                .frame(width: 5, height: 5)
            VStack(alignment: .leading, spacing: 3) {
                Text(displayName)
                    .font(.system(size: 11))
                    .foregroundColor(Color.white.opacity(0.45))
                    .lineLimit(1)
                Text(timeSummary)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundColor(Color.white.opacity(0.3))
                    .lineLimit(1)
            }
            Spacer()
            Text(stat.totalTokens.formattedTokens())
                .font(.system(size: 11, weight: .semibold, design: .rounded))
                .foregroundColor(Color.white.opacity(0.7))
                .frame(width: 44, alignment: .trailing)
            Text(hasValidCost ? stat.cost.formattedCost() : "—")
                .font(.system(size: 11, weight: .semibold, design: .rounded))
                .foregroundColor(
                    hasValidCost
                        ? Color(red: 0.4, green: 0.9, blue: 0.6)
                        : Color.white.opacity(0.25))
                .frame(width: 56, alignment: .trailing)
                .lineLimit(1)
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
        if stat.sources.count == 1 {
            return stat.sources[0]
        }

        let head = stat.sources.prefix(2).joined(separator: ", ")
        let remainder = stat.sources.count - 2
        return remainder > 0 ? "\(head) +\(remainder)" : head
    }

    private var timeSummary: String {
        "\(stat.activeSeconds.formattedWorkDuration()) used"
    }

    private var accentColor: Color {
        if stat.id.hasPrefix("claude-") { return Color(red: 0.55, green: 0.45, blue: 1.0) }
        if stat.id.hasPrefix("gpt-") { return Color(red: 0.4, green: 0.9, blue: 0.5) }
        if stat.id.hasPrefix("gemini-") { return Color(red: 0.3, green: 0.7, blue: 1.0) }
        if stat.id.hasPrefix("grok-") { return Color(red: 1.0, green: 0.8, blue: 0.2) }
        return Color.white.opacity(0.5)
    }
}
