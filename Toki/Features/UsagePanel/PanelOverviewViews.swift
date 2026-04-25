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
                label: "Active Time",
                value: usage.workTime.wallClockSeconds.formattedWorkDuration(),
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

            if !isLoading, !usage.supplementalStats.isEmpty {
                PanelSectionCaption(title: "Additional Signals")

                ForEach(usage.supplementalStats, id: \.id) { stat in
                    StatRowView(
                        label: stat.label,
                        value: stat.formattedValue,
                        accent: supplementalAccentColor(for: stat),
                        isLoading: false)
                }

                if usage.hasExcludedSupplementalStats {
                    Text(
                        "Excluded from Total Tokens. Cursor currently stores local "
                            + "context-window metrics, not exact request tokens.")
                        .font(.system(size: 10))
                        .foregroundColor(Color.white.opacity(0.28))
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.horizontal, 16)
                        .padding(.top, 6)
                        .padding(.bottom, 8)
                }
            }
        }
        .padding(.vertical, 6)
    }

    private func supplementalAccentColor(for stat: SupplementalStat) -> Color {
        switch stat.unit {
        case .tokens:
            Color(red: 0.85, green: 0.68, blue: 1.0)
        case .count:
            Color(red: 0.55, green: 0.75, blue: 1.0)
        case .cents:
            Color(red: 0.45, green: 0.9, blue: 0.7)
        }
    }
}

struct PanelWorkTimeView: View {
    let usage: UsageData
    let isLoading: Bool

    var body: some View {
        VStack(spacing: 0) {
            if isLoading {
                VStack(spacing: 0) {
                    StatRowView(
                        label: "Agent Work",
                        value: "",
                        accent: Color(red: 0.95, green: 0.55, blue: 0.35),
                        isLoading: true)
                    StatRowView(
                        label: "Active Time",
                        value: "",
                        accent: Color(red: 0.45, green: 0.8, blue: 1.0),
                        isLoading: true)
                    StatRowView(
                        label: "Parallel",
                        value: "",
                        accent: Color(red: 0.75, green: 0.65, blue: 1.0),
                        isLoading: true)
                    StatRowView(
                        label: "Max Streams",
                        value: "",
                        accent: Color(red: 1.0, green: 0.8, blue: 0.35),
                        isLoading: true)
                }
                .padding(.vertical, 6)
            } else if !usage.workTime.hasActivity {
                Text("No work time")
                    .font(.system(size: 12))
                    .foregroundColor(Color.white.opacity(0.3))
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, 24)
            } else {
                VStack(spacing: 0) {
                    PanelSectionCaption(title: "Summary")
                    StatRowView(
                        label: "Agent Work",
                        value: usage.workTime.agentSeconds.formattedWorkDuration(),
                        accent: Color(red: 0.95, green: 0.55, blue: 0.35))
                    StatRowView(
                        label: "Active Time",
                        value: usage.workTime.wallClockSeconds.formattedWorkDuration(),
                        accent: Color(red: 0.45, green: 0.8, blue: 1.0))

                    PanelSectionCaption(title: "Concurrency")
                    StatRowView(
                        label: "Parallel",
                        value: formattedParallelMultiplier,
                        accent: Color(red: 0.75, green: 0.65, blue: 1.0))
                    StatRowView(
                        label: "Max Streams",
                        value: "\(usage.workTime.maxConcurrentStreams)",
                        accent: Color(red: 1.0, green: 0.8, blue: 0.35))
                    StatRowView(
                        label: "Active Streams",
                        value: "\(usage.workTime.activeStreamCount)",
                        accent: Color(red: 0.55, green: 0.9, blue: 0.65))
                }
                .padding(.vertical, 6)
            }
        }
    }

    private var formattedParallelMultiplier: String {
        let multiplier = usage.workTime.parallelMultiplier
        guard multiplier.isFinite, multiplier > 0 else { return "0.00x" }
        return String(format: "%.2fx", multiplier)
    }
}
