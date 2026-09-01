import Foundation
import TokiUsageCore

final class PiCompatibleUsageFileCache: @unchecked Sendable {
    static let shared = PiCompatibleUsageFileCache(maximumBytes: 512 * 1024 * 1024)

    private struct Key: Hashable {
        let path: String
        let source: String
        let isSubagent: Bool
        let replicaScope: String?
    }

    fileprivate struct Signature {
        let fileSize: Int
        let modifiedAt: TimeInterval
        let fileIdentifier: UInt64?
    }

    private struct Entry {
        let signature: Signature
        let parser: PiCompatibleSessionParser
        let records: [PiCompatibleUsageRecord]
        let processedLineCount: Int
        let fileEndedWithNewline: Bool
        let prefixFingerprint: UInt64
    }

    private let lock = NSLock()
    private let maximumBytes: Int
    private var entries: [Key: Entry] = [:]
    private var totalBytesRead = 0
    private var totalEntryBytes = 0
    private var accessOrder: [Key: UInt64] = [:]
    private var accessCounter: UInt64 = 0

    init(maximumBytes: Int = 512 * 1024 * 1024) {
        precondition(maximumBytes >= 0)
        self.maximumBytes = maximumBytes
    }

    var bytesRead: Int {
        lock.lock()
        defer { lock.unlock() }
        return totalBytesRead
    }

    var cachedFileCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return entries.count
    }

    func retainFiles(_ urls: [URL], source: PiCompatibleSource) {
        lock.lock()
        defer { lock.unlock() }
        let retainedPaths = Set(urls.map(\.path))
        for key in entries.keys
            where key.source == source.sourceName && !retainedPaths.contains(key.path) {
            removeEntry(for: key)
        }
    }

    func records(
        for url: URL,
        source: PiCompatibleSource,
        agentKind: WorkTimeAgentKind,
        replicaScope: String? = nil,
        limits: PiCompatibleReadLimits = .default) throws -> [PiCompatibleUsageRecord] {
        lock.lock()
        defer { lock.unlock() }
        try Task.checkCancellation()
        guard let signature = signature(for: url) else {
            throw PiCompatibleReaderError.unreadableFile(url)
        }
        let key = Key(
            path: url.path,
            source: source.sourceName,
            isSubagent: agentKind == .subagent,
            replicaScope: replicaScope)

        if let entry = entries[key],
           entry.signature.fileSize == signature.fileSize,
           entry.signature.modifiedAt == signature.modifiedAt,
           entry.signature.fileIdentifier == signature.fileIdentifier {
            touch(key)
            return try validatedRecords(entry.records, maximumCount: limits.maximumEventCount)
        }

        if let entry = entries[key],
           let updated = try appendedEntry(
               from: entry,
               signature: signature,
               url: url,
               limits: limits) {
            store(updated, for: key)
            return updated.records
        }

        let rebuilt = try rebuildEntry(
            url: url,
            signature: signature,
            source: source,
            agentKind: agentKind,
            replicaScope: replicaScope,
            limits: limits)
        store(rebuilt, for: key)
        return rebuilt.records
    }

    private func appendedEntry(
        from entry: Entry,
        signature: Signature,
        url: URL,
        limits: PiCompatibleReadLimits) throws -> Entry? {
        guard signature.fileSize > entry.signature.fileSize,
              signature.fileIdentifier == entry.signature.fileIdentifier,
              entry.fileEndedWithNewline,
              fingerprint(url, byteCount: entry.signature.fileSize) == entry.prefixFingerprint else {
            return nil
        }

        var parser = entry.parser
        var records = entry.records
        let result = try readLines(
            at: url,
            startingAt: entry.signature.fileSize,
            endingAt: signature.fileSize,
            initialLineIndex: entry.processedLineCount,
            limits: limits) { line, lineIndex in
                if let record = parser.record(fromJSONLLine: line, lineIndex: lineIndex) {
                    try append(record, to: &records, maximumCount: limits.maximumEventCount)
                }
            }
        totalBytesRead += result.bytesRead
        return Entry(
            signature: signature,
            parser: parser,
            records: records,
            processedLineCount: result.nextLineIndex,
            fileEndedWithNewline: result.endedWithNewline,
            prefixFingerprint: fingerprint(url, byteCount: signature.fileSize) ?? 0)
    }

    private func rebuildEntry(
        url: URL,
        signature: Signature,
        source: PiCompatibleSource,
        agentKind: WorkTimeAgentKind,
        replicaScope: String?,
        limits: PiCompatibleReadLimits) throws -> Entry {
        var parser = PiCompatibleSessionParser(
            streamID: url.path,
            source: source,
            agentKind: agentKind,
            replicaScope: replicaScope)
        var records: [PiCompatibleUsageRecord] = []
        let result = try readLines(
            at: url,
            startingAt: 0,
            endingAt: signature.fileSize,
            initialLineIndex: 0,
            limits: limits) { line, lineIndex in
                if let record = parser.record(fromJSONLLine: line, lineIndex: lineIndex) {
                    try append(record, to: &records, maximumCount: limits.maximumEventCount)
                }
            }
        totalBytesRead += result.bytesRead
        return Entry(
            signature: signature,
            parser: parser,
            records: records,
            processedLineCount: result.nextLineIndex,
            fileEndedWithNewline: result.endedWithNewline,
            prefixFingerprint: fingerprint(url, byteCount: signature.fileSize) ?? 0)
    }

    private func store(_ entry: Entry, for key: Key) {
        totalEntryBytes -= entries[key]?.signature.fileSize ?? 0
        entries[key] = entry
        totalEntryBytes += entry.signature.fileSize
        touch(key)
        while totalEntryBytes > maximumBytes,
              let leastRecentlyUsed = accessOrder.min(by: { $0.value < $1.value })?.key {
            removeEntry(for: leastRecentlyUsed)
        }
    }

    private func touch(_ key: Key) {
        accessCounter &+= 1
        accessOrder[key] = accessCounter
    }

    private func removeEntry(for key: Key) {
        totalEntryBytes -= entries.removeValue(forKey: key)?.signature.fileSize ?? 0
        accessOrder[key] = nil
    }
}

