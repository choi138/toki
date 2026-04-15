import Foundation

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
