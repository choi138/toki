import Foundation

private struct JSONLDateBounds {
    let first: Date?
    let last: Date?

    var isEmpty: Bool {
        first == nil && last == nil
    }
}

private actor JSONLDateBoundsCache {
    static let shared = JSONLDateBoundsCache()

    private var storage: [String: JSONLDateBoundsCacheEntry] = [:]

    func bounds(
        for identityKey: String,
        signature: JSONLDateBoundsSignature
    ) -> JSONLDateBounds? {
        guard let cached = storage[identityKey],
              cached.signature == signature else {
            return nil
        }
        return cached.bounds
    }

    func store(
        _ bounds: JSONLDateBounds,
        for identityKey: String,
        signature: JSONLDateBoundsSignature
    ) {
        storage[identityKey] = JSONLDateBoundsCacheEntry(
            signature: signature,
            bounds: bounds
        )
    }
}

private struct JSONLDateBoundsCacheEntry {
    let signature: JSONLDateBoundsSignature
    let bounds: JSONLDateBounds
}

private struct JSONLDateBoundsSignature: Equatable {
    let modifiedAt: TimeInterval
    let fileSize: Int
}

// MARK: - Per-Model Usage

struct PerModelUsage {
    var totalTokens: Int = 0
    var cost: Double = 0
    var sources: Set<String> = []
}

// MARK: - Raw Token Usage

struct RawTokenUsage {
    var inputTokens: Int = 0
    var outputTokens: Int = 0
    var cacheReadTokens: Int = 0
    var cacheWriteTokens: Int = 0
    var reasoningTokens: Int = 0

    var cost: Double = 0
    var perModel: [String: PerModelUsage] = [:]

    var totalTokens: Int {
        inputTokens + outputTokens + cacheReadTokens + cacheWriteTokens + reasoningTokens
    }
}

func += (lhs: inout RawTokenUsage, rhs: RawTokenUsage) {
    lhs.inputTokens += rhs.inputTokens
    lhs.outputTokens += rhs.outputTokens
    lhs.cacheReadTokens += rhs.cacheReadTokens
    lhs.cacheWriteTokens += rhs.cacheWriteTokens
    lhs.reasoningTokens += rhs.reasoningTokens

    lhs.cost += rhs.cost
    rhs.perModel.forEach { id, usage in
        lhs.perModel[id, default: PerModelUsage()].totalTokens += usage.totalTokens
        lhs.perModel[id, default: PerModelUsage()].cost += usage.cost
        lhs.perModel[id, default: PerModelUsage()].sources.formUnion(usage.sources)
    }
}

// MARK: - Protocol

protocol TokenReader {
    var name: String { get }
    func readUsage(from startDate: Date, to endDate: Date) async throws -> RawTokenUsage
}

// MARK: - Shared Utilities

func homeDir() -> URL {
    FileManager.default.homeDirectoryForCurrentUser
}

func startOfToday() -> Date {
    Calendar.current.startOfDay(for: Date())
}

