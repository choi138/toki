import Foundation
import TokiUsageCore

struct ReaderFetchResult {
    let index: Int
    let usage: RawTokenUsage
    let status: ReaderStatus
    let originSlices: [UsageOriginSlice]
    let fallbackSourceStats: [SourceStat]
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
