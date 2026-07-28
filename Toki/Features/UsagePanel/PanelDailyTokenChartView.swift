import Charts
import SwiftUI

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
                Text(usage.totalTokens > 0 ? "No hourly detail" : "No hourly data")
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
