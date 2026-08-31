import Foundation
import TokiUsageCore

enum LocalUsageReaderDiagnosticError: LocalizedError {
    case decodeFailed(source: String, stage: String)

    var errorDescription: String? {
        switch self {
        case let .decodeFailed(source, stage):
            "\(source) \(stage) decode failed"
        }
    }
}

func findFiles(in directory: URL, withExtension ext: String, modifiedAfter: Date? = nil) -> [URL] {
    (try? findFiles(
        in: directory,
        withExtension: ext,
        modifiedAfter: modifiedAfter,
        cancellationCheck: {})) ?? []
}

func findFiles(
    in directory: URL,
    withExtension ext: String,
    modifiedAfter: Date? = nil,
    cancellationCheck: () throws -> Void) throws -> [URL] {
    try cancellationCheck()
    let keys: [URLResourceKey] = modifiedAfter != nil
        ? [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey, .contentModificationDateKey]
        : [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey]

    guard FileManager.default.fileExists(atPath: directory.path),
          let enumerator = FileManager.default.enumerator(
              at: directory,
              includingPropertiesForKeys: keys,
              options: [.skipsHiddenFiles]) else {
        return []
    }

    var files: [URL] = []
    for case let url as URL in enumerator {
        try cancellationCheck()
        guard let values = try? url.resourceValues(forKeys: Set(keys)) else { continue }
        if values.isSymbolicLink == true {
            if values.isDirectory == true {
                enumerator.skipDescendants()
            }
            continue
        }
        guard values.isRegularFile == true,
              url.pathExtension == ext else { continue }

        if let since = modifiedAfter {
            guard let modifiedDate = values.contentModificationDate,
                  modifiedDate >= since else { continue }
        }

        files.append(url)
    }
    return files
}

enum UsageFileDiscoveryError: Error {
    case cannotReadRoot
    case rootIsNotDirectory
    case cannotEnumerateRoot
    case cannotReadEntryMetadata
}

func findFilesThrowing(
    in directory: URL,
    withExtension ext: String,
    modifiedAfter: Date? = nil,
    maximumFileCount: Int? = nil,
    maximumEntryCount: Int? = nil) throws -> [URL] {
    try Task.checkCancellation()

    let keys: [URLResourceKey] = modifiedAfter != nil
        ? [.isHiddenKey, .isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey, .contentModificationDateKey]
        : [.isHiddenKey, .isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey]
    let rootValues: URLResourceValues
    do {
        rootValues = try directory.resourceValues(forKeys: [.isDirectoryKey])
    } catch {
        let cocoaError = error as NSError
        if cocoaError.domain == NSCocoaErrorDomain,
           cocoaError.code == CocoaError.fileReadNoSuchFile.rawValue
           || cocoaError.code == CocoaError.fileNoSuchFile.rawValue {
            return []
        }
        throw UsageFileDiscoveryError.cannotReadRoot
    }
    guard rootValues.isDirectory == true else {
        throw UsageFileDiscoveryError.rootIsNotDirectory
    }

    var traversalFailed = false
    guard let enumerator = FileManager.default.enumerator(
        at: directory,
        includingPropertiesForKeys: keys,
        options: [],
        errorHandler: { _, _ in
            traversalFailed = true
            return false
        }) else {
        throw UsageFileDiscoveryError.cannotEnumerateRoot
    }

    var files: [URL] = []
    var visitedEntryCount = 0
    while let url = enumerator.nextObject() as? URL {
        try Task.checkCancellation()
        let (nextEntryCount, entryOverflow) = visitedEntryCount.addingReportingOverflow(1)
        guard !entryOverflow,
              maximumEntryCount.map({ nextEntryCount <= $0 }) ?? true else {
            throw PiCompatibleReaderError.tooManyEntries(entryOverflow ? Int.max : nextEntryCount)
        }
        visitedEntryCount = nextEntryCount
        let values: URLResourceValues
        do {
            values = try url.resourceValues(forKeys: Set(keys))
        } catch {
            throw UsageFileDiscoveryError.cannotReadEntryMetadata
        }
        if skipHiddenEntry(url, values: values, enumerator: enumerator) { continue }
        if values.isSymbolicLink == true {
            if values.isDirectory == true {
                enumerator.skipDescendants()
            }
            continue
        }
        guard values.isRegularFile == true,
              url.pathExtension == ext else { continue }

        if let since = modifiedAfter {
            guard let modifiedDate = values.contentModificationDate,
                  modifiedDate >= since else { continue }
        }

        let (nextFileCount, fileOverflow) = files.count.addingReportingOverflow(1)
        guard !fileOverflow,
              maximumFileCount.map({ nextFileCount <= $0 }) ?? true else {
            throw PiCompatibleReaderError.tooManyFiles(fileOverflow ? Int.max : nextFileCount)
        }
        files.append(url)
    }
    if traversalFailed {
        throw UsageFileDiscoveryError.cannotEnumerateRoot
    }
    return files
}

