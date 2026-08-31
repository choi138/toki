import Foundation
import TokiUsageCore

struct CodexRolloutProcessingState: Codable {
    let processedByteCount: Int
    let processedLineCount: Int
    let fileEndedWithNewline: Bool
    let prefixFingerprint: UInt64
    let selectorState: CodexRolloutSnapshotSelectorState
    let previousSnapshot: CodexUsageSnapshot?
    let lastSnapshotTimestamp: TimeInterval?
    let lastSnapshotFileOrder: Int?
}

struct CodexRolloutProcessedSummary {
    let summary: CodexRolloutDailySummary
    let processingState: CodexRolloutProcessingState
    let didReadToEnd: Bool
}

func codexRolloutDailySummaryWithState(
    fromRolloutAt url: URL,
    signature: CodexFileSignature,
    includingDerivedData: Bool = true) -> CodexRolloutProcessedSummary {
    var selector = CodexRolloutSnapshotSelector()
    var snapshots: [CodexTimedSnapshot] = []
    var lineCount = 0

    let didReadToEnd = forEachJSONLLineUntil(
        at: url,
        startingAt: 0,
        endingAt: UInt64(signature.fileSize),
        initialLineIndex: 0,
        maximumBufferedLineByteCount: 1024 * 1024,
        shouldKeepOversizedLine: { data in
            codexDataShouldProcessRolloutLine(
                data,
                includeForkMarkers: selector.state.waitingForForkTurnContext)
        },
        shouldProcessLineData: { data in
            codexDataShouldProcessRolloutLine(
                data,
                includeForkMarkers: selector.state.waitingForForkTurnContext)
        }) { line, index in
            lineCount = index + 1
            if let snapshot = selector.snapshot(from: line, fileOrder: index) {
                snapshots.append(snapshot)
            }
            return true
        }

    snapshots.sort(by: codexSnapshotOrder)
    var summary = CodexRolloutDailySummary()
    let previousSnapshot = accumulateCodexSnapshots(
        snapshots,
        into: &summary,
        previousSnapshot: nil,
        includingDerivedData: includingDerivedData)
    if includingDerivedData {
        recomputeCodexActiveSeconds(in: &summary)
    }

    return CodexRolloutProcessedSummary(
        summary: summary,
        processingState: CodexRolloutProcessingState(
            processedByteCount: signature.fileSize,
            processedLineCount: lineCount,
            fileEndedWithNewline: codexFileEndedWithNewline(url, byteCount: signature.fileSize),
            prefixFingerprint: codexPrefixFingerprint(url, byteCount: signature.fileSize) ?? 0,
            selectorState: selector.state,
            previousSnapshot: previousSnapshot,
            lastSnapshotTimestamp: snapshots.last?.date.timeIntervalSince1970,
            lastSnapshotFileOrder: snapshots.last?.fileOrder),
        didReadToEnd: didReadToEnd)
}

func codexRolloutDailySummaryByAppending(
    fromRolloutAt url: URL,
    signature: CodexFileSignature,
    cachedEntry: CodexRolloutUsageCacheEntry,
    includingDerivedData: Bool = true) -> CodexRolloutProcessedSummary? {
    guard cachedEntry.isCurrentSchema,
          !includingDerivedData || cachedEntry.hasCompleteDerivedData,
          cachedEntry.timeZoneIdentifier == codexCacheTimeZoneIdentifier(),
          let state = cachedEntry.processingState,
          state.processedByteCount == cachedEntry.fileSize,
          signature.fileSize > state.processedByteCount,
          state.fileEndedWithNewline,
          let existingFingerprint = codexPrefixFingerprint(url, byteCount: state.processedByteCount),
          existingFingerprint == state.prefixFingerprint else {
        return nil
    }

    var selector = CodexRolloutSnapshotSelector(state: state.selectorState)
    var appendedSnapshots: [CodexTimedSnapshot] = []
    var lineCount = state.processedLineCount

    let didReadToEnd = forEachJSONLLineUntil(
        at: url,
        startingAt: UInt64(state.processedByteCount),
        endingAt: UInt64(signature.fileSize),
        initialLineIndex: state.processedLineCount,
        maximumBufferedLineByteCount: 1024 * 1024,
        shouldKeepOversizedLine: { data in
            codexDataShouldProcessRolloutLine(
                data,
                includeForkMarkers: selector.state.waitingForForkTurnContext)
        },
        shouldProcessLineData: { data in
            codexDataShouldProcessRolloutLine(
                data,
                includeForkMarkers: selector.state.waitingForForkTurnContext)
        }) { line, index in
            lineCount = index + 1
            if let snapshot = selector.snapshot(from: line, fileOrder: index) {
                appendedSnapshots.append(snapshot)
            }
            return true
        }
    guard !Task.isCancelled, didReadToEnd else { return nil }

    appendedSnapshots.sort(by: codexSnapshotOrder)
    if let first = appendedSnapshots.first,
       let lastTimestamp = state.lastSnapshotTimestamp,
       let lastFileOrder = state.lastSnapshotFileOrder,
       first.date.timeIntervalSince1970 < lastTimestamp
       || (first.date.timeIntervalSince1970 == lastTimestamp && first.fileOrder < lastFileOrder) {
        return nil
    }

    var summary = cachedEntry.summary
    let previousSnapshot = accumulateCodexSnapshots(
        appendedSnapshots,
        into: &summary,
        previousSnapshot: state.previousSnapshot,
        includingDerivedData: includingDerivedData)
    if includingDerivedData {
        recomputeCodexActiveSeconds(in: &summary)
    }

    return CodexRolloutProcessedSummary(
        summary: summary,
        processingState: CodexRolloutProcessingState(
            processedByteCount: signature.fileSize,
            processedLineCount: lineCount,
            fileEndedWithNewline: codexFileEndedWithNewline(url, byteCount: signature.fileSize),
            prefixFingerprint: codexPrefixFingerprint(url, byteCount: signature.fileSize) ?? 0,
            selectorState: selector.state,
            previousSnapshot: previousSnapshot,
            lastSnapshotTimestamp: appendedSnapshots.last?.date.timeIntervalSince1970
                ?? state.lastSnapshotTimestamp,
            lastSnapshotFileOrder: appendedSnapshots.last?.fileOrder ?? state.lastSnapshotFileOrder),
        didReadToEnd: true)
}

