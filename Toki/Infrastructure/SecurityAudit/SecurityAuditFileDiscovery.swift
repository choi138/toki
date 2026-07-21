import Foundation

struct SecurityAuditSourceScanPlan {
    let source: SecurityAuditFileSource
    let fileURLs: [URL]
}

struct SecurityAuditScanPlanSummary {
    let scanPlans: [SecurityAuditSourceScanPlan]
    let skippedSourceNames: [String]
    let visiblePathsByEnabledSource: [String: Set<String>]
    let totalFileCount: Int
}

final class SecurityAuditFileDiscovery {
    private let sources: [SecurityAuditFileSource]
    private let fileManager: FileManager

    init(sources: [SecurityAuditFileSource], fileManager: FileManager) {
        self.sources = sources
        self.fileManager = fileManager
    }

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

            reportProgress(progress, sourceName: source.name, totalFileCount: totalFileCount)
            let fileURLs = discoverFiles(for: source, modifiedAfter: request.modifiedAfter)
            scanPlans.append(SecurityAuditSourceScanPlan(source: source, fileURLs: fileURLs))
            totalFileCount += fileURLs.count
            visiblePathsByEnabledSource[source.name, default: []].formUnion(
                fileURLs.map(\.standardizedFileURL.path))
            reportProgress(progress, sourceName: source.name, totalFileCount: totalFileCount)
        }

        return SecurityAuditScanPlanSummary(
            scanPlans: scanPlans,
            skippedSourceNames: skippedSourceNames,
            visiblePathsByEnabledSource: visiblePathsByEnabledSource,
            totalFileCount: totalFileCount)
    }
}

private extension SecurityAuditFileDiscovery {
    func reportProgress(
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
                let sqliteWALModifiedDate = SecurityAuditSQLiteFileMetadata.walModificationDate(
                    for: source,
                    fileURL: url,
                    fileManager: fileManager)
                guard modifiedDate.map({ $0 >= modifiedAfter }) == true
                    || sqliteWALModifiedDate.map({ $0 >= modifiedAfter }) == true else {
                    return nil
                }
            }

            return url
        }
        .sorted { $0.path < $1.path }
    }
}
