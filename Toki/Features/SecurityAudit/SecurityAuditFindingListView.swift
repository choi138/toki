import SwiftUI

struct SecurityAuditFindingListView: View {
    @ObservedObject var viewModel: SecurityAuditViewModel

    var body: some View {
        LazyVStack(spacing: 0) {
            SecurityAuditSectionCaption(title: "\(viewModel.filteredFindingCount) Findings")
            if viewModel.displayedFindings.isEmpty {
                Text("No matching findings")
                    .font(.system(size: 12))
                    .foregroundColor(Color.white.opacity(0.3))
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, 18)
            } else {
                ForEach(viewModel.displayedFindings) { finding in
                    SecurityFindingRowView(
                        finding: finding,
                        isCopied: viewModel.copiedFindingID == finding.id,
                        copyPath: { viewModel.copyPath(for: finding) },
                        copyMaskedFinding: { viewModel.copyMaskedFinding(finding) },
                        revealInFinder: { viewModel.revealInFinder(finding) })
                }

                if viewModel.canShowMoreFindings {
                    SecurityAuditShowMoreFindingsView(
                        visibleCount: viewModel.displayedFindings.count,
                        totalCount: viewModel.filteredFindingCount,
                        nextCount: viewModel.nextFindingPageCount,
                        action: viewModel.showMoreFindings)
                }
            }
        }
        .padding(.top, 4)
    }
}

private struct SecurityAuditShowMoreFindingsView: View {
    let visibleCount: Int
    let totalCount: Int
    let nextCount: Int
    let action: () -> Void

    var body: some View {
        VStack(spacing: 8) {
            Text("Showing \(visibleCount) of \(totalCount)")
                .font(.system(size: 10, weight: .medium))
                .foregroundColor(Color.white.opacity(0.34))

            Button(action: action) {
                HStack(spacing: 6) {
                    Image(systemName: "plus.circle")
                        .font(.system(size: 11, weight: .semibold))
                        .accessibilityHidden(true)
                    Text("Show \(nextCount) more")
                        .font(.system(size: 11, weight: .semibold))
                }
                .foregroundColor(Color.white.opacity(0.72))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
                .background(Color.white.opacity(0.06))
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text("Show more findings"))
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
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
