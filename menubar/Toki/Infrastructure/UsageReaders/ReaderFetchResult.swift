import Foundation
import TokiUsageCore

struct ReaderFetchResult {
    let index: Int
    let usage: RawTokenUsage
    let status: ReaderStatus
    let originSlices: [UsageOriginSlice]
    let fallbackSourceStats: [SourceStat]
}

struct ReaderTotalFetchResult {
    let index: Int
    let totalTokens: Int
    let status: ReaderStatus
}

func emptyReaderFetchResult(
    index: Int,
    reader: any TokenReader,
    state: ReaderStatusState,
    message: String? = nil,
    lastReadAt: Date? = nil) -> ReaderFetchResult {
    ReaderFetchResult(
        index: index,
        usage: RawTokenUsage(),
        status: ReaderStatus(
            name: reader.name,
            state: state,
            message: message,
            lastReadAt: lastReadAt,
            totalTokens: 0,
            isOriginPartitioned: reader is any OriginPartitionedTokenReader),
        originSlices: [],
        fallbackSourceStats: [])
}

func readerTotalFetchResult(
    index: Int,
    reader: any TokenReader,
    scope: UsageScope,
    from startDate: Date,
    to endDate: Date) async -> ReaderTotalFetchResult {
    guard !Task.isCancelled else {
        return ReaderTotalFetchResult(
            index: index,
            totalTokens: 0,
            status: ReaderStatus(
                name: reader.name,
                state: .empty,
                message: nil,
                lastReadAt: nil,
                totalTokens: 0,
                isOriginPartitioned: reader is any OriginPartitionedTokenReader))
    }

    do {
        let totalTokens: Int = switch scope {
        case .all:
            try await reader.readTotalTokens(from: startDate, to: endDate)
        case let .origin(originID):
            if let partitionedReader = reader as? any OriginPartitionedTokenReader {
                try await partitionedReader
                    .readUsageByOrigin(from: startDate, to: endDate)
                    .filter { $0.origin.id == originID }
                    .reduce(0) { $0 + $1.usage.totalTokens }
            } else if originID == .local {
                try await reader.readTotalTokens(from: startDate, to: endDate)
            } else {
                0
            }
        }
        return ReaderTotalFetchResult(
            index: index,
            totalTokens: totalTokens,
            status: ReaderStatus(
                name: reader.name,
                state: totalTokens > 0 ? .loaded : .empty,
                message: nil,
                lastReadAt: Date(),
                totalTokens: totalTokens,
                isOriginPartitioned: reader is any OriginPartitionedTokenReader))
    } catch {
        return ReaderTotalFetchResult(
            index: index,
            totalTokens: 0,
            status: ReaderStatus(
                name: reader.name,
                state: .failed,
                message: error.localizedDescription,
                lastReadAt: Date(),
                totalTokens: 0,
                isOriginPartitioned: reader is any OriginPartitionedTokenReader))
    }
}
