import SwiftUI

struct SecurityAuditView: View {
    @StateObject private var viewModel: SecurityAuditViewModel

    @MainActor
    init(viewModel: SecurityAuditViewModel? = nil) {
        _viewModel = StateObject(wrappedValue: viewModel ?? SecurityAuditViewModel())
    }

    var body: some View {
        VStack(spacing: 0) {
            SecurityAuditHeaderView()
            divider
            ScrollView(.vertical) {
                SecurityAuditContentView(viewModel: viewModel)
                    .padding(.vertical, 8)
            }
        }
        .frame(width: 360, height: 520)
        .background(Color(red: 0.09, green: 0.09, blue: 0.11))
        .preferredColorScheme(.dark)
    }

    private var divider: some View {
        Rectangle()
            .fill(Color.white.opacity(0.07))
            .frame(height: 0.5)
    }
}

private struct SecurityAuditHeaderView: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        HStack {
            Label {
                Text("Security Audit")
                    .font(.system(size: 13, weight: .semibold))
            } icon: {
                Image(systemName: "shield.lefthalf.filled")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(Color(red: 0.4, green: 0.9, blue: 0.6))
            }
            .foregroundColor(.white)

            Spacer()

            Button {
                dismiss()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(Color.white.opacity(0.42))
                    .frame(width: 18, height: 18)
                    .contentShape(Rectangle())
                    .accessibilityHidden(true)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text("Close security audit"))
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }
}

private struct SecurityAuditContentView: View {
    @ObservedObject var viewModel: SecurityAuditViewModel

    var body: some View {
        VStack(spacing: 0) {
            SecurityAuditScanControlsView(viewModel: viewModel)

            if viewModel.isScanning {
                SecurityAuditLoadingView(progress: viewModel.scanProgress)
            } else if let result = viewModel.result {
                SecurityAuditSummaryView(result: result)
                if result.hasFindings {
                    SecurityAuditFiltersView(viewModel: viewModel)
                    SecurityAuditFindingListView(viewModel: viewModel)
                } else {
                    SecurityAuditMessageView(
                        systemImage: "checkmark.shield",
                        title: "No findings",
                        detail: "Scanned sources are clear")
                }
            } else {
                SecurityAuditMessageView(
                    systemImage: "shield",
                    title: "Ready",
                    detail: "Local logs only")
            }
        }
    }
}

private struct SecurityAuditScanControlsView: View {
    @ObservedObject var viewModel: SecurityAuditViewModel

    var body: some View {
        HStack(spacing: 8) {
            Button {
                Task { await viewModel.scan() }
            } label: {
                scanButtonLabel
            }
            .buttonStyle(.plain)
            .disabled(viewModel.isScanning)
            .accessibilityLabel(Text(viewModel.isScanning ? "Scanning logs" : "Scan logs"))

            if viewModel.result?.hasFindings == true {
                clearFiltersButton
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }

    private var scanButtonLabel: some View {
        HStack(spacing: 6) {
            if viewModel.isScanning {
                ProgressView()
                    .scaleEffect(0.55)
                    .frame(width: 14, height: 14)
                    .accessibilityHidden(true)
            } else {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 11, weight: .semibold))
                    .accessibilityHidden(true)
            }
            Text(viewModel.result == nil ? "Scan Logs" : "Rescan")
                .font(.system(size: 11, weight: .semibold))
        }
        .foregroundColor(.white.opacity(0.78))
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
        .background(Color.white.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
    }

    private var clearFiltersButton: some View {
        Button {
            viewModel.clearFilters()
        } label: {
            Image(systemName: "line.3.horizontal.decrease.circle")
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(Color.white.opacity(0.46))
                .frame(width: 30, height: 30)
                .contentShape(Rectangle())
                .accessibilityHidden(true)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text("Clear filters"))
    }
}

private struct SecurityAuditSummaryView: View {
    let result: SecurityAuditResult

    var body: some View {
        VStack(spacing: 8) {
            HStack(spacing: 8) {
                SeveritySummaryView(
                    title: "High",
                    count: result.count(for: .high),
                    color: Color(red: 1.0, green: 0.45, blue: 0.35))
                SeveritySummaryView(
                    title: "Medium",
                    count: result.count(for: .medium),
                    color: Color(red: 1.0, green: 0.8, blue: 0.35))
                SeveritySummaryView(
                    title: "Low",
                    count: result.count(for: .low),
                    color: Color.white.opacity(0.38))
            }

            HStack(spacing: 8) {
                Text("\(result.scannedFileCount) files")
                Text("\(result.scannedLineCount) lines")
                Text(Self.timeFormatter.string(from: result.scannedAt))
            }
            .font(.system(size: 10, weight: .medium))
            .foregroundColor(Color.white.opacity(0.32))
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 8)
    }

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "HH:mm:ss"
        return formatter
    }()
}

