import AppKit
import Foundation

@MainActor
final class SecurityAuditViewModel: ObservableObject {
    @Published private(set) var result: SecurityAuditResult?
    @Published private(set) var isScanning = false
    @Published private(set) var copiedFindingID: SecurityFinding.ID?
    @Published private(set) var scanProgress: SecurityAuditProgress?
    @Published var selectedSeverity: SecuritySeverity?
    @Published var selectedCategory: SecurityFindingCategory?
    @Published var selectedSourceName: String?

    private let scanner: any SecurityAuditScanning

    init(scanner: any SecurityAuditScanning = SecurityAuditScanner()) {
        self.scanner = scanner
    }

    var findings: [SecurityFinding] {
        result?.findings ?? []
    }

    var filteredFindings: [SecurityFinding] {
        findings.filter { finding in
            if let selectedSeverity, finding.severity != selectedSeverity {
                return false
            }
            if let selectedCategory, finding.category != selectedCategory {
                return false
            }
            if let selectedSourceName, finding.sourceName != selectedSourceName {
                return false
            }
            return true
        }
    }

    var sourceNames: [String] {
        Array(Set(findings.map(\.sourceName))).sorted()
    }

    var categories: [SecurityFindingCategory] {
        Array(Set(findings.map(\.category))).sorted { $0.displayName < $1.displayName }
    }

    func scan() async {
        guard !isScanning else { return }

        isScanning = true
        scanProgress = .idle
        defer {
            isScanning = false
            scanProgress = nil
        }

        let scanResult = await scanner.scan(
            request: SecurityAuditRequest(),
            progress: { [weak self] progress in
                Task { @MainActor in
                    self?.scanProgress = progress
                }
            })
        result = scanResult
        clearUnavailableFilters()
    }

    func clearFilters() {
        selectedSeverity = nil
        selectedCategory = nil
        selectedSourceName = nil
    }

    func copyPath(for finding: SecurityFinding) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(finding.location.filePath, forType: .string)
        markCopied(finding.id)
    }

    func copyMaskedFinding(_ finding: SecurityFinding) {
        let summary = [
            "\(finding.sourceName) · \(finding.severity.displayName) · \(finding.category.displayName)",
            finding.maskedEvidence,
            "\(finding.location.filePath):\(finding.location.lineNumber)",
        ].joined(separator: "\n")
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(summary, forType: .string)
        markCopied(finding.id)
    }

    func revealInFinder(_ finding: SecurityFinding) {
        guard FileManager.default.fileExists(atPath: finding.location.filePath) else { return }
        NSWorkspace.shared.activateFileViewerSelecting([
            URL(fileURLWithPath: finding.location.filePath),
        ])
    }
}

private extension SecurityAuditViewModel {
    func clearUnavailableFilters() {
        if let selectedSeverity, !findings.contains(where: { $0.severity == selectedSeverity }) {
            self.selectedSeverity = nil
        }
        if let selectedCategory, !findings.contains(where: { $0.category == selectedCategory }) {
            self.selectedCategory = nil
        }
        if let selectedSourceName, !findings.contains(where: { $0.sourceName == selectedSourceName }) {
            self.selectedSourceName = nil
        }
    }

    func markCopied(_ findingID: SecurityFinding.ID) {
        copiedFindingID = findingID
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(1.6))
            if copiedFindingID == findingID {
                copiedFindingID = nil
            }
        }
    }
}
