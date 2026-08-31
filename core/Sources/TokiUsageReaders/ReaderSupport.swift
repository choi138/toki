import Foundation
import TokiUsageCore

func findFiles(in directory: URL, withExtension ext: String, modifiedAfter: Date? = nil) -> [URL] {
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
    modifiedAfter: Date? = nil) throws -> [URL] {
    try Task.checkCancellation()

    let keys: [URLResourceKey] = modifiedAfter != nil
        ? [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey, .contentModificationDateKey]
        : [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey]
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
        options: [.skipsHiddenFiles],
        errorHandler: { _, _ in
            traversalFailed = true
            return false
        }) else {
        throw UsageFileDiscoveryError.cannotEnumerateRoot
    }

    var files: [URL] = []
    while let url = enumerator.nextObject() as? URL {
        try Task.checkCancellation()
        let values: URLResourceValues
        do {
            values = try url.resourceValues(forKeys: Set(keys))
        } catch {
            throw UsageFileDiscoveryError.cannotReadEntryMetadata
        }
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
    if traversalFailed {
        throw UsageFileDiscoveryError.cannotEnumerateRoot
    }
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

func checkedTokenTotal(_ values: Int...) -> Int? {
    var total = 0
    for value in values {
        guard value >= 0 else { return nil }
        let addition = total.addingReportingOverflow(value)
        guard !addition.overflow else { return nil }
        total = addition.partialValue
    }
    return total
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
