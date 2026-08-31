import Foundation
import TokiSyncProtocol

struct PiCompatibleReadLimits: Equatable {
    static let `default` = PiCompatibleReadLimits(
        maximumFileCount: 50000,
        maximumFileBytes: 256 * 1024 * 1024,
        maximumLineBytes: 4 * 1024 * 1024,
        maximumEventCount: RemoteUsageSnapshotValidator.maximumTokenEventCount,
        maximumEntryCount: 500_000)

    let maximumFileCount: Int
    let maximumFileBytes: Int
    let maximumLineBytes: Int
    let maximumEventCount: Int
    let maximumEntryCount: Int

    init(
        maximumFileCount: Int,
        maximumFileBytes: Int,
        maximumLineBytes: Int,
        maximumEventCount: Int,
        maximumEntryCount: Int? = nil) {
        self.maximumFileCount = maximumFileCount
        self.maximumFileBytes = maximumFileBytes
        self.maximumLineBytes = maximumLineBytes
        self.maximumEventCount = maximumEventCount
        self.maximumEntryCount = maximumEntryCount
            ?? Self.defaultEntryCount(for: maximumFileCount)
    }

    private static func defaultEntryCount(for maximumFileCount: Int) -> Int {
        let (scaled, overflow) = maximumFileCount.multipliedReportingOverflow(by: 10)
        return overflow ? Int.max : max(maximumFileCount, scaled)
    }
}

enum PiCompatibleReaderError: LocalizedError, Equatable {
    case tooManyFiles(Int)
    case fileTooLarge(URL)
    case lineTooLong(URL)
    case invalidUTF8(URL, line: Int)
    case unreadableFile(URL)
    case tooManyEvents(Int)
    case tooManyEntries(Int)

    var errorDescription: String? {
        switch self {
        case let .tooManyFiles(count):
            "The session source contains too many files (\(count))."
        case let .fileTooLarge(url):
            "The session file \(url.lastPathComponent) exceeds the supported size."
        case let .lineTooLong(url):
            "The session file \(url.lastPathComponent) contains an oversized record."
        case let .invalidUTF8(url, line):
            "The session file \(url.lastPathComponent) contains invalid UTF-8 at line \(line + 1)."
        case let .unreadableFile(url):
            "The session file \(url.lastPathComponent) could not be read."
        case let .tooManyEvents(count):
            "The session source contains too many usage events (\(count))."
        case let .tooManyEntries(count):
            "The session source contains too many filesystem entries (\(count))."
        }
    }
}

func forEachBoundedJSONLLine(
    at url: URL,
    limits: PiCompatibleReadLimits,
    _ body: (String, Int) throws -> Void) throws {
    let handle: FileHandle
    do {
        handle = try FileHandle(forReadingFrom: url)
    } catch {
        throw PiCompatibleReaderError.unreadableFile(url)
    }
    defer { try? handle.close() }
    do {
        let fileSize = try handle.seekToEnd()
        guard fileSize <= UInt64(limits.maximumFileBytes) else {
            throw PiCompatibleReaderError.fileTooLarge(url)
        }
        try handle.seek(toOffset: 0)
    } catch let error as PiCompatibleReaderError {
        throw error
    } catch {
        throw PiCompatibleReaderError.unreadableFile(url)
    }

    var lineIndex = 0
    var pending = Data()
    var consumedBytes = 0

    while true {
        try Task.checkCancellation()
        let chunk: Data
        do {
            guard let data = try handle.read(upToCount: 64 * 1024),
                  !data.isEmpty else {
                break
            }
            chunk = data
        } catch {
            throw PiCompatibleReaderError.unreadableFile(url)
        }

        let (nextConsumedBytes, overflow) = consumedBytes.addingReportingOverflow(chunk.count)
        guard !overflow, nextConsumedBytes <= limits.maximumFileBytes else {
            throw PiCompatibleReaderError.fileTooLarge(url)
        }
        consumedBytes = nextConsumedBytes
        pending.append(chunk)
        while let newlineIndex = pending.firstIndex(of: 0x0A) {
            guard pending.distance(from: pending.startIndex, to: newlineIndex)
                <= limits.maximumLineBytes else {
                throw PiCompatibleReaderError.lineTooLong(url)
            }
            let lineData = pending.subdata(in: pending.startIndex..<newlineIndex)
            pending.removeSubrange(pending.startIndex...newlineIndex)
            try consumeJSONLLine(
                lineData,
                at: url,
                lineIndex: lineIndex,
                limits: limits,
                body)
            lineIndex += 1
        }
        guard pending.count <= limits.maximumLineBytes else {
            throw PiCompatibleReaderError.lineTooLong(url)
        }
    }

    do {
        guard try handle.seekToEnd() <= UInt64(limits.maximumFileBytes) else {
            throw PiCompatibleReaderError.fileTooLarge(url)
        }
    } catch let error as PiCompatibleReaderError {
        throw error
    } catch {
        throw PiCompatibleReaderError.unreadableFile(url)
    }

    if !pending.isEmpty {
        try consumeJSONLLine(
            pending,
            at: url,
            lineIndex: lineIndex,
            limits: limits,
            body)
    }
}

private func consumeJSONLLine(
    _ rawData: Data,
    at url: URL,
    lineIndex: Int,
    limits: PiCompatibleReadLimits,
    _ body: (String, Int) throws -> Void) throws {
    var data = rawData
    if data.last == 0x0D {
        data.removeLast()
    }
    guard data.count <= limits.maximumLineBytes else {
        throw PiCompatibleReaderError.lineTooLong(url)
    }
    guard !data.isEmpty else { return }
    guard let line = String(data: data, encoding: .utf8) else {
        throw PiCompatibleReaderError.invalidUTF8(url, line: lineIndex)
    }
    let trimmed = line.trimmingCharacters(in: .whitespaces)
    guard !trimmed.isEmpty else { return }
    try body(trimmed, lineIndex)
}

func boundedUsageTokenCount(_ value: Int?) -> Int {
    min(
        max(0, value ?? 0),
        RemoteUsageSnapshotValidator.maximumTokenCountPerBucket)
}

func boundedUsageCost(_ value: Double?) -> Double {
    guard let value, value.isFinite else { return 0 }
    return min(max(0, value), RemoteUsageSnapshotValidator.maximumCostPerEvent)
}

func boundedRecordedUsageCost(_ value: Double?) -> Double? {
    guard let value, value.isFinite, value >= 0 else { return nil }
    return min(value, RemoteUsageSnapshotValidator.maximumCostPerEvent)
}
