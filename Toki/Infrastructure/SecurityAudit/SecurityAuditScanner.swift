import Foundation

final class SecurityAuditScanner: SecurityAuditScanning {
    private let fileDiscovery: SecurityAuditFileDiscovery
    private let fileScanner: SecurityAuditFileScanner
    private let maxConcurrentFileScans: Int

    init(
        sources: [SecurityAuditFileSource] = SecurityAuditScanner.defaultSources(),
        rules: [SecurityAuditRule] = SecurityAuditRules.defaults,
        fileManager: FileManager = .default,
        maxConcurrentFileScans: Int = min(max(ProcessInfo.processInfo.activeProcessorCount, 1), 8),
        cacheStore: (any SecurityAuditCacheStoring)? = SecurityAuditCacheStore()) {
        fileDiscovery = SecurityAuditFileDiscovery(sources: sources, fileManager: fileManager)
        fileScanner = SecurityAuditFileScanner(
            rules: rules,
            fileManager: fileManager,
            cacheStore: cacheStore)
        self.maxConcurrentFileScans = max(maxConcurrentFileScans, 1)
    }

    func scan(
        request: SecurityAuditRequest = SecurityAuditRequest(),
        progress: SecurityAuditProgressHandler? = nil) async -> SecurityAuditResult {
        let scannedAt = Date()
        let planSummary = fileDiscovery.makeScanPlanSummary(request: request, progress: progress)
        let progressReporter = SecurityAuditProgressReporter(
            totalFileCount: planSummary.totalFileCount,
            progress: progress)
        var accumulator = SecurityAuditScanAccumulator()
        var cache = fileScanner.loadCache()

        progressReporter.report(phase: .scanning, accumulator: accumulator)

        for plan in planSummary.scanPlans {
            guard !Task.isCancelled else { break }

            for batchStart in stride(from: 0, to: plan.fileURLs.count, by: maxConcurrentFileScans) {
                guard !Task.isCancelled else { break }

                let batchEnd = min(batchStart + maxConcurrentFileScans, plan.fileURLs.count)
                let batch = Array(plan.fileURLs[batchStart..<batchEnd])
                _ = await fileScanner.scanFilesUsingCache(
                    batch,
                    source: plan.source,
                    scannedAt: scannedAt,
                    cache: &cache,
                    onFileStarted: { sourceName, fileURL in
                        progressReporter.report(
                            phase: .scanning,
                            sourceName: sourceName,
                            fileURL: fileURL,
                            accumulator: accumulator)
                    },
                    onFileCompleted: { sourceName, fileURL, fileResult in
                        accumulator.record(fileResult)
                        progressReporter.report(
                            phase: .scanning,
                            sourceName: sourceName,
                            fileURL: fileURL,
                            accumulator: accumulator)
                    })
            }
        }

        if request.modifiedAfter == nil {
            fileScanner.reconcileDeletedFiles(
                cache: &cache,
                visiblePathsByEnabledSource: planSummary.visiblePathsByEnabledSource)
        }
        fileScanner.saveCache(cache)
        progressReporter.report(phase: .finished, accumulator: accumulator, force: true)

        return SecurityAuditResult(
            scannedAt: scannedAt,
            scannedSourceCount: planSummary.scanPlans.count,
            scannedFileCount: accumulator.scannedFileCount,
            scannedLineCount: accumulator.scannedLineCount,
            skippedSourceNames: planSummary.skippedSourceNames,
            findings: accumulator.findings.sorted(by: fileScanner.sortFindings))
    }

    func scanTextLine(
        _ line: String,
        sourceName: String,
        fileURL: URL,
        lineNumber: Int,
        fallbackDetectedAt: Date?) -> [SecurityFinding] {
        fileScanner.scanTextLine(
            line,
            sourceName: sourceName,
            fileURL: fileURL,
            lineNumber: lineNumber,
            fallbackDetectedAt: fallbackDetectedAt)
    }
}

private struct SecurityAuditScanAccumulator {
    private(set) var scannedFileCount = 0
    private(set) var scannedLineCount = 0
    private(set) var findings: [SecurityFinding] = []
    private var seenFindingIDs = Set<String>()

    mutating func record(_ result: SecurityFileScanResult) {
        scannedFileCount += 1
        scannedLineCount += result.lineCount

        for finding in result.findings where seenFindingIDs.insert(finding.id).inserted {
            findings.append(finding)
        }
    }
}

private final class SecurityAuditProgressReporter {
    private let totalFileCount: Int
    private let progress: SecurityAuditProgressHandler?
    private var lastScanProgressReport = Date.distantPast

    init(totalFileCount: Int, progress: SecurityAuditProgressHandler?) {
        self.totalFileCount = totalFileCount
        self.progress = progress
    }

    func report(
        phase: SecurityAuditProgress.Phase,
        sourceName: String? = nil,
        fileURL: URL? = nil,
        accumulator: SecurityAuditScanAccumulator,
        force: Bool = false) {
        if !force, phase == .scanning, totalFileCount > 50 {
            let now = Date()
            guard now.timeIntervalSince(lastScanProgressReport) >= 0.12 else { return }
            lastScanProgressReport = now
        }

        progress?(SecurityAuditProgress(
            phase: phase,
            currentSourceName: sourceName,
            currentFileName: fileURL?.lastPathComponent,
            completedFileCount: accumulator.scannedFileCount,
            totalFileCount: totalFileCount,
            scannedLineCount: accumulator.scannedLineCount,
            findingCount: accumulator.findings.count))
    }
}
