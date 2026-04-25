import Foundation

func homeDir() -> URL {
    FileManager.default.homeDirectoryForCurrentUser
}

func findFiles(in directory: URL, withExtension ext: String, modifiedAfter: Date? = nil) -> [URL] {
    let keys: [URLResourceKey] = modifiedAfter != nil
        ? [.isRegularFileKey, .contentModificationDateKey]
        : [.isRegularFileKey]

    guard FileManager.default.fileExists(atPath: directory.path),
          let enumerator = FileManager.default.enumerator(
              at: directory,
              includingPropertiesForKeys: keys,
              options: [.skipsHiddenFiles]) else {
        return []
    }

    return enumerator.compactMap { item -> URL? in
        guard let url = item as? URL, url.pathExtension == ext else { return nil }

        if let since = modifiedAfter {
            let modifiedDate = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate
            guard let modifiedDate, modifiedDate >= since else { return nil }
        }

        return url
    }
}

func readJSONLLines(at url: URL) -> [String] {
    guard let content = try? String(contentsOf: url, encoding: .utf8) else { return [] }
    return content
        .components(separatedBy: .newlines)
        .map { $0.trimmingCharacters(in: .whitespaces) }
        .filter { !$0.isEmpty }
}

func normalizedModelID(_ value: String?) -> String? {
    guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines),
          !trimmed.isEmpty,
          trimmed != "<synthetic>" else {
        return nil
    }
    return trimmed
}

extension RawTokenUsage {
    mutating func mergeActiveEstimate(_ estimate: ActivityTimeEstimate<String>, source: String) {
        activeSeconds += estimate.totalSeconds
        for (modelID, seconds) in estimate.secondsByKey {
            perModel[modelID, default: PerModelUsage()].activeSeconds += seconds
            perModel[modelID, default: PerModelUsage()].sources.insert(source)
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
            let fallbackOnlyWorkTime = resolvedFallbackWorkTime
            fallbackWorkTime = fallbackOnlyWorkTime
            workTime = fallbackOnlyWorkTime
            return
        }

        activeSeconds = fallbackActiveSeconds
        for modelID in perModel.keys {
            perModel[modelID]?.activeSeconds = fallbackActiveSecondsByModel[modelID, default: 0]
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
            maxConcurrentStreams: estimate.maxConcurrentStreams)
        // Fallback rows have no timestamps, so they are added as separate active
        // time while peak concurrency only reflects observed stream overlap.
        workTime = fallbackWorkTime.mergedConservatively(with: estimatedWorkTime)
        for (modelID, seconds) in estimate.secondsByKey {
            perModel[modelID, default: PerModelUsage()].activeSeconds += seconds
            if let source {
                perModel[modelID, default: PerModelUsage()].sources.insert(source)
            }
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

enum DateParser {
    private static let formatters: [ISO8601DateFormatter] = {
        let withFractionalSeconds = ISO8601DateFormatter()
        withFractionalSeconds.formatOptions = [.withInternetDateTime, .withFractionalSeconds]

        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        return [withFractionalSeconds, plain]
    }()

    static func parse(_ string: String) -> Date? {
        formatters.lazy.compactMap { $0.date(from: string) }.first
    }
}
