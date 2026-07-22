import Foundation
import TokiUsageCore
import TokiUsageReaders

struct UsageOriginSlice {
    let origin: UsageOrigin
    let usage: RawTokenUsage
    let sourceStats: [SourceStat]
}

protocol OriginPartitionedTokenReader: TokenReader {
    func readUsageByOrigin(from startDate: Date, to endDate: Date) async throws -> [UsageOriginSlice]
}

extension OriginPartitionedTokenReader {
    func readUsage(from startDate: Date, to endDate: Date) async throws -> RawTokenUsage {
        let slices = try await readUsageByOrigin(from: startDate, to: endDate)
        var combined = RawTokenUsage()
        for slice in slices {
            combined += slice.usage
        }
        combined.recomputeMergedActiveEstimate(clippingEndDate: endDate)
        return combined
    }
}
