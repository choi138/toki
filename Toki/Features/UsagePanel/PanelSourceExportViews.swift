import AppKit
import SwiftUI

struct PanelSourceView: View {
    let usage: UsageData
    let originReports: [UsageOriginReport]
    let selectedScope: UsageScope
    let scopeTitle: String
    let readerStatuses: [ReaderStatus]
    let isLoading: Bool
    let onSelectOrigin: (UsageOriginID) -> Void

    @State private var copiedFormat: UsageExportFormat?

    var body: some View {
        VStack(spacing: 0) {
            if isLoading {
                VStack(spacing: 0) {
                    ForEach(0..<4, id: \.self) { index in
                        skeletonSourceRow(width: CGFloat(68 + index * 12))
                    }
                }
                .padding(.vertical, 6)
            } else {
                exportControls

                if selectedScope == .all, originReports.count > 1 {
                    PanelDeviceBreakdownView(
                        reports: originReports,
                        onSelect: onSelectOrigin)
                }

                if usage.sourceStats.isEmpty {
                    Text("No source data")
                        .font(.system(size: 12))
                        .foregroundColor(Color.white.opacity(0.3))
                        .frame(maxWidth: .infinity, alignment: .center)
                        .padding(.vertical, 18)
                } else {
                    PanelSectionCaption(title: "By Tool")
                    ForEach(usage.sourceStats, id: \.id) { source in
                        SourceStatRowView(stat: source)
                            .equatable()
                    }
                }

                if selectedScope == .all, !readerStatuses.isEmpty {
                    PanelSectionCaption(title: "Reader Status")
                    ForEach(readerStatuses) { status in
                        ReaderStatusRowView(status: status)
                            .equatable()
                    }
                }
            }
        }
        .padding(.vertical, 6)
    }

    private var exportControls: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("EXPORT CURRENT VIEW · \(scopeTitle)")
                .font(.system(size: 9, weight: .semibold))
                .foregroundColor(Color.white.opacity(0.28))
                .lineLimit(1)

            HStack(spacing: 8) {
                ForEach(UsageExportFormat.allCases, id: \.self) { format in
                    Button {
                        copyUsageExport(usage, format: format)
                        copiedFormat = format
                        Task { @MainActor in
                            try? await Task.sleep(for: .seconds(2))
                            if copiedFormat == format {
                                copiedFormat = nil
                            }
                        }
                    } label: {
                        Text(copiedFormat == format ? "Copied" : format.rawValue)
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundColor(.white.opacity(0.72))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 6)
                            .background(Color.white.opacity(copiedFormat == format ? 0.12 : 0.07))
                            .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(Text("Copy \(scopeTitle) as \(format.rawValue)"))
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }

    private func skeletonSourceRow(width: CGFloat) -> some View {
        HStack(alignment: .center, spacing: 6) {
            Circle()
                .fill(Color.white.opacity(0.08))
                .frame(width: 5, height: 5)
            SkeletonBar(width: width, height: 10)
            Spacer()
            SkeletonBar(width: 40, height: 10)
            SkeletonBar(width: 42, height: 10)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 7)
    }
}

struct PanelDeviceBreakdownView: View {
    let reports: [UsageOriginReport]
    let onSelect: (UsageOriginID) -> Void

    var body: some View {
        VStack(spacing: 0) {
            PanelSectionCaption(title: "By Device")
            ForEach(reports) { report in
                PanelDeviceUsageRow(report: report) {
                    onSelect(report.id)
                }
            }
        }
    }
}

private struct PanelDeviceUsageRow: View {
    let report: UsageOriginReport
    let onSelect: () -> Void

    var body: some View {
        Button(action: onSelect) {
            HStack(alignment: .center, spacing: 8) {
                Image(systemName: panelDeviceSystemImage(for: report.origin))
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(deviceColor.opacity(0.72))
                    .frame(width: 16)
                VStack(alignment: .leading, spacing: 3) {
                    Text(report.origin.name)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(Color.white.opacity(0.62))
                        .lineLimit(1)
                    Text(statusText)
                        .font(.system(size: 9, weight: .medium))
                        .foregroundColor(Color.white.opacity(0.3))
                        .lineLimit(1)
                }
                Spacer(minLength: 4)
                Text(report.usageData.totalTokens.formattedTokens())
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                    .foregroundColor(Color.white.opacity(0.7))
                    .frame(width: 44, alignment: .trailing)
                Text(report.usageData.cost > 0 ? report.usageData.cost.formattedCost() : "—")
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                    .foregroundColor(
                        report.usageData.cost > 0
                            ? Color(red: 0.4, green: 0.9, blue: 0.6)
                            : Color.white.opacity(0.25))
                    .frame(width: 56, alignment: .trailing)
                    .lineLimit(1)
            }
            .contentShape(Rectangle())
            .padding(.horizontal, 16)
            .padding(.vertical, 7)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(accessibilityLabel))
        .accessibilityHint(Text("Show usage from this device"))
    }

