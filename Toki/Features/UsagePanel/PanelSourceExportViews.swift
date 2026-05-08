import AppKit
import SwiftUI

struct PanelSourceView: View {
    let usage: UsageData
    let readerStatuses: [ReaderStatus]
    let isLoading: Bool

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

                if usage.sourceStats.isEmpty {
                    Text("No source data")
                        .font(.system(size: 12))
                        .foregroundColor(Color.white.opacity(0.3))
                        .frame(maxWidth: .infinity, alignment: .center)
                        .padding(.vertical, 18)
                } else {
                    PanelSectionCaption(title: "By Source")
                    ForEach(usage.sourceStats, id: \.id) { source in
                        SourceStatRowView(stat: source)
                            .equatable()
                    }
                }

                if !readerStatuses.isEmpty {
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
                .accessibilityLabel(Text("Copy \(format.rawValue)"))
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

private func panelAccentColor(forSource source: String) -> Color {
    switch source {
    case "Claude Code":
        Color(red: 0.55, green: 0.45, blue: 1.0)
    case "Codex":
        Color(red: 0.4, green: 0.9, blue: 0.5)
    case "Cursor":
        Color(red: 0.45, green: 0.75, blue: 1.0)
    case "Gemini CLI":
        Color(red: 0.3, green: 0.7, blue: 1.0)
    case "OpenCode":
        Color(red: 1.0, green: 0.72, blue: 0.35)
    case "OpenClaw":
        Color(red: 0.85, green: 0.68, blue: 1.0)
    default:
        Color.white.opacity(0.5)
    }
}
