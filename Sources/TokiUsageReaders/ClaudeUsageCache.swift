import Foundation
import TokiDurableStorage

private let claudeUsageCacheParserVersion = 2

public actor ClaudeUsageCache {
    public static let shared = ClaudeUsageCache(cacheURL: claudeUsageCacheURL())

    private let cacheURL: URL
    private var isLoaded = false
    private var entries: [String: ClaudeUsageCacheEntry] = [:]
    private var batchDepth = 0
    private var hasPendingChanges = false

    public init(cacheURL: URL) {
        self.cacheURL = cacheURL
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
            return nil
        }

        return cached.records
    }

    func store(records: [ClaudeCachedUsageRecord], for url: URL) async {
        await loadIfNeeded()

        guard let fileSignature = claudeFileSignature(for: url) else { return }

        entries[url.path] = ClaudeUsageCacheEntry(
            parserVersion: claudeUsageCacheParserVersion,
            fileSize: fileSignature.fileSize,
            modifiedAt: fileSignature.modifiedAt,
            records: records)

        hasPendingChanges = true
        persistIfNeeded()
    }

    public func reset() throws {
        entries = [:]
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

        guard let data = try? Data(contentsOf: cacheURL),
              let decoded = try? JSONDecoder().decode(ClaudeUsageCacheFile.self, from: data) else {
            entries = [:]
            return
        }

        entries = decoded.entries
    }

    private func persistIfNeeded() {
        guard hasPendingChanges, batchDepth == 0 else { return }

        let payload = ClaudeUsageCacheFile(entries: entries)
        guard let data = try? JSONEncoder().encode(payload) else { return }
        do {
            try DurableFileIO.writePrivate(data, to: cacheURL)
        } catch {
            return
        }
        hasPendingChanges = false
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
        cacheWrite: Int) {
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
