import Foundation

protocol TokenReader {
    var name: String { get }
    func readUsage(from startDate: Date, to endDate: Date) async throws -> RawTokenUsage
    func readTotalTokens(from startDate: Date, to endDate: Date) async throws -> Int
}

extension TokenReader {
    func readTotalTokens(from startDate: Date, to endDate: Date) async throws -> Int {
        try await readUsage(from: startDate, to: endDate).totalTokens
    }
}
