import Foundation

final class SecurityAuditScanner: SecurityAuditScanning {
    private let sources: [SecurityAuditFileSource]
    private let rules: [SecurityAuditRule]
    private let fileManager: FileManager
    private let maxConcurrentFileScans: Int
    private let cacheStore: (any SecurityAuditCacheStoring)?
    private let ruleSetIdentifier: String

    init(
        sources: [SecurityAuditFileSource] = SecurityAuditScanner.defaultSources(),
        rules: [SecurityAuditRule] = SecurityAuditRules.defaults,
        fileManager: FileManager = .default,
        maxConcurrentFileScans: Int = min(max(ProcessInfo.processInfo.activeProcessorCount, 1), 8),
        cacheStore: (any SecurityAuditCacheStoring)? = SecurityAuditCacheStore()) {
        self.sources = sources
        self.rules = rules
        self.fileManager = fileManager
        self.maxConcurrentFileScans = max(maxConcurrentFileScans, 1)
        self.cacheStore = cacheStore
        ruleSetIdentifier = SecurityAuditRules.cacheIdentifier(for: rules)
    }

    func scan(
        request: SecurityAuditRequest = SecurityAuditRequest(),
        progress: SecurityAuditProgressHandler? = nil) async -> SecurityAuditResult {
        let scannedAt = Date()
        var scannedFileCount = 0
        var scannedLineCount = 0
        var findings: [SecurityFinding] = []
        var seenFindingIDs = Set<String>()
        var completedFileCount = 0
        var cache = cacheStore?.load() ?? SecurityAuditCache(ruleSetIdentifier: ruleSetIdentifier)
        if cache.ruleSetIdentifier != ruleSetIdentifier {
            cache = SecurityAuditCache(ruleSetIdentifier: ruleSetIdentifier)
        } else {
            cache.ruleSetIdentifier = ruleSetIdentifier
        }
        let planSummary = makeScanPlanSummary(request: request, progress: progress)
        let totalFileCount = planSummary.totalFileCount

        func report(
            phase: SecurityAuditProgress.Phase,
            sourceName: String? = nil,
            fileURL: URL? = nil) {
            progress?(SecurityAuditProgress(
                phase: phase,
                currentSourceName: sourceName,
                currentFileName: fileURL?.lastPathComponent,
                completedFileCount: completedFileCount,
                totalFileCount: totalFileCount,
                scannedLineCount: scannedLineCount,
                findingCount: findings.count))
        }

        report(phase: .scanning)

        for plan in planSummary.scanPlans {
            guard !Task.isCancelled else { break }

            let source = plan.source
            let fileURLs = plan.fileURLs
            for batchStart in stride(from: 0, to: fileURLs.count, by: maxConcurrentFileScans) {
                guard !Task.isCancelled else { break }

                let batchEnd = min(batchStart + maxConcurrentFileScans, fileURLs.count)
                let batch = Array(fileURLs[batchStart..<batchEnd])

                _ = await scanFilesUsingCache(
                    batch,
                    sourceName: source.name,
                    scannedAt: scannedAt,
                    cache: &cache,
                    onFileStarted: { sourceName, fileURL in
                        report(phase: .scanning, sourceName: sourceName, fileURL: fileURL)
                    },
                    onFileCompleted: { sourceName, fileURL, fileResult in
                        completedFileCount += 1
                        scannedFileCount += 1
                        scannedLineCount += fileResult.lineCount

                        for finding in fileResult.findings where !seenFindingIDs.contains(finding.id) {
                            seenFindingIDs.insert(finding.id)
                            findings.append(finding)
                        }

                        report(phase: .scanning, sourceName: sourceName, fileURL: fileURL)
                    })
            }
        }

        if request.modifiedAfter == nil {
            reconcileDeletedFiles(
                cache: &cache,
                visiblePathsByEnabledSource: planSummary.visiblePathsByEnabledSource)
        }
        cacheStore?.save(cache)
        report(phase: .finished)

        return SecurityAuditResult(
            scannedAt: scannedAt,
            scannedSourceCount: planSummary.scanPlans.count,
            scannedFileCount: scannedFileCount,
            scannedLineCount: scannedLineCount,
            skippedSourceNames: planSummary.skippedSourceNames,
            findings: findings.sorted(by: sortFindings))
    }

