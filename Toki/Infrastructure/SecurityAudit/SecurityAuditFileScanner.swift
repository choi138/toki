import Foundation

final class SecurityAuditFileScanner {
    private let rules: [SecurityAuditRule]
    private let fileManager: FileManager
    private let cacheStore: (any SecurityAuditCacheStoring)?
    private let ruleSetIdentifier: String

    init(
        rules: [SecurityAuditRule],
        fileManager: FileManager,
        cacheStore: (any SecurityAuditCacheStoring)?) {
        self.rules = rules
        self.fileManager = fileManager
        self.cacheStore = cacheStore
        ruleSetIdentifier = SecurityAuditRules.cacheIdentifier(for: rules)
    }

    func loadCache() -> SecurityAuditCache {
        let loadedCache = cacheStore?.load() ?? SecurityAuditCache(ruleSetIdentifier: ruleSetIdentifier)
        guard loadedCache.ruleSetIdentifier == ruleSetIdentifier else {
            return SecurityAuditCache(ruleSetIdentifier: ruleSetIdentifier)
        }

        var cache = loadedCache
        cache.ruleSetIdentifier = ruleSetIdentifier
        return cache
    }

    func saveCache(_ cache: SecurityAuditCache) {
        cacheStore?.save(cache)
    }

    func scanFilesUsingCache(
        _ fileURLs: [URL],
        source: SecurityAuditFileSource,
        scannedAt: Date,
        cache: inout SecurityAuditCache,
        onFileStarted: ((String, URL) -> Void)? = nil,
        onFileCompleted: ((String, URL, SecurityFileScanResult) -> Void)? = nil) async -> [SecurityFileScanResult] {
        let sourceName = source.name
        var resultsByPath: [String: SecurityFileScanResult] = [:]
        var filesToScanFully: [URL] = []

        for fileURL in fileURLs {
            guard !Task.isCancelled else { break }

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
            let sqliteWALSignature = SecurityAuditSQLiteFileMetadata.walSignature(
                for: source,
                fileURL: fileURL,
                fileManager: fileManager)

            if let result = cachedResultIfAvailable(
                cache: cache,
                sourceName: sourceName,
                path: path,
                fileURL: fileURL,
                fileSize: fileSize,
                modificationDate: modificationDate,
                sqliteWALSignature: sqliteWALSignature) {
                resultsByPath[path] = result
                onFileCompleted?(sourceName, fileURL, result)
                continue
            }

            if let result = appendedResultIfAvailable(
                cache: &cache,
                sourceName: sourceName,
                path: path,
                fileURL: fileURL,
                fileSize: fileSize,
                modificationDate: modificationDate,
                sqliteWALSignature: sqliteWALSignature,
                scannedAt: scannedAt) {
                resultsByPath[path] = result
                onFileCompleted?(sourceName, fileURL, result)
                continue
            }

            filesToScanFully.append(fileURL)
        }

        await scanAndCacheFullFiles(
            filesToScanFully,
            source: source,
            scannedAt: scannedAt,
            cache: &cache,
            resultsByPath: &resultsByPath,
            onFileCompleted: onFileCompleted)

        return fileURLs.map {
            resultsByPath[$0.standardizedFileURL.path] ?? SecurityFileScanResult(findings: [], lineCount: 0)
        }
    }

    func reconcileDeletedFiles(
        cache: inout SecurityAuditCache,
        visiblePathsByEnabledSource: [String: Set<String>]) {
        cache.entriesByPath = cache.entriesByPath.filter { _, entry in
            guard let visiblePaths = visiblePathsByEnabledSource[entry.sourceName] else { return true }
            return visiblePaths.contains(entry.path)
        }
    }
}

private struct SecurityIndexedFileScanResult {
    let index: Int
    let fileURL: URL
    let result: SecurityFileScanResult
}

