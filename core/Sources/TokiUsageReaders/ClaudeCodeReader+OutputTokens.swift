import Foundation
import TokiUsageCore

public extension ClaudeCodeReader {
    /// Velocity samples run every few seconds, so this skips cache pruning and leaves the full
    /// cache rewrite to the next `readUsage`.
    func readOutputTokens(from startDate: Date, to endDate: Date) async throws -> Int {
        try await readUsage(from: startDate, to: endDate, maintainsCache: false).outputTokens
    }
}
