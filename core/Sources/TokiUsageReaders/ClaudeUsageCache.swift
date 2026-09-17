import Foundation
import TokiDurableStorage

// Reparse older entries through the bounded reader and its recording diagnostics.
private let claudeUsageCacheParserVersion = 4
public let maximumClaudeUsageCacheBytes = 64 * 1024 * 1024
// `{"entries":{}}` around the persisted entries.
private let claudeUsageCachePayloadEnvelopeBytes = 14

public actor ClaudeUsageCache {
    public static let shared = ClaudeUsageCache(cacheURL: claudeUsageCacheURL())

    private let cacheURL: URL
    private let maximumBytes: Int
    private let maximumEntryCount: Int
    private var isLoaded = false
    private var entries: [String: ClaudeUsageCacheEntry] = [:]
    private var entryByteCounts: [String: Int] = [:]
    private var totalPayloadBytes = 0
    private var accessOrder: [String: UInt64] = [:]
    private var accessCounter: UInt64 = 0
    private var batchDepth = 0
    private var hasPendingChanges = false

    public init(
        cacheURL: URL,
        maximumBytes: Int = maximumClaudeUsageCacheBytes,
        maximumEntryCount: Int = 2048) {
        precondition(maximumBytes >= 0)
        precondition(maximumEntryCount > 0)
        self.cacheURL = cacheURL
        self.maximumBytes = maximumBytes
        self.maximumEntryCount = maximumEntryCount
    }

    func beginBatch() async {
        await loadIfNeeded()
        batchDepth += 1
    }

    func endBatch() async {
        await loadIfNeeded()
        batchDepth = max(0, batchDepth - 1)
        persistIfNeeded()
    }

    func records(for url: URL) async -> [ClaudeCachedUsageRecord]? {
        await loadIfNeeded()

        guard let fileSignature = claudeFileSignature(for: url),
              let cached = entries[url.path],
              cached.parserVersion == claudeUsageCacheParserVersion,
              cached.fileSize == fileSignature.fileSize,
              cached.modifiedAt == fileSignature.modifiedAt else {
            removeEntry(path: url.path)
            return nil
        }

        touch(url.path)
        return cached.records
    }

    func retainFiles(_ urls: Set<URL>) async {
        await loadIfNeeded()
        let retainedPaths = Set(urls.map(\.path))
        for path in entries.keys where !retainedPaths.contains(path) {
            removeEntry(path: path)
        }
        persistIfNeeded()
    }

    func store(records: [ClaudeCachedUsageRecord], for url: URL) async {
        await loadIfNeeded()

        guard let fileSignature = claudeFileSignature(for: url) else { return }

        let entry = ClaudeUsageCacheEntry(
            parserVersion: claudeUsageCacheParserVersion,
            fileSize: fileSignature.fileSize,
            modifiedAt: fileSignature.modifiedAt,
            records: records)
        guard let byteCount = payloadByteCount(path: url.path, entry: entry),
              claudeUsageCachePayloadEnvelopeBytes + byteCount <= maximumBytes else {
            removeEntry(path: url.path)
            persistIfNeeded()
            return
        }

        totalPayloadBytes -= entryByteCounts[url.path] ?? 0
        entries[url.path] = entry
        entryByteCounts[url.path] = byteCount
        totalPayloadBytes += byteCount
        touch(url.path)
        enforceMemoryLimit()
        hasPendingChanges = true
        persistIfNeeded()
    }

    public func reset() throws {
        entries = [:]
        entryByteCounts = [:]
        totalPayloadBytes = 0
        accessOrder = [:]
        accessCounter = 0
        batchDepth = 0
        hasPendingChanges = false
        isLoaded = true

        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: cacheURL.path)
            || (try? fileManager.destinationOfSymbolicLink(atPath: cacheURL.path)) != nil else {
            return
        }
        let values = try cacheURL.resourceValues(forKeys: [.isDirectoryKey])
        guard values.isDirectory != true else {
            throw ClaudeUsageCacheError.invalidCacheFile
        }
        try fileManager.removeItem(at: cacheURL)
    }

    private func loadIfNeeded() async {
        guard !isLoaded else { return }
        isLoaded = true

        let data: Data?
        do {
            data = try DurableFileIO.readPrivate(
                from: cacheURL,
                maximumByteCount: maximumBytes)
        } catch {
            replaceInvalidCache()
            return
        }
        guard let data else { return }
        guard let decoded = try? JSONDecoder().decode(ClaudeUsageCacheFile.self, from: data) else {
            replaceInvalidCache()
            return
        }

        for path in decoded.entries.keys.sorted() {
            guard let entry = decoded.entries[path],
                  let byteCount = payloadByteCount(path: path, entry: entry),
                  claudeUsageCachePayloadEnvelopeBytes + byteCount <= maximumBytes else {
                hasPendingChanges = true
                continue
            }
            entries[path] = entry
            entryByteCounts[path] = byteCount
            totalPayloadBytes += byteCount
            touch(path)
            enforceMemoryLimit()
        }
        persistIfNeeded()
    }

    private func persistIfNeeded() {
        guard hasPendingChanges, batchDepth == 0 else { return }

        guard let data = encodedPayloadWithinLimit() else { return }
        do {
            try DurableFileIO.writePrivate(data, to: cacheURL)
        } catch {
            return
        }
        hasPendingChanges = false
    }

    private func encodedPayloadWithinLimit() -> Data? {
        while true {
            guard let data = try? JSONEncoder().encode(ClaudeUsageCacheFile(entries: entries)) else {
                return nil
            }
            if data.count <= maximumBytes { return data }
            // totalPayloadBytes is an upper bound on this size, so evicting here is
            // only a safety net; without it an oversized cache would never persist.
            guard let path = leastRecentlyUsedPath else { return nil }
            removeEntry(path: path)
        }
    }

    /// Bytes `"path":<entry>,` adds to the persisted object. `[path]` yields the
    /// key exactly as JSONEncoder escapes it; its brackets stand in for the
    /// colon and comma.
    private func payloadByteCount(path: String, entry: ClaudeUsageCacheEntry) -> Int? {
        let encoder = JSONEncoder()
        guard let entryData = try? encoder.encode(entry),
              let keyData = try? encoder.encode([path]) else {
            return nil
        }
        return entryData.count + keyData.count
    }

    private func replaceInvalidCache() {
        entries = [:]
        hasPendingChanges = true
        persistIfNeeded()
    }

    private func enforceMemoryLimit() {
        while claudeUsageCachePayloadEnvelopeBytes + totalPayloadBytes > maximumBytes
            || entries.count > maximumEntryCount {
            guard let path = leastRecentlyUsedPath else { return }
            removeEntry(path: path)
        }
    }

    private var leastRecentlyUsedPath: String? {
        accessOrder.min(by: { $0.value < $1.value })?.key
    }

    private func removeEntry(path: String) {
        guard entries.removeValue(forKey: path) != nil else { return }
        totalPayloadBytes -= entryByteCounts.removeValue(forKey: path) ?? 0
        accessOrder[path] = nil
        hasPendingChanges = true
    }

    private func touch(_ path: String) {
        accessCounter &+= 1
        accessOrder[path] = accessCounter
    }
}

