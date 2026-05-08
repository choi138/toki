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
        let hasValidCost = stat.isPriceKnown && stat.cost.isFinite && stat.cost > 0

        HStack(alignment: .center, spacing: 6) {
            Circle()
                .fill(panelAccentColor(forModelID: stat.id).opacity(0.5))
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
        if stat.sources.count == 1 { return stat.sources[0] }
        let head = stat.sources.prefix(2).joined(separator: ", ")
        let remainder = stat.sources.count - 2
        return remainder > 0 ? "\(head) +\(remainder)" : head
    }

    private var timeSummary: String {
        if !stat.isPriceKnown, stat.totalTokens > 0 {
            return "unpriced"
        }
        if stat.activeSeconds > 0 {
            return "\(stat.activeSeconds.formattedWorkDuration()) used"
        }
        return stat.cost > 0 ? "cost only" : "0s used"
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

func panelAccentColor(forModelID id: String) -> Color {
    if id.hasPrefix("claude-") { return Color(red: 0.55, green: 0.45, blue: 1.0) }
    if id.hasPrefix("gpt-") { return Color(red: 0.4, green: 0.9, blue: 0.5) }
    if id.hasPrefix("gemini-") { return Color(red: 0.3, green: 0.7, blue: 1.0) }
    if id.hasPrefix("grok-") { return Color(red: 1.0, green: 0.8, blue: 0.2) }
    return Color.white.opacity(0.5)
}
