import Foundation
import TokiUsageCore
import TokiUsageReaders

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
        let includesLocal: Bool = switch scope {
        case .all: true
        case let .origin(originID): originID == .local
        }
        // Hermes totals must retain collection diagnostics from the same read as the tokens.
        // Its default total-token implementation already reads the full usage value.
        if reader is HermesReader, includesLocal {
            let usage = try await reader.readUsage(from: startDate, to: endDate)
            let message = readerPartialUsageMessage(usage)
            return ReaderTotalFetchResult(
                index: index,
                totalTokens: usage.totalTokens,
                status: ReaderStatus(
                    name: reader.name,
                    state: message != nil ? .partial : (usage.totalTokens > 0 ? .loaded : .empty),
                    message: message,
                    lastReadAt: Date(),
                    totalTokens: usage.totalTokens,
                    isOriginPartitioned: false))
        }
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

func readerPartialUsageMessage(_ usage: RawTokenUsage) -> String? {
    let count = usage.supplemental.first {
        $0.id == "hermes-profile-read-errors" && $0.source == HermesReader.sourceName
    }?.value ?? 0
    guard count > 0 else { return nil }
    return "Partial usage: \(count) profile\(count == 1 ? "" : "s") could not be read."
}
