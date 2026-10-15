import Foundation
import TokiUsageCore

extension ClaudeCodeReader {
    enum FileScope {
        case allFiles
        case filesModifiedSinceStart
    }

    /// Velocity samples run every few seconds: append-only transcripts untouched since `startDate`
    /// hold no in-range records, and the full cache rewrite is left to the next `readUsage`.
    public func readOutputTokens(from startDate: Date, to endDate: Date) async throws -> Int {
        try await readUsage(from: startDate, to: endDate, scope: .filesModifiedSinceStart).outputTokens
    }

    static func filesModified(since startDate: Date, in files: Set<URL>) -> Set<URL> {
        files.filter { url in
            let values = try? url.resourceValues(forKeys: [.contentModificationDateKey])
            return values?.contentModificationDate.map { $0 >= startDate } ?? true
        }
    }
}
