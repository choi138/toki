import Foundation
import SwiftUI

struct PanelHourlyUsageView: View {
    let usage: UsageData
    let isLoading: Bool

    var body: some View {
        VStack(spacing: 0) {
            PanelDailyTokenChartView(usage: usage, isLoading: isLoading)

            if isLoading {
                divider
                PanelHourlySummaryView(rows: loadingSummaryRows, isLoading: true)
                PanelSectionCaption(title: "Top Hours")
                ForEach(0..<5, id: \.self) { index in
                    PanelHourlyBucketSkeletonRow(width: CGFloat(82 + index * 8))
                }
            } else if hasTokenData {
                divider
                PanelHourlySummaryView(rows: summaryRows)
                PanelSectionCaption(title: "Top Hours")
                ForEach(Array(topBuckets.enumerated()), id: \.offset) { index, bucket in
                    PanelHourlyBucketRowView(
                        bucket: bucket,
                        rank: index + 1,
                        maxTokenCount: maxTopBucketTokens)
                }
            }
        }
    }

    private var divider: some View {
        Rectangle()
            .fill(Color.white.opacity(0.07))
            .frame(height: 0.5)
    }

    private var hasTokenData: Bool {
        usage.timeBuckets.contains { $0.totalTokens > 0 }
    }

    private var activeBuckets: [UsageTimeBucket] {
        usage.timeBuckets.filter { $0.totalTokens > 0 }
    }

    private var topBuckets: [UsageTimeBucket] {
        activeBuckets
            .sorted {
                if $0.totalTokens != $1.totalTokens {
                    return $0.totalTokens > $1.totalTokens
                }
                return $0.startDate < $1.startDate
            }
            .prefix(5)
            .map { $0 }
    }

    private var maxTopBucketTokens: Int {
        max(1, topBuckets.map(\.totalTokens).max() ?? 0)
    }

    private var summaryRows: [PanelHourlySummaryRow] {
        [
            PanelHourlySummaryRow(
                label: "Peak Hour",
                value: peakHourLabel,
                accent: Color(red: 0.4, green: 0.9, blue: 0.6)),
            PanelHourlySummaryRow(
                label: "Active Hours",
                value: "\(activeBuckets.count)",
                accent: Color(red: 0.45, green: 0.75, blue: 1.0)),
            PanelHourlySummaryRow(
                label: "Hourly Total",
                value: hourlyTotal.formattedTokens(),
                accent: Color(red: 0.85, green: 0.68, blue: 1.0)),
            PanelHourlySummaryRow(
                label: "Avg Active",
                value: averageActiveTokens.formattedTokens(),
                accent: Color(red: 1.0, green: 0.8, blue: 0.35)),
        ]
    }

    private var loadingSummaryRows: [PanelHourlySummaryRow] {
        [
            PanelHourlySummaryRow(
                label: "Peak Hour",
                value: "",
                accent: Color(red: 0.4, green: 0.9, blue: 0.6)),
            PanelHourlySummaryRow(
                label: "Active Hours",
                value: "",
                accent: Color(red: 0.45, green: 0.75, blue: 1.0)),
            PanelHourlySummaryRow(
                label: "Hourly Total",
                value: "",
                accent: Color(red: 0.85, green: 0.68, blue: 1.0)),
            PanelHourlySummaryRow(
                label: "Avg Active",
                value: "",
                accent: Color(red: 1.0, green: 0.8, blue: 0.35)),
        ]
    }

    private var peakHourLabel: String {
        guard let peak = usage.peakTokenBucket else { return "N/A" }
        return PanelHourlyFormatters.hourRange(for: peak)
    }

    private var hourlyTotal: Int {
        activeBuckets.reduce(0) { $0 + $1.totalTokens }
    }

    private var averageActiveTokens: Int {
        guard !activeBuckets.isEmpty else { return 0 }
        return hourlyTotal / activeBuckets.count
    }
}

private struct PanelHourlySummaryRow {
    let label: String
    let value: String
    let accent: Color
}

private struct PanelHourlySummaryView: View {
    let rows: [PanelHourlySummaryRow]
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
                                        .minimumScaleFactor(0.8)
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

private struct PanelHourlyBucketRowView: View, Equatable {
    let bucket: UsageTimeBucket
    let rank: Int
    let maxTokenCount: Int

    var body: some View {
        HStack(alignment: .center, spacing: 8) {
            Text("\(rank)")
                .font(.system(size: 10, weight: .bold, design: .rounded))
                .foregroundColor(Color.white.opacity(0.32))
                .frame(width: 14, alignment: .trailing)

            VStack(alignment: .leading, spacing: 5) {
                HStack(alignment: .lastTextBaseline, spacing: 6) {
                    Text(PanelHourlyFormatters.hourRange(for: bucket))
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(Color.white.opacity(0.5))
                        .lineLimit(1)

                    Text(bucket.cost > 0 ? bucket.cost.formattedCost() : "-")
                        .font(.system(size: 10, weight: .semibold, design: .rounded))
                        .foregroundColor(Color.white.opacity(0.25))
                        .lineLimit(1)
                }

                GeometryReader { geometry in
                    ZStack(alignment: .leading) {
                        RoundedRectangle(cornerRadius: 2, style: .continuous)
                            .fill(Color.white.opacity(0.06))
                        RoundedRectangle(cornerRadius: 2, style: .continuous)
                            .fill(Color(red: 0.45, green: 0.75, blue: 1.0).opacity(0.58))
                            .frame(width: geometry.size.width * barFraction)
                    }
                }
                .frame(height: 4)
            }

            Spacer(minLength: 8)

            Text(bucket.totalTokens.formattedTokens())
                .font(.system(size: 11, weight: .semibold, design: .rounded))
                .foregroundColor(Color.white.opacity(0.76))
                .frame(width: 54, alignment: .trailing)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 7)
    }

    private var barFraction: CGFloat {
        guard maxTokenCount > 0 else { return 0 }
        return CGFloat(bucket.totalTokens) / CGFloat(maxTokenCount)
    }
}

private struct PanelHourlyBucketSkeletonRow: View {
    let width: CGFloat

    var body: some View {
        HStack(alignment: .center, spacing: 8) {
            SkeletonBar(width: 12, height: 10)
            VStack(alignment: .leading, spacing: 5) {
                SkeletonBar(width: width, height: 10)
                SkeletonBar(height: 4, cornerRadius: 2)
            }
            Spacer()
            SkeletonBar(width: 42, height: 10)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 7)
    }
}

private enum PanelHourlyFormatters {
    static func hourRange(for bucket: UsageTimeBucket) -> String {
        "\(hour.string(from: bucket.startDate))-\(hour.string(from: bucket.endDate))"
    }

    private static let hour: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "HH:mm"
        return formatter
    }()
}