    static func defaultSources(homeDirectory: URL = homeDir()) -> [SecurityAuditFileSource] {
        [
            SecurityAuditFileSource(
                name: "Claude Code",
                rootURL: homeDirectory.appendingPathComponent(".claude/projects"),
                allowedExtensions: ["jsonl"]),
            SecurityAuditFileSource(
                name: "Codex",
                rootURL: homeDirectory.appendingPathComponent(".codex/sessions"),
                allowedExtensions: ["jsonl"]),
            SecurityAuditFileSource(
                name: "Gemini CLI",
                rootURL: homeDirectory.appendingPathComponent(".gemini/tmp"),
                allowedExtensions: ["json"]),
            SecurityAuditFileSource(
                name: "OpenClaw",
                rootURL: homeDirectory.appendingPathComponent(".openclaw/agents"),
                allowedExtensions: ["jsonl"]),
        ]
    }
}

private struct SecurityFileScanResult {
    let findings: [SecurityFinding]
    let lineCount: Int
}

private struct SecurityAuditSourceScanPlan {
    let source: SecurityAuditFileSource
    let fileURLs: [URL]
}

private struct SecurityAuditScanPlanSummary {
    let scanPlans: [SecurityAuditSourceScanPlan]
    let skippedSourceNames: [String]
    let visiblePathsByEnabledSource: [String: Set<String>]
    let totalFileCount: Int
}

private struct SecurityIndexedFileScanResult {
    let index: Int
    let fileURL: URL
    let result: SecurityFileScanResult
}

private extension SecurityAuditScanner {
    func makeScanPlanSummary(
        request: SecurityAuditRequest,
        progress: SecurityAuditProgressHandler?) -> SecurityAuditScanPlanSummary {
        progress?(SecurityAuditProgress.idle)

        var skippedSourceNames: [String] = []
        var visiblePathsByEnabledSource: [String: Set<String>] = [:]
        var scanPlans: [SecurityAuditSourceScanPlan] = []
        var totalFileCount = 0

        for source in sources {
            guard !Task.isCancelled else { break }

            guard request.isSourceEnabled(source.name) else {
                skippedSourceNames.append(source.name)
                continue
            }

            reportDiscoveryProgress(progress, sourceName: source.name, totalFileCount: totalFileCount)
            let fileURLs = discoverFiles(for: source, modifiedAfter: request.modifiedAfter)
            scanPlans.append(SecurityAuditSourceScanPlan(source: source, fileURLs: fileURLs))
            totalFileCount += fileURLs.count
            visiblePathsByEnabledSource[source.name, default: []].formUnion(
                fileURLs.map(\.standardizedFileURL.path))
            reportDiscoveryProgress(progress, sourceName: source.name, totalFileCount: totalFileCount)
        }

        return SecurityAuditScanPlanSummary(
            scanPlans: scanPlans,
            skippedSourceNames: skippedSourceNames,
            visiblePathsByEnabledSource: visiblePathsByEnabledSource,
            totalFileCount: totalFileCount)
    }

    func reportDiscoveryProgress(
        _ progress: SecurityAuditProgressHandler?,
        sourceName: String,
        totalFileCount: Int) {
        progress?(SecurityAuditProgress(
            phase: .discovering,
            currentSourceName: sourceName,
            currentFileName: nil,
            completedFileCount: 0,
            totalFileCount: totalFileCount,
            scannedLineCount: 0,
            findingCount: 0))
    }