private func skipHiddenEntry(
    _ url: URL,
    values: URLResourceValues,
    enumerator: FileManager.DirectoryEnumerator) -> Bool {
    guard values.isHidden == true || url.lastPathComponent.hasPrefix(".") else { return false }
    if values.isDirectory == true {
        enumerator.skipDescendants()
    }
    return true
}

func boundedUsageFileData(at url: URL, maximumBytes: Int) throws -> Data {
    guard maximumBytes >= 0 else {
        throw PiCompatibleReaderError.fileTooLarge(url)
    }
    let handle: FileHandle
    do {
        handle = try FileHandle(forReadingFrom: url)
    } catch {
        throw PiCompatibleReaderError.unreadableFile(url)
    }
    defer { try? handle.close() }
    do {
        let readLimit = maximumBytes == Int.max ? Int.max : maximumBytes + 1
        let data = try handle.read(upToCount: readLimit) ?? Data()
        guard data.count <= maximumBytes else {
            throw PiCompatibleReaderError.fileTooLarge(url)
        }
        return data
    } catch let error as PiCompatibleReaderError {
        throw error
    } catch {
        throw PiCompatibleReaderError.unreadableFile(url)
    }
}

func recordUsageEvents(_ count: Int, total: inout Int, maximum: Int) throws {
    let (nextCount, overflow) = total.addingReportingOverflow(count)
    guard count >= 0, !overflow, nextCount <= maximum else {
        throw PiCompatibleReaderError.tooManyEvents(overflow ? Int.max : nextCount)
    }
    total = nextCount
}

func findUsageFiles(
    in directory: URL,
    withExtension ext: String,
    maximumFileCount: Int? = nil,
    maximumEntryCount: Int? = nil,
    visitedEntryCount: inout Int) throws -> [URL] {
    try Task.checkCancellation()
    let normalizedDirectory = directory.resolvingSymlinksInPath().standardizedFileURL
    let rootValues: URLResourceValues
    do {
        rootValues = try normalizedDirectory.resourceValues(forKeys: [.isDirectoryKey])
    } catch {
        let nsError = error as NSError
        if nsError.domain == NSCocoaErrorDomain,
           nsError.code == NSFileNoSuchFileError || nsError.code == NSFileReadNoSuchFileError {
            return []
        }
        throw PiCompatibleReaderError.unreadableFile(normalizedDirectory)
    }
    guard rootValues.isDirectory == true else {
        throw PiCompatibleReaderError.unreadableFile(normalizedDirectory)
    }

    let keys: Set<URLResourceKey> = [
        .isHiddenKey,
        .isDirectoryKey,
        .isRegularFileKey,
        .isSymbolicLinkKey,
    ]
    var failedURL: URL?
    guard let enumerator = FileManager.default.enumerator(
        at: normalizedDirectory,
        includingPropertiesForKeys: Array(keys),
        options: [],
        errorHandler: { url, _ in
            failedURL = url
            return false
        }) else {
        throw PiCompatibleReaderError.unreadableFile(normalizedDirectory)
    }

    var files: [URL] = []
    for case let url as URL in enumerator {
        try Task.checkCancellation()
        let (nextEntryCount, entryCountOverflow) = visitedEntryCount.addingReportingOverflow(1)
        guard !entryCountOverflow,
              maximumEntryCount.map({ nextEntryCount <= $0 }) ?? true else {
            throw PiCompatibleReaderError.tooManyEntries(entryCountOverflow ? Int.max : nextEntryCount)
        }
        visitedEntryCount = nextEntryCount
        let values: URLResourceValues
        do {
            values = try url.resourceValues(forKeys: keys)
        } catch {
            throw PiCompatibleReaderError.unreadableFile(url.standardizedFileURL)
        }
        if values.isHidden == true || url.lastPathComponent.hasPrefix(".") {
            if values.isDirectory == true {
                enumerator.skipDescendants()
            }
            continue
        }
        if values.isSymbolicLink == true {
            if values.isDirectory == true {
                enumerator.skipDescendants()
            }
            continue
        }
        guard values.isRegularFile == true,
              url.pathExtension == ext else {
            continue
        }
        files.append(url)
        if let maximumFileCount, files.count >= maximumFileCount {
            return files
        }
    }
    if let failedURL {
        throw PiCompatibleReaderError.unreadableFile(failedURL.standardizedFileURL)
    }
    try Task.checkCancellation()
    return files
}

func readJSONLLines(at url: URL) -> [String] {
    guard let content = try? String(contentsOf: url, encoding: .utf8) else { return [] }
    return content
        .components(separatedBy: .newlines)
        .map { $0.trimmingCharacters(in: .whitespaces) }
        .filter { !$0.isEmpty }
}

enum JSONLLineSource {
    case lines([String])
    case file(URL)

    func consume(_ body: (String) -> Void) throws {
        try Task.checkCancellation()
        switch self {
        case let .lines(lines):
            for line in lines {
                try Task.checkCancellation()
                body(line)
            }
        case let .file(url):
            try forEachJSONLLineThrowing(at: url) { line, _ in body(line) }
        }
    }
}

public func normalizedModelID(_ value: String?) -> String? {
    guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines),
          !trimmed.isEmpty,
          trimmed != "<synthetic>" else {
        return nil
    }
    return trimmed
}

