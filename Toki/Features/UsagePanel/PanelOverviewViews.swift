import Foundation
import SwiftUI

struct PanelHeroView: View {
    let usage: UsageData
    let isLoading: Bool
    let yesterdayTotal: Int?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("TOTAL TOKENS")
                .font(.system(size: 10, weight: .semibold))
                .foregroundColor(Color.white.opacity(0.3))
                .tracking(1.5)

            if isLoading {
                SkeletonBar(width: 148, height: 44, cornerRadius: 8)
            } else {
                Text(usage.totalTokens.formattedTokens())
                    .font(.system(size: 42, weight: .bold, design: .rounded))
                    .tracking(-1.5)
                    .foregroundColor(.white)
            }

            if !isLoading, let comparison = comparisonContent {
                HStack(spacing: 3) {
                    Image(systemName: comparison.symbolName)
                        .font(.system(size: 9, weight: .bold))
                    Text(comparison.text)
                        .font(.system(size: 10, weight: .medium))
                }
                .foregroundColor(comparison.color)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 16)
        .padding(.vertical, 20)
    }

    private var comparisonContent: PanelHeroComparisonContent? {
        PanelHeroComparisonContent.make(
            currentTotal: usage.totalTokens,
            yesterdayTotal: yesterdayTotal)
    }
}

struct PanelTokenBreakdownView: View {
    let usage: UsageData
    let isLoading: Bool

    var body: some View {
        VStack(spacing: 0) {
            StatRowView(
                label: "AI Work Time",
                value: usage.activeSeconds.formattedWorkDuration(),
                accent: Color(red: 0.95, green: 0.55, blue: 0.35),
                isLoading: isLoading)
            StatRowView(
                label: "Input",
                value: usage.inputTokens.formattedTokens(),
                accent: Color(red: 0.4, green: 0.8, blue: 1.0),
                isLoading: isLoading)
            StatRowView(
                label: "Output",
                value: usage.outputTokens.formattedTokens(),
                accent: Color(red: 0.6, green: 1.0, blue: 0.7),
                isLoading: isLoading)
            StatRowView(
                label: "Cache Read",
                value: usage.cacheReadTokens.formattedTokens(),
                accent: Color(red: 1.0, green: 0.8, blue: 0.4),
                isLoading: isLoading)
            StatRowView(
                label: "Cache Hit",
                value: String(format: "%.1f%%", usage.cacheEfficiency),
                accent: Color(red: 1.0, green: 0.65, blue: 0.2),
                isLoading: isLoading)
            StatRowView(
                label: "Estimated Cost",
                value: usage.cost.formattedCost(),
                accent: Color(red: 0.4, green: 0.9, blue: 0.6),
                isLoading: isLoading)
        }
        .padding(.vertical, 6)
    }
}