private func append(
    _ record: PiCompatibleUsageRecord,
    to records: inout [PiCompatibleUsageRecord],
    maximumCount: Int) throws {
    let (nextCount, overflow) = records.count.addingReportingOverflow(1)
    guard !overflow, nextCount <= maximumCount else {
        throw PiCompatibleReaderError.tooManyEvents(overflow ? Int.max : nextCount)
    }
    records.append(record)
}

private func validatedRecords(
    _ records: [PiCompatibleUsageRecord],
    maximumCount: Int) throws -> [PiCompatibleUsageRecord] {
    guard records.count <= maximumCount else {
        throw PiCompatibleReaderError.tooManyEvents(records.count)
    }
    return records
}

private struct PiCompatibleLineReadResult {
    let bytesRead: Int
    let nextLineIndex: Int
    let endedWithNewline: Bool
}

private func readLines(
    at url: URL,
    startingAt startOffset: Int,
    endingAt endOffset: Int,
    initialLineIndex: Int,
    limits: PiCompatibleReadLimits,
    body: (String, Int) throws -> Void) throws -> PiCompatibleLineReadResult {
    guard startOffset >= 0,
          endOffset >= startOffset,
          endOffset <= limits.maximumFileBytes else {
        throw PiCompatibleReaderError.fileTooLarge(url)
    }
    let handle: FileHandle
    do {
        handle = try FileHandle(forReadingFrom: url)
        try handle.seek(toOffset: UInt64(startOffset))
    } catch {
        throw PiCompatibleReaderError.unreadableFile(url)
    }
    defer { try? handle.close() }

    var pending = Data()
    var lineIndex = initialLineIndex
    var remaining = endOffset - startOffset
    var lastByte: UInt8?
    while remaining > 0 {
        try Task.checkCancellation()
        let requested = min(64 * 1024, remaining)
        let chunk: Data
        do {
            guard let data = try handle.read(upToCount: requested),
                  !data.isEmpty else {
                throw PiCompatibleReaderError.unreadableFile(url)
            }
            chunk = data
        } catch let error as PiCompatibleReaderError {
            throw error
        } catch {
            throw PiCompatibleReaderError.unreadableFile(url)
        }
        remaining -= chunk.count
        lastByte = chunk.last
        pending.append(chunk)

        while let newlineIndex = pending.firstIndex(of: 0x0A) {
            let lineData = pending.subdata(in: pending.startIndex..<newlineIndex)
            pending.removeSubrange(pending.startIndex...newlineIndex)
            try consumeCachedLine(
                lineData,
                at: url,
                lineIndex: lineIndex,
                limits: limits,
                body: body)
            lineIndex += 1
        }
        guard pending.count <= limits.maximumLineBytes else {
            throw PiCompatibleReaderError.lineTooLong(url)
        }
    }

    if !pending.isEmpty {
        try consumeCachedLine(
            pending,
            at: url,
            lineIndex: lineIndex,
            limits: limits,
            body: body)
        lineIndex += 1
    }
    return PiCompatibleLineReadResult(
        bytesRead: endOffset - startOffset,
        nextLineIndex: lineIndex,
        endedWithNewline: endOffset == 0 || lastByte == 0x0A)
}

