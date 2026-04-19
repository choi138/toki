import Foundation

protocol TokenReader {
    var name: String { get }
    func readUsage(from startDate: Date, to endDate: Date) async throws -> RawTokenUsage
}
