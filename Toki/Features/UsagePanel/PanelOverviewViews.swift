import Foundation
import Charts
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

struct PanelDailyTokenChartView: View {
    let usage: UsageData
    let isLoading: Bool

    @State private var selectedBucketStart: Date?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            header

            if isLoading {
                SkeletonBar(height: 70, cornerRadius: 6)
            } else if hasTokenData {
                chart
            } else {
                Text("No hourly data")
                    .font(.system(size: 12))
                    .foregroundColor(Color.white.opacity(0.3))
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, 18)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private var header: some View {
        HStack(alignment: .lastTextBaseline) {
            VStack(alignment: .leading, spacing: 3) {
                Text("HOURLY USAGE")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundColor(Color.white.opacity(0.24))
                    .tracking(1.2)

                if isLoading {
                    SkeletonBar(width: 92, height: 13, cornerRadius: 4)
                } else if let bucket = highlightedBucket {
                    Text("\(formattedRange(for: bucket)) · \(bucket.totalTokens.formattedTokens())")
                        .font(.system(size: 12, weight: .semibold, design: .rounded))
                        .foregroundColor(.white.opacity(0.78))
                        .lineLimit(1)
                } else {
                    Text("Waiting for timestamped tokens")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(Color.white.opacity(0.32))
                        .lineLimit(1)
                }
            }

            Spacer()

            if !isLoading, highlightedBucket != nil {
                Text(selectedBucket == nil ? "PEAK" : "HOUR")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundColor(Color(red: 0.4, green: 0.9, blue: 0.6).opacity(0.75))
            }
        }
    }

    private var chart: some View {
        Chart(displayBuckets) { bucket in
            BarMark(
                x: .value("Hour", bucket.startDate, unit: .hour),
                y: .value("Tokens", bucket.totalTokens))
                .foregroundStyle(color(for: bucket))
        }
        .chartXAxis {
            AxisMarks(values: axisDates) { value in
                AxisGridLine()
                    .foregroundStyle(Color.white.opacity(0.06))
                AxisTick()
                    .foregroundStyle(Color.white.opacity(0.12))
                AxisValueLabel {
                    if let date = value.as(Date.self) {
                        Text(Self.axisFormatter.string(from: date))
                            .font(.system(size: 8, weight: .medium))
                            .foregroundColor(Color.white.opacity(0.32))
                    }
                }
            }
        }
        .chartYAxis(.hidden)
        .chartYScale(domain: 0...max(1, maxTokenCount))
        .chartPlotStyle { plotArea in
            plotArea
                .background(Color.white.opacity(0.025))
                .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
        }
        .chartOverlay { proxy in
            GeometryReader { geometry in
                Rectangle()
                    .fill(Color.clear)
                    .contentShape(Rectangle())
                    .gesture(
                        DragGesture(minimumDistance: 0)
                            .onChanged { value in
                                updateSelection(
                                    at: value.location,
                                    proxy: proxy,
                                    geometry: geometry)
                            }
                            .onEnded { _ in
                                selectedBucketStart = nil
                            })
                    .onContinuousHover { phase in
                        switch phase {
                        case let .active(location):
                            updateSelection(
                                at: location,
                                proxy: proxy,
                                geometry: geometry)
                        case .ended:
                            selectedBucketStart = nil
                        }
                    }
            }
        }
        .frame(height: 82)
        .accessibilityLabel(Text(accessibilitySummary))
    }

    private var displayBuckets: [UsageTimeBucket] {
        usage.timeBuckets
    }

    private var hasTokenData: Bool {
        displayBuckets.contains { $0.totalTokens > 0 }
    }

    private var highlightedBucket: UsageTimeBucket? {
        selectedBucket ?? usage.peakTokenBucket
    }

    private var selectedBucket: UsageTimeBucket? {
        guard let selectedBucketStart else { return nil }
        return displayBuckets.first { $0.startDate == selectedBucketStart }
    }

    private var highlightedStartDate: Date? {
        highlightedBucket?.startDate
    }

    private var maxTokenCount: Int {
        displayBuckets.map(\.totalTokens).max() ?? 0
    }

    private var axisDates: [Date] {
        guard !displayBuckets.isEmpty else { return [] }
        let step = max(1, displayBuckets.count / 4)
        return displayBuckets.indices.compactMap { index in
            if index % step == 0 || index == displayBuckets.count - 1 {
                return displayBuckets[index].startDate
            }
            return nil
        }
    }