func accumulateCodexSnapshots(
    _ snapshots: [CodexTimedSnapshot],
    into summary: inout CodexRolloutDailySummary,
    previousSnapshot initialPreviousSnapshot: CodexUsageSnapshot?,
    includingDerivedData: Bool = true) -> CodexUsageSnapshot? {
    var previousSnapshot = initialPreviousSnapshot

    for entry in snapshots {
        guard !Task.isCancelled else { return previousSnapshot }

        let usage = entry.usage(since: previousSnapshot)
        previousSnapshot = entry.tokenCount.nextBaseline(after: previousSnapshot)

        guard usage.totalTokens > 0 else { continue }

        let dayKey = codexDayKey(for: entry.date)
        summary.dailyUsage[dayKey, default: .zero].accumulate(usage)
        if includingDerivedData {
            summary.dailyActivityTimestamps[dayKey, default: []].append(entry.date.timeIntervalSince1970)
            summary.dailyTokenUsageEvents[dayKey, default: []].append(
                CodexCachedTokenUsageEvent(timestamp: entry.date, usage: usage))
        }
    }

    return previousSnapshot
}

func recomputeCodexActiveSeconds(in summary: inout CodexRolloutDailySummary) {
    for dayKey in summary.dailyUsage.keys {
        summary.dailyUsage[dayKey]?.activeSeconds = 0
    }

    let activityTimestamps = summary.dailyActivityTimestamps.values
        .flatMap { $0 }
        .map { Date(timeIntervalSince1970: $0) }
    for (dayKey, seconds) in dailyActiveSeconds(from: activityTimestamps) {
        summary.dailyUsage[dayKey, default: .zero].activeSeconds += seconds
    }
}

private func codexFileEndedWithNewline(_ url: URL, byteCount: Int) -> Bool {
    guard byteCount > 0,
          let byte = codexFileData(url, offset: byteCount - 1, count: 1)?.first else {
        return byteCount == 0
    }
    return byte == 0x0A
}

private func codexPrefixFingerprint(_ url: URL, byteCount: Int) -> UInt64? {
    guard byteCount >= 0 else { return nil }
    let sampleSize = min(4 * 1024, byteCount)
    guard let first = codexFileData(url, offset: 0, count: sampleSize),
          let last = codexFileData(url, offset: max(0, byteCount - sampleSize), count: sampleSize) else {
        return nil
    }

    var hash: UInt64 = 14_695_981_039_346_656_037
    for byte in first {
        hash = (hash ^ UInt64(byte)) &* 1_099_511_628_211
    }
    hash = (hash ^ UInt64(byteCount)) &* 1_099_511_628_211
    for byte in last {
        hash = (hash ^ UInt64(byte)) &* 1_099_511_628_211
    }
    return hash
}

private func codexFileData(_ url: URL, offset: Int, count: Int) -> Data? {
    guard offset >= 0, count >= 0,
          let handle = try? FileHandle(forReadingFrom: url) else {
        return nil
    }
    defer { try? handle.close() }

    do {
        try handle.seek(toOffset: UInt64(offset))
        return try handle.read(upToCount: count)
    } catch {
        return nil
    }
}