private extension SecurityAuditFileScanner {
    func modificationDate(for fileURL: URL) -> Date? {
        (try? fileURL.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
    }

    func scanFiles(
        _ fileURLs: [URL],
        source: SecurityAuditFileSource,
        onFileCompleted: ((String, URL, SecurityFileScanResult) -> Void)?)
        async -> [(URL, SecurityFileScanResult)] {
        await withTaskGroup(of: SecurityIndexedFileScanResult.self) { group in
            for (index, fileURL) in fileURLs.enumerated() {
                guard !Task.isCancelled else { break }

                group.addTask {
                    guard !Task.isCancelled else {
                        let result = SecurityFileScanResult(
                            findings: [],
                            lineCount: 0,
                            isCacheable: false)
                        return SecurityIndexedFileScanResult(index: index, fileURL: fileURL, result: result)
                    }

                    let result = await self.scanFile(
                        fileURL,
                        source: source,
                        fallbackDetectedAt: self.modificationDate(for: fileURL))
                    return SecurityIndexedFileScanResult(index: index, fileURL: fileURL, result: result)
                }
            }

            var results: [SecurityIndexedFileScanResult] = []
            for await fileResult in group {
                results.append(fileResult)
                onFileCompleted?(source.name, fileResult.fileURL, fileResult.result)
            }
            return results
                .sorted { $0.index < $1.index }
                .map { ($0.fileURL, $0.result) }
        }
    }

    func cachedResultIfAvailable(
        cache: SecurityAuditCache,
        sourceName: String,
        path: String,
        fileURL: URL,
        fileSize: Int64,
        modificationDate: Date?,
        sqliteWALSignature: SecurityAuditSQLiteWALSignature?) -> SecurityFileScanResult? {
        guard let cached = cache.entriesByPath[path],
              cached.ruleSetIdentifier == ruleSetIdentifier,
              cached.sourceName == sourceName,
              cached.path == path,
              cached.fileSize == fileSize,
              cached.modificationDate == modificationDate,
              cached.sqliteWALSignature == sqliteWALSignature,
              cached.byteOffset == fileSize,
              SecurityAuditCacheSignature.matches(
                  cached.signature,
                  fileURL: fileURL,
                  byteOffset: fileSize) else {
            return nil
        }

        return SecurityFileScanResult(
            findings: cached.findings.map(\.finding),
            lineCount: cached.lineCount)
    }

    func appendedResultIfAvailable(
        cache: inout SecurityAuditCache,
        sourceName: String,
        path: String,
        fileURL: URL,
        fileSize: Int64,
        modificationDate: Date?,
        sqliteWALSignature: SecurityAuditSQLiteWALSignature?,
        scannedAt: Date) -> SecurityFileScanResult? {
        guard let cached = cache.entriesByPath[path],
              cached.ruleSetIdentifier == ruleSetIdentifier,
              cached.sourceName == sourceName,
              shouldScanAppend(fileURL: fileURL, cached: cached, fileSize: fileSize) else {
            return nil
        }

        let appendedResult = scanAppendedBytes(
            fileURL,
            sourceName: sourceName,
            startOffset: cached.byteOffset,
            startingLineNumber: cached.lineCount,
            fallbackDetectedAt: modificationDate)
        let mergedFindings = cached.findings.map(\.finding) + appendedResult.findings
        let lineCount = cached.lineCount + appendedResult.lineCount
        guard appendedResult.isCacheable else {
            return SecurityFileScanResult(
                findings: mergedFindings,
                lineCount: lineCount,
                isCacheable: false)
        }

        updateCache(
            &cache,
            sourceName: sourceName,
            path: path,
            fileURL: fileURL,
            fileSize: fileSize,
            modificationDate: modificationDate,
            sqliteWALSignature: sqliteWALSignature,
            lineCount: lineCount,
            findings: mergedFindings,
            scannedAt: scannedAt)
        return SecurityFileScanResult(findings: mergedFindings, lineCount: lineCount)
    }
}

private extension SecurityAuditFileScanner {
    func scanAndCacheFullFiles(
        _ fileURLs: [URL],
        source: SecurityAuditFileSource,
        scannedAt: Date,
        cache: inout SecurityAuditCache,
        resultsByPath: inout [String: SecurityFileScanResult],
        onFileCompleted: ((String, URL, SecurityFileScanResult) -> Void)?) async {
        let fullScanResults = await scanFiles(
            fileURLs,
            source: source,
            onFileCompleted: onFileCompleted)
        for (fileURL, fileResult) in fullScanResults {
            let path = fileURL.standardizedFileURL.path
            let attributes = try? fileManager.attributesOfItem(atPath: path)
            let fileSize = (attributes?[.size] as? NSNumber)?.int64Value ?? 0
            let modificationDate = attributes?[.modificationDate] as? Date ?? modificationDate(for: fileURL)
            if fileResult.isCacheable {
                updateCache(
                    &cache,
                    sourceName: source.name,
                    path: path,
                    fileURL: fileURL,
                    fileSize: fileSize,
                    modificationDate: modificationDate,
                    sqliteWALSignature: SecurityAuditSQLiteFileMetadata.walSignature(
                        for: source,
                        fileURL: fileURL,
                        fileManager: fileManager),
                    lineCount: fileResult.lineCount,
                    findings: fileResult.findings,
                    scannedAt: scannedAt)
            } else {
                cache.entriesByPath.removeValue(forKey: path)
            }
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
            guard !Task.isCancelled else {
                return SecurityFileScanResult(findings: [], lineCount: 0, isCacheable: false)
            }
            guard let text = String(data: data, encoding: .utf8) else {
                return SecurityFileScanResult(findings: [], lineCount: 0)
            }

            let lines = appendedLines(from: text)
            var findings: [SecurityFinding] = []
            for (index, line) in lines.enumerated() {
                guard !Task.isCancelled else {
                    return SecurityFileScanResult(
                        findings: findings,
                        lineCount: index,
                        isCacheable: false)
                }

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
        sqliteWALSignature: SecurityAuditSQLiteWALSignature?,
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
            sqliteWALSignature: sqliteWALSignature,
            lineCount: lineCount,
            findings: findings.map(SecurityAuditCachedFinding.init),
            lastScannedAt: scannedAt,
            byteOffset: fileSize,
            signature: signature)
    }
}

private extension SecurityAuditFileScanner {
    func scanFile(
        _ fileURL: URL,
        source: SecurityAuditFileSource,
        fallbackDetectedAt: Date?) async -> SecurityFileScanResult {
        if !source.sqliteTextQueries.isEmpty {
            return scanSQLiteFile(
                fileURL,
                sourceName: source.name,
                queries: source.sqliteTextQueries,
                fallbackDetectedAt: fallbackDetectedAt)
        }

        var findings: [SecurityFinding] = []
        var lineNumber = 0

        do {
            for try await line in fileURL.lines {
                guard !Task.isCancelled else {
                    return SecurityFileScanResult(
                        findings: findings,
                        lineCount: lineNumber,
                        isCacheable: false)
                }
                lineNumber += 1
                findings.append(
                    contentsOf: scanLine(
                        line,
                        sourceName: source.name,
                        fileURL: fileURL,
                        lineNumber: lineNumber,
                        fallbackDetectedAt: fallbackDetectedAt))
            }
        } catch {
            if Task.isCancelled {
                return SecurityFileScanResult(
                    findings: findings,
                    lineCount: lineNumber,
                    isCacheable: false)
            }
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
}

extension SecurityAuditFileScanner {
    func scanTextLine(
        _ line: String,
        sourceName: String,
        fileURL: URL,
        lineNumber: Int,
        fallbackDetectedAt: Date?) -> [SecurityFinding] {
        scanLine(
            line,
            sourceName: sourceName,
            fileURL: fileURL,
            lineNumber: lineNumber,
            fallbackDetectedAt: fallbackDetectedAt)
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