    private var accessibilitySummary: String {
        guard let bucket = usage.peakTokenBucket else {
            return "Hourly token usage chart with no timestamped token data"
        }
        return "Hourly token usage chart. Peak \(formattedRange(for: bucket)), \(bucket.totalTokens) tokens"
    }

    private func color(for bucket: UsageTimeBucket) -> Color {
        if bucket.startDate == highlightedStartDate {
            return Color(red: 0.4, green: 0.9, blue: 0.6).opacity(0.9)
        }
        if bucket.totalTokens == 0 {
            return Color.white.opacity(0.08)
        }
        return Color(red: 0.45, green: 0.75, blue: 1.0).opacity(0.58)
    }

    private func updateSelection(at location: CGPoint, proxy: ChartProxy, geometry: GeometryProxy) {
        let plotFrame = geometry[proxy.plotAreaFrame]
        let xPosition = location.x - plotFrame.origin.x
        guard xPosition >= 0,
              xPosition <= plotFrame.width,
              let date = proxy.value(atX: xPosition, as: Date.self),
              let nearestBucketStart = nearestBucketStart(to: date) else {
            selectedBucketStart = nil
            return
        }

        selectedBucketStart = nearestBucketStart
    }

    private func nearestBucketStart(to date: Date) -> Date? {
        displayBuckets.min { lhs, rhs in
            abs(lhs.startDate.timeIntervalSince(date)) < abs(rhs.startDate.timeIntervalSince(date))
        }?.startDate
    }

    private func formattedRange(for bucket: UsageTimeBucket) -> String {
        "\(Self.hourFormatter.string(from: bucket.startDate))-\(Self.hourFormatter.string(from: bucket.endDate))"
    }

    private static let hourFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "HH:mm"
        return formatter
    }()

    private static let axisFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "HH"
        return formatter
    }()
}

struct PanelWorkTimeView: View {
    let usage: UsageData
    let isLoading: Bool

    var body: some View {
        VStack(spacing: 0) {
            if isLoading {
                VStack(spacing: 0) {
                    PanelSectionCaption(title: "Summary")
                    WorkTimeTotalHeaderView(
                        value: "",
                        isLoading: true)
                    WorkTimeRelationshipTableView(
                        rows: loadingRelationshipRows,
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
                    WorkTimeTotalHeaderView(
                        value: usage.workTime.wallClockSeconds.formattedWorkDuration())
                    WorkTimeRelationshipTableView(rows: relationshipRows)
                }
                .padding(.vertical, 6)
            }
        }
    }

    private var relationshipRows: [WorkTimeRelationshipRow] {
        [
            WorkTimeRelationshipRow(
                metric: "Main Agent",
                relationship: "Direct work",
                value: usage.workTime.mainAgentSeconds.formattedWorkDuration(),
                accent: Color(red: 0.55, green: 0.9, blue: 0.65)),
            WorkTimeRelationshipRow(
                metric: "Subagents",
                relationship: "Delegated work",
                value: usage.workTime.subagentSeconds.formattedWorkDuration(),
                accent: Color(red: 0.85, green: 0.68, blue: 1.0)),
            WorkTimeRelationshipRow(
                metric: "Total Work",
                relationship: "Main + Subagents",
                value: usage.workTime.agentSeconds.formattedWorkDuration(),
                accent: Color(red: 0.95, green: 0.55, blue: 0.35)),
            WorkTimeRelationshipRow(
                metric: "AI Work Time",
                relationship: "Overlap once",
                value: usage.workTime.wallClockSeconds.formattedWorkDuration(),
                accent: Color(red: 0.45, green: 0.8, blue: 1.0)),
            WorkTimeRelationshipRow(
                metric: "Parallel",
                relationship: "Total Work / AI Work",
                value: formattedParallelMultiplier,
                accent: Color(red: 0.75, green: 0.65, blue: 1.0)),
            WorkTimeRelationshipRow(
                metric: "Streams",
                relationship: "Active / Max",
                value: "\(usage.workTime.activeStreamCount) / \(usage.workTime.maxConcurrentStreams)",
                accent: Color(red: 1.0, green: 0.8, blue: 0.35)),
        ]
    }

    private var loadingRelationshipRows: [WorkTimeRelationshipRow] {
        [
            WorkTimeRelationshipRow(
                metric: "Main Agent",
                relationship: "Direct work",
                value: "",
                accent: Color(red: 0.55, green: 0.9, blue: 0.65)),
            WorkTimeRelationshipRow(
                metric: "Subagents",
                relationship: "Delegated work",
                value: "",
                accent: Color(red: 0.85, green: 0.68, blue: 1.0)),
            WorkTimeRelationshipRow(
                metric: "Total Work",
                relationship: "Main + Subagents",
                value: "",
                accent: Color(red: 0.95, green: 0.55, blue: 0.35)),
            WorkTimeRelationshipRow(
                metric: "AI Work Time",
                relationship: "Overlap once",
                value: "",
                accent: Color(red: 0.45, green: 0.8, blue: 1.0)),
            WorkTimeRelationshipRow(
                metric: "Parallel",
                relationship: "Total Work / AI Work",
                value: "",
                accent: Color(red: 0.75, green: 0.65, blue: 1.0)),
            WorkTimeRelationshipRow(
                metric: "Streams",
                relationship: "Active / Max",
                value: "",
                accent: Color(red: 1.0, green: 0.8, blue: 0.35)),
        ]
    }

    private var formattedParallelMultiplier: String {
        let multiplier = usage.workTime.parallelMultiplier
        guard multiplier.isFinite, multiplier > 0 else { return "N/A" }
        return String(format: "%.2fx", multiplier)
    }
}

private struct WorkTimeTotalHeaderView: View {
    let value: String
    var isLoading = false

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            RoundedRectangle(cornerRadius: 2)
                .fill(Color(red: 0.95, green: 0.55, blue: 0.35).opacity(isLoading ? 0.18 : 0.8))
                .frame(width: 3, height: 32)