    private var statusText: String {
        let platform = panelDevicePlatformLabel(for: report.origin)
        guard let updatedAt = report.origin.lastUpdatedAt else { return platform }
        let now = Date()
        let safeUpdatedAt = min(updatedAt, now)
        let relative = Self.relativeDateFormatter.localizedString(
            for: safeUpdatedAt,
            relativeTo: now)
        let verb = panelDeviceUpdateLabel(for: report.origin)
        return "\(platform) · \(verb) \(relative)"
    }

    private var deviceColor: Color {
        report.origin.kind == .remote
            ? Color(red: 0.7, green: 0.62, blue: 1.0)
            : Color(red: 0.4, green: 0.75, blue: 1.0)
    }

    private var accessibilityLabel: String {
        "\(report.origin.name), \(panelDevicePlatformLabel(for: report.origin)), "
            + "\(report.usageData.totalTokens) tokens, \(report.usageData.cost.formattedCost())"
    }

    private static let relativeDateFormatter: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter
    }()
}

private func copyUsageExport(_ usage: UsageData, format: UsageExportFormat) {
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(UsageExport.string(for: usage, format: format), forType: .string)
}

private struct SourceStatRowView: View, Equatable {
    let stat: SourceStat

    var body: some View {
        HStack(alignment: .center, spacing: 6) {
            Circle()
                .fill(panelAccentColor(forSource: stat.source).opacity(0.55))
                .frame(width: 5, height: 5)
            VStack(alignment: .leading, spacing: 3) {
                Text(stat.source)
                    .font(.system(size: 11))
                    .foregroundColor(Color.white.opacity(0.48))
                    .lineLimit(1)
                Text(stat.activeSeconds > 0 ? "\(stat.activeSeconds.formattedWorkDuration()) used" : "0s used")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundColor(Color.white.opacity(0.3))
                    .lineLimit(1)
            }
            Spacer()
            Text(stat.totalTokens.formattedTokens())
                .font(.system(size: 11, weight: .semibold, design: .rounded))
                .foregroundColor(Color.white.opacity(0.7))
                .frame(width: 44, alignment: .trailing)
            Text(stat.cost > 0 ? stat.cost.formattedCost() : "—")
                .font(.system(size: 11, weight: .semibold, design: .rounded))
                .foregroundColor(stat.cost > 0 ? Color(red: 0.4, green: 0.9, blue: 0.6) : Color.white.opacity(0.25))
                .frame(width: 56, alignment: .trailing)
                .lineLimit(1)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 7)
    }
}

private struct ReaderStatusRowView: View, Equatable {
    let status: ReaderStatus

    var body: some View {
        HStack(alignment: .center, spacing: 6) {
            Circle()
                .fill(stateColor.opacity(0.6))
                .frame(width: 5, height: 5)
            VStack(alignment: .leading, spacing: 3) {
                Text(status.name)
                    .font(.system(size: 11))
                    .foregroundColor(Color.white.opacity(0.48))
                    .lineLimit(1)
                Text(status.message ?? statusText)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundColor(Color.white.opacity(0.3))
                    .lineLimit(1)
            }
            Spacer()
            Text(status.totalTokens > 0 ? status.totalTokens.formattedTokens() : "—")
                .font(.system(size: 11, weight: .semibold, design: .rounded))
                .foregroundColor(Color.white.opacity(0.62))
                .frame(width: 44, alignment: .trailing)
            Text(status.state.rawValue.capitalized)
                .font(.system(size: 10, weight: .semibold, design: .rounded))
                .foregroundColor(stateColor.opacity(0.78))
                .frame(width: 56, alignment: .trailing)
                .lineLimit(1)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 7)
    }

    private var statusText: String {
        switch status.state {
        case .loaded:
            if let lastReadAt = status.lastReadAt {
                "Read \(Self.timeFormatter.string(from: lastReadAt))"
            } else {
                "Loaded"
            }
        case .empty:
            "No local data"
        case .disabled:
            "Off"
        case .failed:
            "Read failed"
        }
    }

    private var stateColor: Color {
        switch status.state {
        case .loaded:
            Color(red: 0.4, green: 0.9, blue: 0.6)
        case .empty:
            Color.white.opacity(0.35)
        case .disabled:
            Color(red: 1.0, green: 0.8, blue: 0.35)
        case .failed:
            Color(red: 1.0, green: 0.45, blue: 0.35)
        }
    }

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "HH:mm:ss"
        return formatter
    }()
}
