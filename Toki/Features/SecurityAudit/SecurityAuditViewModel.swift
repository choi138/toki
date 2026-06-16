import AppKit
import Foundation

@MainActor
final class SecurityAuditViewModel: ObservableObject {
    nonisolated static let initialDisplayedFindingCount = 200
    nonisolated static let displayedFindingPageSize = 200

    @Published private(set) var result: SecurityAuditResult?
    @Published private(set) var isScanning = false
    @Published private(set) var copiedFindingID: SecurityFinding.ID?
    @Published private(set) var scanProgress: SecurityAuditProgress?
    @Published private(set) var displayedFindings: [SecurityFinding] = []
    @Published private(set) var filteredFindingCount = 0
    @Published private(set) var sourceNames: [String] = []
    @Published private(set) var categories: [SecurityFindingCategory] = []
    @Published private(set) var severityCounts: [SecuritySeverity: Int] = [:]
    @Published var selectedSeverity: SecuritySeverity? {
        didSet {
            guard oldValue != selectedSeverity else { return }
            updateFilteredFindings(resetDisplayLimit: true)
        }
    }

    @Published var selectedCategory: SecurityFindingCategory? {
        didSet {
            guard oldValue != selectedCategory else { return }
            updateFilteredFindings(resetDisplayLimit: true)
        }
    }

    @Published var selectedSourceName: String? {
        didSet {
            guard oldValue != selectedSourceName else { return }
            updateFilteredFindings(resetDisplayLimit: true)
        }
    }

    private let scanner: any SecurityAuditScanning
    private var filteredFindings: [SecurityFinding] = []
    private var findingDisplayLimit = SecurityAuditViewModel.initialDisplayedFindingCount
    private var scanTask: Task<Void, Never>?
    private var scanGeneration = 0

    init(scanner: any SecurityAuditScanning = SecurityAuditScanner()) {
        self.scanner = scanner
    }

    deinit {
        scanTask?.cancel()
    }

    var findings: [SecurityFinding] {
        result?.findings ?? []
    }

    var hiddenFindingCount: Int {
        max(0, filteredFindingCount - displayedFindings.count)
    }

    var canShowMoreFindings: Bool {
        hiddenFindingCount > 0
    }

    var nextFindingPageCount: Int {
        min(Self.displayedFindingPageSize, hiddenFindingCount)
    }

    func startScan() {
        guard scanTask == nil, !isScanning else { return }

        scanTask = Task { [weak self] in
            await self?.scan()
        }
    }

    func cancelScan() {
        scanTask?.cancel()
        scanTask = nil
        scanGeneration += 1
        isScanning = false
        scanProgress = nil
    }

    func scan() async {
        guard !isScanning else { return }

        scanGeneration += 1
        let currentScanGeneration = scanGeneration
        isScanning = true
        result = nil
        resetFindingPresentation()
        scanProgress = .idle
        defer {
            if scanGeneration == currentScanGeneration {
                isScanning = false
                scanProgress = nil
                scanTask = nil
            }
        }

        let scanResult = await scanner.scan(
            request: SecurityAuditRequest(),
            progress: { [weak self, currentScanGeneration] progress in
                Task { @MainActor in
                    guard let self,
                          self.isScanning,
                          self.scanGeneration == currentScanGeneration else {
                        return
                    }
                    self.scanProgress = progress
                }
            })
        guard !Task.isCancelled, scanGeneration == currentScanGeneration else { return }

        rebuildFindingPresentation(for: scanResult.findings)
        result = scanResult
        clearUnavailableFilters()
    }

    func count(for severity: SecuritySeverity) -> Int {
        severityCounts[severity] ?? 0
    }

    func clearFilters() {
        selectedSeverity = nil
        selectedCategory = nil
        selectedSourceName = nil
    }

    func showMoreFindings() {
        findingDisplayLimit = min(
            findingDisplayLimit + Self.displayedFindingPageSize,
            filteredFindings.count)
        updateDisplayedFindings()
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
    func rebuildFindingPresentation(for findings: [SecurityFinding]) {
        sourceNames = Array(Set(findings.map(\.sourceName))).sorted()
        categories = Array(Set(findings.map(\.category))).sorted { $0.displayName < $1.displayName }
        severityCounts = Dictionary(grouping: findings, by: \.severity).mapValues(\.count)
        updateFilteredFindings(resetDisplayLimit: true, findings: findings)
    }

    func resetFindingPresentation() {
        sourceNames = []
        categories = []
        severityCounts = [:]
        filteredFindings = []
        filteredFindingCount = 0
        displayedFindings = []
        findingDisplayLimit = Self.initialDisplayedFindingCount
    }

    func updateFilteredFindings(resetDisplayLimit: Bool, findings sourceFindings: [SecurityFinding]? = nil) {
        let allFindings = sourceFindings ?? findings
        if resetDisplayLimit {
            findingDisplayLimit = Self.initialDisplayedFindingCount
        }
        filteredFindings = allFindings.filter { finding in
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
        filteredFindingCount = filteredFindings.count
        updateDisplayedFindings()
    }

    func updateDisplayedFindings() {
        displayedFindings = Array(filteredFindings.prefix(findingDisplayLimit))
    }

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
