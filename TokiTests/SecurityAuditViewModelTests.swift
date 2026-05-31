import XCTest
@testable import Toki

@MainActor
final class SecurityAuditViewModelTests: XCTestCase {
    func testScanCapsDisplayedFindingsForLargeResults() async {
        let viewModel = SecurityAuditViewModel(
            scanner: StubSecurityAuditScanner(result: result(findingCount: 450)))

        await viewModel.scan()

        XCTAssertEqual(viewModel.filteredFindingCount, 450)
        XCTAssertEqual(
            viewModel.displayedFindings.count,
            SecurityAuditViewModel.initialDisplayedFindingCount)
        XCTAssertEqual(viewModel.hiddenFindingCount, 250)
        XCTAssertTrue(viewModel.canShowMoreFindings)
    }

    func testShowMoreFindingsRevealsResultsIncrementally() async {
        let viewModel = SecurityAuditViewModel(
            scanner: StubSecurityAuditScanner(result: result(findingCount: 450)))

        await viewModel.scan()
        viewModel.showMoreFindings()

        XCTAssertEqual(viewModel.displayedFindings.count, 400)
        XCTAssertEqual(viewModel.hiddenFindingCount, 50)

        viewModel.showMoreFindings()

        XCTAssertEqual(viewModel.displayedFindings.count, 450)
        XCTAssertEqual(viewModel.hiddenFindingCount, 0)
        XCTAssertFalse(viewModel.canShowMoreFindings)
    }

    func testFilteringResetsDisplayedFindingsToMatchingSubset() async {
        let findings = makeFindings(count: 250, sourceName: "Codex")
            + makeFindings(count: 12, sourceName: "Claude Code", startingLineNumber: 1000)
        let viewModel = SecurityAuditViewModel(
            scanner: StubSecurityAuditScanner(result: result(findings: findings)))

        await viewModel.scan()
        viewModel.showMoreFindings()
        viewModel.selectedSourceName = "Claude Code"

        XCTAssertEqual(viewModel.filteredFindingCount, 12)
        XCTAssertEqual(viewModel.displayedFindings.count, 12)
        XCTAssertEqual(viewModel.hiddenFindingCount, 0)
        XCTAssertFalse(viewModel.canShowMoreFindings)
    }

    func testReselectingSameFilterDoesNotResetDisplayedFindings() async {
        let findings = makeFindings(count: 250, sourceName: "Codex")
            + makeFindings(count: 12, sourceName: "Claude Code", startingLineNumber: 1000)
        let viewModel = SecurityAuditViewModel(
            scanner: StubSecurityAuditScanner(result: result(findings: findings)))

        await viewModel.scan()
        viewModel.selectedSourceName = "Codex"
        viewModel.showMoreFindings()
        viewModel.selectedSourceName = "Codex"

        XCTAssertEqual(viewModel.filteredFindingCount, 250)
        XCTAssertEqual(viewModel.displayedFindings.count, 250)
        XCTAssertEqual(viewModel.hiddenFindingCount, 0)
    }
}

private struct StubSecurityAuditScanner: SecurityAuditScanning {
    let result: SecurityAuditResult

    func scan(
        request: SecurityAuditRequest,
        progress: SecurityAuditProgressHandler?) async -> SecurityAuditResult {
        progress?(SecurityAuditProgress(
            phase: .finished,
            currentSourceName: nil,
            currentFileName: nil,
            completedFileCount: result.scannedFileCount,
            totalFileCount: result.scannedFileCount,
            scannedLineCount: result.scannedLineCount,
            findingCount: result.findings.count))
        return result
    }
}

private func result(findingCount: Int) -> SecurityAuditResult {
    result(findings: makeFindings(count: findingCount, sourceName: "Codex"))
}

private func result(findings: [SecurityFinding]) -> SecurityAuditResult {
    SecurityAuditResult(
        scannedAt: Date(timeIntervalSince1970: 0),
        scannedSourceCount: 1,
        scannedFileCount: 1,
        scannedLineCount: findings.count,
        skippedSourceNames: [],
        findings: findings)
}

private func makeFindings(
    count: Int,
    sourceName: String,
    startingLineNumber: Int = 0) -> [SecurityFinding] {
    (0..<count).map { index in
        let lineNumber = startingLineNumber + index + 1
        return SecurityFinding(
            sourceName: sourceName,
            severity: index.isMultiple(of: 2) ? .high : .medium,
            category: .environmentSecret,
            ruleName: "Secret assignment",
            maskedEvidence: "tokn...\(lineNumber)",
            location: SecurityFindingLocation(
                filePath: "/tmp/\(sourceName)-session.jsonl",
                lineNumber: lineNumber),
            detectedAt: nil)
    }
}