    func discoverFiles(for source: SecurityAuditFileSource, modifiedAfter: Date?) -> [URL] {
        let keys: [URLResourceKey] = [.isRegularFileKey, .contentModificationDateKey]
        guard fileManager.fileExists(atPath: source.rootURL.path),
              let enumerator = fileManager.enumerator(
                  at: source.rootURL,
                  includingPropertiesForKeys: keys,
                  options: [.skipsPackageDescendants]) else {
            return []
        }

        return enumerator.compactMap { item -> URL? in
            guard let url = item as? URL,
                  source.allowedExtensions.contains(url.pathExtension.lowercased()),
                  (try? url.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true else {
                return nil
            }

            if let modifiedAfter {
                let modifiedDate = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?
                    .contentModificationDate
                guard let modifiedDate, modifiedDate >= modifiedAfter else { return nil }
            }

            return url
        }
        .sorted { $0.path < $1.path }
    }

    func modificationDate(for fileURL: URL) -> Date? {
        (try? fileURL.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
    }

    func scanFiles(
        _ fileURLs: [URL],
        sourceName: String,
        onFileStarted: ((String, URL) -> Void)? = nil,
        onFileCompleted: ((String, URL, SecurityFileScanResult) -> Void)? = nil)
        async -> [(URL, SecurityFileScanResult)] {
        await withTaskGroup(of: SecurityIndexedFileScanResult.self) { group in
            for (index, fileURL) in fileURLs.enumerated() {
                onFileStarted?(sourceName, fileURL)
                group.addTask {
                    let fileModificationDate = self.modificationDate(for: fileURL)
                    let result = await self.scanFile(
                        fileURL,
                        sourceName: sourceName,
                        fallbackDetectedAt: fileModificationDate)
                    return SecurityIndexedFileScanResult(index: index, fileURL: fileURL, result: result)
                }
            }

            var results: [SecurityIndexedFileScanResult] = []
            for await fileResult in group {
                results.append(fileResult)
                onFileCompleted?(sourceName, fileResult.fileURL, fileResult.result)
            }
            return results
                .sorted { $0.index < $1.index }
                .map { ($0.fileURL, $0.result) }
        }
    }

    func scanFilesUsingCache(
        _ fileURLs: [URL],
        sourceName: String,
        scannedAt: Date,
        cache: inout SecurityAuditCache,
        onFileStarted: ((String, URL) -> Void)? = nil,
        onFileCompleted: ((String, URL, SecurityFileScanResult) -> Void)? = nil) async -> [SecurityFileScanResult] {
        var resultsByPath: [String: SecurityFileScanResult] = [:]
        var filesToScanFully: [URL] = []

        for fileURL in fileURLs {
            onFileStarted?(sourceName, fileURL)
            let path = fileURL.standardizedFileURL.path
            guard let attributes = try? fileManager.attributesOfItem(atPath: path) else {
                let result = SecurityFileScanResult(findings: [], lineCount: 0)
                cache.entriesByPath.removeValue(forKey: path)
                resultsByPath[path] = result
                onFileCompleted?(sourceName, fileURL, result)
                continue
            }

            let fileSize = (attributes[.size] as? NSNumber)?.int64Value ?? 0
            let modificationDate = attributes[.modificationDate] as? Date ?? modificationDate(for: fileURL)

            if let cached = cache.entriesByPath[path],
               cached.ruleSetIdentifier == ruleSetIdentifier,
               cached.sourceName == sourceName,
               cached.path == path,
               cached.fileSize == fileSize,
               cached.modificationDate == modificationDate,
               cached.byteOffset == fileSize,
               SecurityAuditCacheSignature.matches(
                   cached.signature,
                   fileURL: fileURL,
                   byteOffset: fileSize) {
                let result = SecurityFileScanResult(
                    findings: cached.findings.map(\.finding),
                    lineCount: cached.lineCount)
                resultsByPath[path] = result
                onFileCompleted?(sourceName, fileURL, result)
                continue
            }

            if let cached = cache.entriesByPath[path],
               cached.ruleSetIdentifier == ruleSetIdentifier,
               cached.sourceName == sourceName,
               shouldScanAppend(fileURL: fileURL, cached: cached, fileSize: fileSize) {
                let appendedResult = scanAppendedBytes(
                    fileURL,
                    sourceName: sourceName,
                    startOffset: cached.byteOffset,
                    startingLineNumber: cached.lineCount,
                    fallbackDetectedAt: modificationDate)
                let mergedFindings = cached.findings.map(\.finding) + appendedResult.findings
                let lineCount = cached.lineCount + appendedResult.lineCount
                updateCache(
                    &cache,
                    sourceName: sourceName,
                    path: path,
                    fileURL: fileURL,
                    fileSize: fileSize,
                    modificationDate: modificationDate,
                    lineCount: lineCount,
                    findings: mergedFindings,
                    scannedAt: scannedAt)
                let result = SecurityFileScanResult(findings: mergedFindings, lineCount: lineCount)
                resultsByPath[path] = result
                onFileCompleted?(sourceName, fileURL, result)
                continue
            }

            filesToScanFully.append(fileURL)
        }

        await scanAndCacheFullFiles(
            filesToScanFully,
            sourceName: sourceName,
            scannedAt: scannedAt,
            cache: &cache,
            resultsByPath: &resultsByPath,
            onFileCompleted: onFileCompleted)

        return fileURLs.map {
            resultsByPath[$0.standardizedFileURL.path] ?? SecurityFileScanResult(findings: [], lineCount: 0)
        }
    }

    func scanAndCacheFullFiles(
        _ fileURLs: [URL],
        sourceName: String,
        scannedAt: Date,
        cache: inout SecurityAuditCache,
        resultsByPath: inout [String: SecurityFileScanResult],
        onFileCompleted: ((String, URL, SecurityFileScanResult) -> Void)?) async {
        let fullScanResults = await scanFiles(
            fileURLs,
            sourceName: sourceName,
            onFileStarted: nil,
            onFileCompleted: onFileCompleted)
        for (fileURL, fileResult) in fullScanResults {
            let path = fileURL.standardizedFileURL.path
            let attributes = try? fileManager.attributesOfItem(atPath: path)
            let fileSize = (attributes?[.size] as? NSNumber)?.int64Value ?? 0
            let modificationDate = attributes?[.modificationDate] as? Date ?? modificationDate(for: fileURL)
            updateCache(
                &cache,
                sourceName: sourceName,
                path: path,
                fileURL: fileURL,
                fileSize: fileSize,
                modificationDate: modificationDate,
                lineCount: fileResult.lineCount,
                findings: fileResult.findings,
                scannedAt: scannedAt)
            resultsByPath[path] = fileResult
        }
    }

    func shouldScanAppend(fileURL: URL, cached: SecurityAuditCachedFile, fileSize: Int64) -> Bool {
        fileURL.pathExtension.lowercased() == "jsonl"
            && fileSize > cached.byteOffset
            && cached.byteOffset >= 0
            && cached.byteOffset <= fileSize
            && cached.signature.endedWithNewline
            && SecurityAuditCacheSignature.matches(
                cached.signature,
                fileURL: fileURL,
                byteOffset: cached.byteOffset)
    }

    func scanAppendedBytes(
        _ fileURL: URL,
        sourceName: String,
        startOffset: Int64,
        startingLineNumber: Int,
        fallbackDetectedAt: Date?) -> SecurityFileScanResult {
        guard let handle = try? FileHandle(forReadingFrom: fileURL) else {
            return SecurityFileScanResult(findings: [], lineCount: 0)
        }
        defer { try? handle.close() }

        do {
            try handle.seek(toOffset: UInt64(startOffset))
            let data = try handle.readToEnd() ?? Data()
            guard let text = String(data: data, encoding: .utf8) else {
                return SecurityFileScanResult(findings: [], lineCount: 0)
            }

            let lines = appendedLines(from: text)
            var findings: [SecurityFinding] = []
            for (index, line) in lines.enumerated() {
                findings.append(contentsOf: scanLine(
                    line,
                    sourceName: sourceName,
                    fileURL: fileURL,
                    lineNumber: startingLineNumber + index + 1,
                    fallbackDetectedAt: fallbackDetectedAt))
            }
            return SecurityFileScanResult(findings: findings, lineCount: lines.count)
        } catch {
            return SecurityFileScanResult(findings: [], lineCount: 0)
        }
    }

    func appendedLines(from text: String) -> [String] {
        var lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        if text.hasSuffix("\n") {
            lines.removeLast()
        }
        return lines
    }

    func updateCache(
        _ cache: inout SecurityAuditCache,
        sourceName: String,
        path: String,
        fileURL: URL,
        fileSize: Int64,
        modificationDate: Date?,
        lineCount: Int,
        findings: [SecurityFinding],
        scannedAt: Date) {
        guard let signature = SecurityAuditCacheSignature.signature(for: fileURL, byteOffset: fileSize) else {
            cache.entriesByPath.removeValue(forKey: path)
            return
        }

        cache.entriesByPath[path] = SecurityAuditCachedFile(
            ruleSetIdentifier: ruleSetIdentifier,
            sourceName: sourceName,
            path: path,
            fileSize: fileSize,
            modificationDate: modificationDate,
            lineCount: lineCount,
            findings: findings.map(SecurityAuditCachedFinding.init),
            lastScannedAt: scannedAt,
            byteOffset: fileSize,
            signature: signature)
    }

    func reconcileDeletedFiles(
        cache: inout SecurityAuditCache,
        visiblePathsByEnabledSource: [String: Set<String>]) {
        cache.entriesByPath = cache.entriesByPath.filter { _, entry in
            guard let visiblePaths = visiblePathsByEnabledSource[entry.sourceName] else { return true }
            return visiblePaths.contains(entry.path)
        }
    }

    func scanFile(
        _ fileURL: URL,
        sourceName: String,
        fallbackDetectedAt: Date?) async -> SecurityFileScanResult {
        var findings: [SecurityFinding] = []
        var lineNumber = 0

        do {
            for try await line in fileURL.lines {
                guard !Task.isCancelled else { break }
                lineNumber += 1
                findings.append(
                    contentsOf: scanLine(
                        line,
                        sourceName: sourceName,
                        fileURL: fileURL,
                        lineNumber: lineNumber,
                        fallbackDetectedAt: fallbackDetectedAt))
            }
        } catch {
            return SecurityFileScanResult(findings: findings, lineCount: lineNumber)
        }

        return SecurityFileScanResult(findings: findings, lineCount: lineNumber)
    }

    func scanLine(
        _ line: String,
        sourceName: String,
        fileURL: URL,
        lineNumber: Int,
        fallbackDetectedAt: Date?)
        -> [SecurityFinding] {
        let range = NSRange(line.startIndex..<line.endIndex, in: line)
        guard range.length > 0 else { return [] }

        var hasResolvedDetectedAt = false
        var resolvedDetectedAt: Date?
        func detectedAt() -> Date? {
            if !hasResolvedDetectedAt {
                resolvedDetectedAt = SecurityAuditTimestampExtractor.date(from: line) ?? fallbackDetectedAt
                hasResolvedDetectedAt = true
            }
            return resolvedDetectedAt
        }

        return rules.flatMap { rule -> [SecurityFinding] in
            guard rule.prefilter(line) else { return [] }

            return rule.pattern.matches(in: line, range: range).compactMap { match -> SecurityFinding? in
                guard let evidence = evidenceText(from: match, in: line, captureGroup: rule.captureGroup),
                      !evidence.isEmpty,
                      rule.validator(evidence) else {
                    return nil
                }

                return SecurityFinding(
                    sourceName: sourceName,
                    severity: rule.severity,
                    category: rule.category,
                    ruleName: rule.name,
                    maskedEvidence: SecurityEvidenceMasker.mask(evidence),
                    location: SecurityFindingLocation(
                        filePath: fileURL.standardizedFileURL.path,
                        lineNumber: lineNumber),
                    detectedAt: detectedAt())
            }
        }
    }

    func evidenceText(from match: NSTextCheckingResult, in line: String, captureGroup: Int?) -> String? {
        if let captureGroup {
            return text(in: match.range(at: captureGroup), line: line)
        }

        return text(in: match.range, line: line)
    }

    func text(in range: NSRange, line: String) -> String? {
        guard range.location != NSNotFound,
              let swiftRange = Range(range, in: line) else {
            return nil
        }
        return String(line[swiftRange])
    }

    func sortFindings(_ lhs: SecurityFinding, _ rhs: SecurityFinding) -> Bool {
        if lhs.severity != rhs.severity {
            return lhs.severity < rhs.severity
        }
        if lhs.sourceName != rhs.sourceName {
            return lhs.sourceName < rhs.sourceName
        }
        if lhs.location.filePath != rhs.location.filePath {
            return lhs.location.filePath < rhs.location.filePath
        }
        return lhs.location.lineNumber < rhs.location.lineNumber
    }
}