func findFiles(in directory: URL, withExtension ext: String, modifiedAfter: Date? = nil) -> [URL] {
    let keys: [URLResourceKey] = modifiedAfter != nil
        ? [.isRegularFileKey, .contentModificationDateKey]
        : [.isRegularFileKey]

    guard FileManager.default.fileExists(atPath: directory.path),
          let enumerator = FileManager.default.enumerator(
              at: directory,
              includingPropertiesForKeys: keys,
              options: [.skipsHiddenFiles]
          ) else { return [] }

    return enumerator.compactMap { item -> URL? in
        guard let url = item as? URL, url.pathExtension == ext else { return nil }

        if let since = modifiedAfter {
            let modDate = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
            guard let mod = modDate, mod >= since else { return nil }
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

func jsonLineStringValue(_ line: String, forKey key: String) -> String? {
    let prefix = "\"\(key)\":\""
    guard let start = line.range(of: prefix)?.upperBound,
          let end = line[start...].firstIndex(of: "\"") else {
        return nil
    }
    return String(line[start..<end])
}

func jsonLineDate(_ line: String, keys: [String]) -> Date? {
    for key in keys {
        guard let value = jsonLineStringValue(line, forKey: key),
              let date = DateParser.parse(value) else { continue }
        return date
    }
    return nil
}

func jsonlFileOverlapsRange(
    at url: URL,
    startDate: Date,
    endDate: Date,
    timestampKeys: [String]
) async -> Bool {
    let bounds = await cachedJSONLDateBounds(at: url, timestampKeys: timestampKeys)

    // If we fail to infer file bounds, keep the file in the candidate set so we
    // do not accidentally undercount usage because of a format edge case.
    guard !bounds.isEmpty else { return true }

    if let first = bounds.first, first >= endDate {
        return false
    }

    return true
}

private func cachedJSONLDateBounds(
    at url: URL,
    timestampKeys: [String]
) async -> JSONLDateBounds {
    guard let identityKey = jsonlDateBoundsIdentityKey(for: url, timestampKeys: timestampKeys),
          let signature = jsonlDateBoundsSignature(for: url) else {
        return computeJSONLDateBounds(at: url, timestampKeys: timestampKeys)
    }

    if let cached = await JSONLDateBoundsCache.shared.bounds(
        for: identityKey,
        signature: signature
    ) {
        return cached
    }

    let computed = computeJSONLDateBounds(at: url, timestampKeys: timestampKeys)

    await JSONLDateBoundsCache.shared.store(computed, for: identityKey, signature: signature)

    return computed
}

private func jsonlDateBoundsIdentityKey(for url: URL, timestampKeys: [String]) -> String? {
    guard !url.path.isEmpty else { return nil }
    let keys = timestampKeys.sorted().joined(separator: ",")
    return "\(url.path)|\(keys)"
}

private func jsonlDateBoundsSignature(for url: URL) -> JSONLDateBoundsSignature? {
    guard let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey]),
          let modifiedAt = values.contentModificationDate,
          let fileSize = values.fileSize else {
        return nil
    }

    return JSONLDateBoundsSignature(
        modifiedAt: modifiedAt.timeIntervalSince1970,
        fileSize: fileSize
    )
}

private func computeJSONLDateBounds(
    at url: URL,
    timestampKeys: [String]
) -> JSONLDateBounds {
    let headLines = readJSONLWindowLines(at: url, maxBytes: 65_536, fromStart: true)
    let tailLines = readJSONLWindowLines(at: url, maxBytes: 65_536, fromStart: false)

    let first = headLines.lazy.compactMap { jsonLineDate($0, keys: timestampKeys) }.first
    let last = tailLines.reversed().lazy.compactMap { jsonLineDate($0, keys: timestampKeys) }.first

    return JSONLDateBounds(first: first, last: last)
}

private func readJSONLWindowLines(
    at url: URL,
    maxBytes: Int,
    fromStart: Bool
) -> [String] {
    guard let handle = try? FileHandle(forReadingFrom: url) else { return [] }
    defer { try? handle.close() }

    let fileSize = (try? handle.seekToEnd()) ?? 0
    guard fileSize > 0 else { return [] }

    let windowSize = min(UInt64(maxBytes), fileSize)
    let offset = fromStart ? 0 : fileSize - windowSize
    try? handle.seek(toOffset: offset)

    var data = handle.readData(ofLength: Int(windowSize))
    guard !data.isEmpty else { return [] }

    if fromStart {
        if fileSize > windowSize,
           let lastNewline = data.lastIndex(of: UInt8(ascii: "\n")) {
            data = Data(data[...lastNewline])
        }
    } else if offset > 0,
              let firstNewline = data.firstIndex(of: UInt8(ascii: "\n")) {
        data = Data(data[data.index(after: firstNewline)...])
    }

    guard let text = String(data: data, encoding: .utf8) else { return [] }

    return text
        .components(separatedBy: .newlines)
        .map { $0.trimmingCharacters(in: .whitespaces) }
        .filter { !$0.isEmpty }
}

enum DateParser {
    private static let formatters: [ISO8601DateFormatter] = {
        let withFrac = ISO8601DateFormatter()
        withFrac.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        return [withFrac, plain]
    }()

    static func parse(_ string: String) -> Date? {
        return formatters.lazy.compactMap { $0.date(from: string) }.first
    }
}