private struct SecurityAuditFiltersView: View {
    @ObservedObject var viewModel: SecurityAuditViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            SecurityAuditSectionCaption(title: "Filters")
            HStack(spacing: 8) {
                severityFilter
                categoryFilter
                sourceFilter
            }
            .padding(.horizontal, 16)
        }
        .padding(.vertical, 4)
    }

    private var severityFilter: some View {
        SecurityFilterMenu(
            title: "Severity",
            value: viewModel.selectedSeverity?.displayName ?? "All") {
                Button("All") { viewModel.selectedSeverity = nil }
                Divider()
                ForEach(SecuritySeverity.allCases) { severity in
                    Button(severity.displayName) { viewModel.selectedSeverity = severity }
                }
            }
    }

    private var categoryFilter: some View {
        SecurityFilterMenu(
            title: "Category",
            value: viewModel.selectedCategory?.displayName ?? "All") {
                Button("All") { viewModel.selectedCategory = nil }
                Divider()
                ForEach(viewModel.categories) { category in
                    Button(category.displayName) { viewModel.selectedCategory = category }
                }
            }
    }

    private var sourceFilter: some View {
        SecurityFilterMenu(
            title: "Source",
            value: viewModel.selectedSourceName ?? "All") {
                Button("All") { viewModel.selectedSourceName = nil }
                Divider()
                ForEach(viewModel.sourceNames, id: \.self) { sourceName in
                    Button(sourceName) { viewModel.selectedSourceName = sourceName }
                }
            }
    }
}

private struct SecurityAuditFindingListView: View {
    @ObservedObject var viewModel: SecurityAuditViewModel

    var body: some View {
        VStack(spacing: 0) {
            SecurityAuditSectionCaption(title: "\(viewModel.filteredFindings.count) Findings")
            if viewModel.filteredFindings.isEmpty {
                Text("No matching findings")
                    .font(.system(size: 12))
                    .foregroundColor(Color.white.opacity(0.3))
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, 18)
            } else {
                ForEach(viewModel.filteredFindings) { finding in
                    SecurityFindingRowView(
                        finding: finding,
                        isCopied: viewModel.copiedFindingID == finding.id,
                        copyPath: { viewModel.copyPath(for: finding) },
                        copyMaskedFinding: { viewModel.copyMaskedFinding(finding) },
                        revealInFinder: { viewModel.revealInFinder(finding) })
                }
            }
        }
        .padding(.top, 4)
    }
}

private struct SecurityAuditLoadingView: View {
    let progress: SecurityAuditProgress?

    var body: some View {
        VStack(spacing: 10) {
            SecurityAuditSectionCaption(title: "Scanning")
            SecurityAuditProgressStatusView(progress: progress)
            ForEach(0..<5, id: \.self) { index in
                HStack(spacing: 8) {
                    SecurityAuditSkeletonBar(width: 6, height: 6, cornerRadius: 3)
                    VStack(alignment: .leading, spacing: 5) {
                        SecurityAuditSkeletonBar(width: CGFloat(118 + index * 12), height: 11)
                        SecurityAuditSkeletonBar(width: CGFloat(190 - index * 10), height: 9)
                    }
                    Spacer()
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
            }
        }
    }
}

private struct SecurityAuditProgressStatusView: View {
    let progress: SecurityAuditProgress?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text(title)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(Color.white.opacity(0.82))
                Spacer()
                Text(countText)
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .foregroundColor(Color.white.opacity(0.42))
            }

            progressView

            HStack(spacing: 8) {
                Text(detail)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 8)
                Text(metricText)
                    .lineLimit(1)
            }
            .font(.system(size: 10, weight: .medium))
            .foregroundColor(Color.white.opacity(0.36))
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(Color.white.opacity(0.045))
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        .padding(.horizontal, 16)
    }

    @ViewBuilder
    private var progressView: some View {
        if let fractionCompleted = progress?.fractionCompleted {
            ProgressView(value: fractionCompleted, total: 1)
                .progressViewStyle(.linear)
                .tint(Color(red: 0.4, green: 0.9, blue: 0.6))
        } else {
            ProgressView()
                .scaleEffect(0.55, anchor: .leading)
                .frame(height: 4, alignment: .leading)
                .tint(Color(red: 0.4, green: 0.9, blue: 0.6))
        }
    }

    private var title: String {
        switch progress?.phase ?? .preparing {
        case .preparing:
            "Preparing scan"
        case .discovering:
            "Discovering files"
        case .scanning:
            "Scanning logs"
        case .finished:
            "Finishing scan"
        }
    }

    private var countText: String {
        guard let progress, progress.totalFileCount > 0 else {
            return "..."
        }
        return "\(progress.completedFileCount)/\(progress.totalFileCount)"
    }

    private var detail: String {
        guard let progress else { return "Preparing sources" }

        switch (progress.currentSourceName, progress.currentFileName) {
        case let (source?, file?):
            return "\(source) · \(file)"
        case let (source?, nil):
            return source
        default:
            return "Local log sources"
        }
    }

    private var metricText: String {
        guard let progress else { return "0 lines · 0 findings" }
        return "\(progress.scannedLineCount) lines · \(progress.findingCount) findings"
    }
}