            VStack(alignment: .leading, spacing: 4) {
                Text("AI WORK TIME")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundColor(Color.white.opacity(isLoading ? 0.22 : 0.38))
                    .tracking(1.2)

                if isLoading {
                    SkeletonBar(width: 72, height: 22, cornerRadius: 5)
                } else {
                    Text(value)
                        .font(.system(size: 24, weight: .bold, design: .rounded))
                        .foregroundColor(.white.opacity(0.92))
                }
            }

            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.top, 6)
        .padding(.bottom, 8)
    }
}

private struct WorkTimeRelationshipRow {
    let metric: String
    let relationship: String
    let value: String
    let accent: Color
}

private struct WorkTimeRelationshipTableView: View {
    let rows: [WorkTimeRelationshipRow]
    var isLoading = false

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                tableHeader("Metric", width: 82, alignment: .leading)
                tableHeader("Relationship", width: 112, alignment: .leading)
                tableHeader("Value", width: nil, alignment: .trailing)
            }
            .padding(.horizontal, 16)
            .padding(.top, 6)
            .padding(.bottom, 5)

            ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                HStack(spacing: 0) {
                    HStack(spacing: 6) {
                        Circle()
                            .fill(row.accent.opacity(isLoading ? 0.15 : 0.52))
                            .frame(width: 5, height: 5)
                        Text(row.metric)
                            .font(.system(size: 11, weight: .medium))
                            .foregroundColor(Color.white.opacity(isLoading ? 0.2 : 0.52))
                            .lineLimit(1)
                    }
                    .frame(width: 82, alignment: .leading)

                    Text(row.relationship)
                        .font(.system(size: 11))
                        .foregroundColor(Color.white.opacity(isLoading ? 0.16 : 0.35))
                        .lineLimit(1)
                        .frame(width: 112, alignment: .leading)

                    Spacer(minLength: 8)

                    if isLoading {
                        SkeletonBar(width: skeletonWidth(for: row.metric), height: 10)
                    } else {
                        Text(row.value)
                            .font(.system(size: 11, weight: .semibold, design: .rounded))
                            .foregroundColor(Color.white.opacity(0.84))
                            .lineLimit(1)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 6)
            }
        }
    }

    private func tableHeader(_ title: String, width: CGFloat?, alignment: Alignment) -> some View {
        Text(title.uppercased())
            .font(.system(size: 8, weight: .semibold))
            .foregroundColor(Color.white.opacity(0.22))
            .tracking(0.8)
            .frame(width: width, alignment: alignment)
    }

    private func skeletonWidth(for value: String) -> CGFloat {
        let seed = value.unicodeScalars.reduce(0) { $0 + Int($1.value) }
        return CGFloat(34 + (seed % 24))
    }
}
