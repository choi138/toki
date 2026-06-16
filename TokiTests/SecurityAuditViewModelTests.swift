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

    func testCancelScanClearsScanningStateAndIgnoresLateResult() async {
        let viewModel = SecurityAuditViewModel(
            scanner: SlowSecurityAuditScanner(result: result(findingCount: 1)))

        viewModel.startScan()
        await waitUntil { viewModel.isScanning }

        viewModel.cancelScan()
        try? await Task.sleep(for: .milliseconds(50))

        XCTAssertFalse(viewModel.isScanning)
        XCTAssertNil(viewModel.result)
        XCTAssertTrue(viewModel.displayedFindings.isEmpty)
    }

    func testRestartingScanAfterCancelKeepsNewScanActive() async {
        let scanner = SequencedDelayedSecurityAuditScanner(
            results: [
                result(findings: makeFindings(count: 1, sourceName: "Old")),
                result(findings: makeFindings(count: 2, sourceName: "New")),
            ],
            delaysInMilliseconds: [120, 260])
        let viewModel = SecurityAuditViewModel(scanner: scanner)

        viewModel.startScan()
        await waitUntil { viewModel.isScanning }

        viewModel.cancelScan()
        viewModel.startScan()
        await waitUntil { scanner.callCount == 2 && viewModel.isScanning }
        try? await Task.sleep(for: .milliseconds(180))

        XCTAssertTrue(viewModel.isScanning)
        XCTAssertNil(viewModel.result)

        await waitUntil(timeout: 0.5) { viewModel.result?.findings.first?.sourceName == "New" }

        XCTAssertFalse(viewModel.isScanning)
        XCTAssertEqual(viewModel.findings.count, 2)
        XCTAssertEqual(viewModel.findings.first?.sourceName, "New")
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

private struct SlowSecurityAuditScanner: SecurityAuditScanning {
    let result: SecurityAuditResult

    func scan(
        request: SecurityAuditRequest,
        progress: SecurityAuditProgressHandler?) async -> SecurityAuditResult {
        progress?(.idle)
        try? await Task.sleep(for: .seconds(1))
        return result
    }
}

private final class SequencedDelayedSecurityAuditScanner: SecurityAuditScanning {
    private let results: [SecurityAuditResult]
    private let delaysInMilliseconds: [Int]
    private let stateQueue = DispatchQueue(label: "toki.tests.security-audit-sequenced-scanner")
    private var nextIndex = 0

    init(results: [SecurityAuditResult], delaysInMilliseconds: [Int]) {
        self.results = results
        self.delaysInMilliseconds = delaysInMilliseconds
    }

    var callCount: Int {
        stateQueue.sync { nextIndex }
    }

    func scan(
        request: SecurityAuditRequest,
        progress: SecurityAuditProgressHandler?) async -> SecurityAuditResult {
        let index = nextCallIndex()
        progress?(.idle)
        await sleepIgnoringCancellation(milliseconds: value(at: index, in: delaysInMilliseconds))
        return value(at: index, in: results)
    }

    private func nextCallIndex() -> Int {
        stateQueue.sync {
            let index = nextIndex
            nextIndex += 1
            return index
        }
    }

    private func value<T>(at index: Int, in values: [T]) -> T {
        values[min(index, values.count - 1)]
    }

    private func sleepIgnoringCancellation(milliseconds: Int) async {
        await withCheckedContinuation { continuation in
            DispatchQueue.global().asyncAfter(deadline: .now() + .milliseconds(milliseconds)) {
                continuation.resume()
            }
        }
    }
}

@MainActor
private func waitUntil(
    timeout: TimeInterval = 0.5,
    condition: @escaping @MainActor () -> Bool) async {
    let deadline = Date().addingTimeInterval(timeout)
    while !condition(), Date() < deadline {
        await Task.yield()
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