private struct SeveritySummaryView: View {
    let title: String
    let count: Int
    let color: Color

    private var hasCount: Bool {
        count.signum() == 1
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title.uppercased())
                .font(.system(size: 9, weight: .semibold))
                .foregroundColor(Color.white.opacity(0.28))
            HStack(alignment: .center, spacing: 5) {
                Circle()
                    .fill(color.opacity(hasCount ? 0.8 : 0.28))
                    .frame(width: 6, height: 6)
                Text("\(count)")
                    .font(.system(size: 18, weight: .bold, design: .rounded))
                    .foregroundColor(Color.white.opacity(hasCount ? 0.88 : 0.4))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 10)
        .padding(.vertical, 9)
        .background(Color.white.opacity(0.045))
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
    }
}

private struct SecurityAuditSectionCaption: View {
    let title: String

    var body: some View {
        Text(title.uppercased())
            .font(.system(size: 9, weight: .semibold))
            .foregroundColor(Color.white.opacity(0.28))
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 16)
            .padding(.vertical, 6)
    }
}

private struct SecurityAuditSkeletonBar: View {
    var width: CGFloat?
    var height: CGFloat = 12
    var cornerRadius: CGFloat = 4

    @State private var opacity = 0.18

    var body: some View {
        RoundedRectangle(cornerRadius: cornerRadius)
            .fill(Color.white.opacity(opacity))
            .frame(width: width, height: height)
            .onAppear {
                withAnimation(.easeInOut(duration: 0.85).repeatForever(autoreverses: true)) {
                    opacity = 0.06
                }
            }
    }
}

private struct SecurityFilterMenu<Content: View>: View {
    let title: String
    let value: String
    private let content: () -> Content

    init(
        title: String,
        value: String,
        @ViewBuilder content: @escaping () -> Content) {
        self.title = title
        self.value = value
        self.content = content
    }

    var body: some View {
        Menu {
            content()
        } label: {
            HStack(spacing: 4) {
                Text(value)
                    .font(.system(size: 10, weight: .semibold))
                    .lineLimit(1)
                Image(systemName: "chevron.down")
                    .font(.system(size: 8, weight: .semibold))
                    .accessibilityHidden(true)
            }
            .foregroundColor(Color.white.opacity(0.68))
            .frame(maxWidth: .infinity)
            .padding(.vertical, 6)
            .background(Color.white.opacity(0.06))
            .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(title))
        .accessibilityValue(Text(value))
    }
}

private struct SecurityFindingRowView: View {
    let finding: SecurityFinding
    let isCopied: Bool
    let copyPath: () -> Void
    let copyMaskedFinding: () -> Void
    let revealInFinder: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            severityDot
            findingText
            Spacer(minLength: 6)
            actionMenu
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }

    private var severityDot: some View {
        Circle()
            .fill(severityColor.opacity(0.75))
            .frame(width: 6, height: 6)
            .padding(.top, 4)
    }

    private var findingText: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 5) {
                Text(finding.sourceName)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(Color.white.opacity(0.62))
                    .lineLimit(1)
                Text(finding.category.displayName)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(severityColor.opacity(0.82))
                    .lineLimit(1)
            }

            Text(finding.maskedEvidence)
                .font(.system(size: 12, weight: .semibold, design: .monospaced))
                .foregroundColor(Color.white.opacity(0.82))
                .lineLimit(1)

            Text("\(shortPath):\(finding.location.lineNumber)")
                .font(.system(size: 10))
                .foregroundColor(Color.white.opacity(0.32))
                .lineLimit(1)
        }
    }

    private var actionMenu: some View {
        Menu {
            Button(isCopied ? "Copied" : "Copy Masked Finding", action: copyMaskedFinding)
            Button("Copy Path", action: copyPath)
            Button("Reveal in Finder", action: revealInFinder)
        } label: {
            Image(systemName: "ellipsis.circle")
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(Color.white.opacity(0.38))
                .frame(width: 18, height: 18)
                .accessibilityHidden(true)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text("Finding actions"))
    }

    private var severityColor: Color {
        switch finding.severity {
        case .high:
            Color(red: 1.0, green: 0.45, blue: 0.35)
        case .medium:
            Color(red: 1.0, green: 0.8, blue: 0.35)
        case .low:
            Color.white.opacity(0.42)
        }
    }

    private var shortPath: String {
        let url = URL(fileURLWithPath: finding.location.filePath)
        let parent = url.deletingLastPathComponent().lastPathComponent
        if parent.isEmpty {
            return url.lastPathComponent
        }
        return "\(parent)/\(url.lastPathComponent)"
    }
}

private struct SecurityAuditMessageView: View {
    let systemImage: String
    let title: String
    let detail: String

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: systemImage)
                .font(.system(size: 26, weight: .semibold))
                .foregroundColor(Color.white.opacity(0.28))
                .padding(.top, 34)
            Text(title)
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(Color.white.opacity(0.62))
            Text(detail)
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(Color.white.opacity(0.32))
        }
        .frame(maxWidth: .infinity)
        .padding(.bottom, 34)
    }
}