func inferredUsageProvider(from model: String?) -> String? {
    guard let model = normalizedModelID(model)?.lowercased() else { return nil }
    if model.contains("claude") || model.contains("opus") || model.contains("sonnet")
        || model.contains("haiku") {
        return "anthropic"
    }
    if model.contains("gemini") { return "google" }
    if model.contains("kimi") { return "moonshot" }
    if model.contains("qwen") { return "qwen" }
    if model.contains("deepseek") { return "deepseek" }
    if model.contains("mistral") || model.contains("codestral") { return "mistral" }
    if model.contains("grok") { return "xai" }
    if model.contains("glm") { return "zai" }
    if model.hasPrefix("gpt-") || model.hasPrefix("o1") || model.hasPrefix("o3")
        || model.hasPrefix("o4") || model.contains("codex") {
        return "openai"
    }
    return nil
}

public extension RawTokenUsage {
    mutating func mergeActiveEstimate(_ estimate: ActivityTimeEstimate<String>, source: String) {
        activeSeconds += estimate.totalSeconds
        for (modelID, seconds) in estimate.secondsByKey {
            perModel[modelID, default: PerModelUsage()].activeSeconds += seconds
            perModel[modelID, default: PerModelUsage()].sources.insert(source)
        }
        for (modelID, seconds) in estimate.wallClockSecondsByKey {
            perModel[modelID, default: PerModelUsage()].wallClockSeconds += seconds
        }
    }

    mutating func mergeActivityEvents(
        _ events: [ActivityTimeEvent<String>],
        source: String,
        clippingEndDate: Date? = nil) {
        guard !events.isEmpty else { return }
        activityEvents.append(contentsOf: events)
        recomputeMergedActiveEstimate(source: source, clippingEndDate: clippingEndDate)
    }

    mutating func recomputeMergedActiveEstimate(
        source: String? = nil,
        clippingEndDate: Date? = nil) {
        guard !activityEvents.isEmpty else {
            // Readers that report totals without timestamps never reach the estimate
            // below, so carry their duration into the wall-clock field here. Leaving it
            // at zero would export an unmeasured zero for time that was measured.
            for modelID in perModel.keys {
                perModel[modelID]?.wallClockSeconds = fallbackActiveSecondsByModel[modelID, default: 0]
            }
            let fallbackOnlyWorkTime = resolvedFallbackWorkTime
            fallbackWorkTime = fallbackOnlyWorkTime
            workTime = fallbackOnlyWorkTime
            return
        }

        activeSeconds = fallbackActiveSeconds
        for modelID in perModel.keys {
            perModel[modelID]?.activeSeconds = fallbackActiveSecondsByModel[modelID, default: 0]
            perModel[modelID]?.wallClockSeconds = fallbackActiveSecondsByModel[modelID, default: 0]
        }

        let estimate = ActivityTimeEstimator.estimate(
            events: activityEvents,
            clippingEndDate: clippingEndDate)
        activeSeconds += estimate.totalSeconds
        let fallbackWorkTime = resolvedFallbackWorkTime
        let estimatedWorkTime = WorkTimeMetrics(
            agentSeconds: estimate.totalSeconds,
            wallClockSeconds: estimate.wallClockSeconds,
            activeStreamCount: estimate.activeStreamCount,
            maxConcurrentStreams: estimate.maxConcurrentStreams,
            mainAgentSeconds: estimate.mainAgentSeconds,
            subagentSeconds: estimate.subagentSeconds)
        // Fallback rows have no timestamps, so they are added as separate active
        // time while peak concurrency only reflects observed stream overlap.
        workTime = fallbackWorkTime.mergedConservatively(with: estimatedWorkTime)
        for (modelID, seconds) in estimate.secondsByKey {
            perModel[modelID, default: PerModelUsage()].activeSeconds += seconds
            if let source {
                perModel[modelID, default: PerModelUsage()].sources.insert(source)
            }
        }
        for (modelID, seconds) in estimate.wallClockSecondsByKey {
            perModel[modelID, default: PerModelUsage()].wallClockSeconds += seconds
        }
        boundModelSourceWallClockToModelTotals()
    }

    /// `perModelBySource` is summed per origin, so a model observed on several origins
    /// would otherwise report their durations added together. Bound each row by the
    /// model's merged span so no row claims more elapsed time than the model was in use.
    private mutating func boundModelSourceWallClockToModelTotals() {
        for (key, usage) in perModelBySource {
            guard let modelWallClock = perModel[key.modelID]?.wallClockSeconds,
                  modelWallClock > 0,
                  usage.wallClockSeconds > modelWallClock else {
                continue
            }
            perModelBySource[key]?.wallClockSeconds = modelWallClock
        }
    }
}

func jsonLineStringValue(_ line: String, forKey key: String) -> String? {
    let prefix = "\"\(key)\":\""
    guard let start = line.range(of: prefix)?.upperBound,
          let end = line[start...].firstIndex(of: "\"") else {
        return nil
    }
    return String(line[start..<end])
}
