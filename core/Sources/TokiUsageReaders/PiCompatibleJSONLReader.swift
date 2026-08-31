import Foundation
import TokiSyncProtocol

struct PiCompatibleReadLimits: Equatable {
    static let `default` = PiCompatibleReadLimits(
        maximumFileCount: 50000,
        maximumFileBytes: 256 * 1024 * 1024,
        maximumLineBytes: 4 * 1024 * 1024,
        maximumEventCount: RemoteUsageSnapshotValidator.maximumTokenEventCount)

    let maximumFileCount: Int
    let maximumFileBytes: Int
    let maximumLineBytes: Int
    let maximumEventCount: Int

    var maximumUnreconciledEventCount: Int {
        maximumEventCount > Int.max / 2 ? Int.max : maximumEventCount * 2
    }
}

enum PiCompatibleReaderError: LocalizedError, Equatable {
    case tooManyFiles(Int)
    case fileTooLarge(URL)
    case lineTooLong(URL)
    case invalidUTF8(URL, line: Int)
    case unreadableFile(URL)
    case tooManyEvents(Int)

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
        }
    }
}

func forEachBoundedJSONLLine(
    at url: URL,
    limits: PiCompatibleReadLimits,
    _ body: (String, Int) throws -> Void) throws {
    let attributes: [FileAttributeKey: Any]
    do {
        attributes = try FileManager.default.attributesOfItem(atPath: url.path)
    } catch {
        throw PiCompatibleReaderError.unreadableFile(url)
    }
    let fileSize = (attributes[.size] as? NSNumber)?.intValue ?? 0
    guard fileSize <= limits.maximumFileBytes else {
        throw PiCompatibleReaderError.fileTooLarge(url)
    }

    let handle: FileHandle
    do {
        handle = try FileHandle(forReadingFrom: url)
    } catch {
        throw PiCompatibleReaderError.unreadableFile(url)
    }
    defer { try? handle.close() }

    var lineIndex = 0
    var pending = Data()

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

        pending.append(chunk)
        while let newlineIndex = pending.firstIndex(of: 0x0A) {
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