private struct ClaudeUsageCacheFile: Codable {
    let entries: [String: ClaudeUsageCacheEntry]
}

private struct ClaudeUsageCacheEntry: Codable {
    let parserVersion: Int?
    let fileSize: Int
    let modifiedAt: TimeInterval
    let records: [ClaudeCachedUsageRecord]

    init(
        parserVersion: Int? = nil,
        fileSize: Int,
        modifiedAt: TimeInterval,
        records: [ClaudeCachedUsageRecord]) {
        self.parserVersion = parserVersion
        self.fileSize = fileSize
        self.modifiedAt = modifiedAt
        self.records = records
    }
}

struct ClaudeCachedUsageRecord: Codable {
    let lineIndex: Int
    let timestamp: TimeInterval
    let requestId: String?
    let sessionID: String?
    let cwd: String?
    let messageID: String?
    let model: String?
    let input: Int
    let output: Int
    let cacheRead: Int
    let cacheWrite: Int
    let cacheWriteOneHour: Int

    init(
        lineIndex: Int,
        timestamp: TimeInterval,
        requestId: String?,
        sessionID: String? = nil,
        cwd: String? = nil,
        messageID: String?,
        model: String?,
        input: Int,
        output: Int,
        cacheRead: Int,
        cacheWrite: Int,
        cacheWriteOneHour: Int = 0) {
        self.lineIndex = lineIndex
        self.timestamp = timestamp
        self.requestId = requestId
        self.sessionID = sessionID
        self.cwd = cwd
        self.messageID = messageID
        self.model = model
        self.input = input
        self.output = output
        self.cacheRead = cacheRead
        self.cacheWrite = cacheWrite
        self.cacheWriteOneHour = cacheWriteOneHour
    }
}

private struct ClaudeFileSignature {
    let fileSize: Int
    let modifiedAt: TimeInterval
}

private func claudeFileSignature(for url: URL) -> ClaudeFileSignature? {
    guard let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey]),
          let modifiedAt = values.contentModificationDate,
          let fileSize = values.fileSize else {
        return nil
    }

    return ClaudeFileSignature(
        fileSize: fileSize,
        modifiedAt: modifiedAt.timeIntervalSince1970)
}

private enum ClaudeUsageCacheError: Error {
    case invalidCacheFile
}

public func claudeUsageCacheURL(
    paths: LocalUsageReaderPaths = LocalUsageReaderPaths(),
    scope: LocalUsageCacheScope = .application) -> URL {
    paths.cacheDirectory(for: scope).appendingPathComponent("claude-usage-cache.json")
}