private func consumeCachedLine(
    _ rawData: Data,
    at url: URL,
    lineIndex: Int,
    limits: PiCompatibleReadLimits,
    body: (String, Int) throws -> Void) throws {
    var data = rawData
    if data.last == 0x0D {
        data.removeLast()
    }
    guard data.count <= limits.maximumLineBytes else {
        throw PiCompatibleReaderError.lineTooLong(url)
    }
    guard !data.isEmpty,
          let line = String(data: data, encoding: .utf8) else {
        if data.isEmpty { return }
        throw PiCompatibleReaderError.invalidUTF8(url, line: lineIndex)
    }
    let trimmed = line.trimmingCharacters(in: .whitespaces)
    if !trimmed.isEmpty {
        try body(trimmed, lineIndex)
    }
}

private func signature(for url: URL) -> PiCompatibleUsageFileCache.Signature? {
    guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
          let modifiedAt = attributes[.modificationDate] as? Date,
          let fileSize = (attributes[.size] as? NSNumber)?.intValue else {
        return nil
    }
    return PiCompatibleUsageFileCache.Signature(
        fileSize: fileSize,
        modifiedAt: modifiedAt.timeIntervalSince1970,
        fileIdentifier: (attributes[.systemFileNumber] as? NSNumber)?.uint64Value)
}

private func fingerprint(_ url: URL, byteCount: Int) -> UInt64? {
    guard byteCount >= 0,
          let handle = try? FileHandle(forReadingFrom: url) else {
        return nil
    }
    defer { try? handle.close() }
    let sampleSize = min(4 * 1024, byteCount)
    do {
        let first = try handle.read(upToCount: sampleSize) ?? Data()
        try handle.seek(toOffset: UInt64(max(0, byteCount - sampleSize)))
        let last = try handle.read(upToCount: sampleSize) ?? Data()
        var hash: UInt64 = 14_695_981_039_346_656_037
        for byte in first {
            hash = (hash ^ UInt64(byte)) &* 1_099_511_628_211
        }
        hash = (hash ^ UInt64(byteCount)) &* 1_099_511_628_211
        for byte in last {
            hash = (hash ^ UInt64(byte)) &* 1_099_511_628_211
        }
        return hash
    } catch {
        return nil
    }
}
