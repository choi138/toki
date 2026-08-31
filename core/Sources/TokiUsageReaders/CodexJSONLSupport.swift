import Foundation

func codexUUIDv7OrderKey(_ id: String) -> String? {
    let parts = id.split(separator: "-", omittingEmptySubsequences: false)
    guard parts.count == 5,
          parts[0].count == 8,
          parts[1].count == 4,
          parts[2].count == 4,
          parts[3].count == 4,
          parts[4].count == 12,
          parts[2].first == "7",
          parts.allSatisfy({ part in
              part.unicodeScalars.allSatisfy { scalar in
                  switch scalar.value {
                  case 48...57, 65...70, 97...102:
                      true
                  default:
                      false
                  }
              }
          }) else {
        return nil
    }
    return parts.joined().lowercased()
}

func codexSnapshotOrder(_ lhs: CodexTimedSnapshot, _ rhs: CodexTimedSnapshot) -> Bool {
    if lhs.date == rhs.date {
        return lhs.fileOrder < rhs.fileOrder
    }
    return lhs.date < rhs.date
}

func forEachJSONLLine(at url: URL, _ body: (String, Int) -> Void) {
    try? forEachJSONLLineThrowing(at: url, body)
}

func forEachJSONLLineThrowing(
    at url: URL,
    limits: PiCompatibleReadLimits? = nil,
    _ body: (String, Int) throws -> Void) throws {
    try forEachJSONLLineUntilThrowing(at: url, limits: limits) { line, index in
        try body(line, index)
        return true
    }
}

func forEachJSONLLineUntil(at url: URL, _ body: (String, Int) -> Bool) {
    try? forEachJSONLLineUntilThrowing(at: url, body)
}

func forEachJSONLLineUntilThrowing(
    at url: URL,
    limits: PiCompatibleReadLimits? = nil,
    _ body: (String, Int) throws -> Bool) throws {
    try Task.checkCancellation()
    let handle = try FileHandle(forReadingFrom: url)
    defer { try? handle.close() }
    if let limits {
        let fileSize = try handle.seekToEnd()
        guard fileSize <= UInt64(limits.maximumFileBytes) else {
            throw PiCompatibleReaderError.fileTooLarge(url)
        }
        try handle.seek(toOffset: 0)
    }

    var lineIndex = 0
    var pending = Data()
    var consumedBytes = 0
    var newlineSearchOffset = 0

    while true {
        try Task.checkCancellation()
        guard let chunk = try handle.read(upToCount: 64 * 1024),
              !chunk.isEmpty else {
            break
        }

        if let limits {
            let (nextConsumedBytes, overflow) = consumedBytes.addingReportingOverflow(chunk.count)
            guard !overflow, nextConsumedBytes <= limits.maximumFileBytes else {
                throw PiCompatibleReaderError.fileTooLarge(url)
            }
            consumedBytes = nextConsumedBytes
        }

        pending.append(chunk)
        var lineStartIndex = pending.startIndex
        var newlineSearchIndex = pending.index(pending.startIndex, offsetBy: newlineSearchOffset)
        while let newlineIndex = pending[newlineSearchIndex...].firstIndex(of: 0x0A) {
            try Task.checkCancellation()
            if let maximumLineBytes = limits?.maximumLineBytes,
               pending.distance(from: lineStartIndex, to: newlineIndex) > maximumLineBytes {
                throw PiCompatibleReaderError.lineTooLong(url)
            }

            let lineData = pending.subdata(in: lineStartIndex..<newlineIndex)
            lineStartIndex = pending.index(after: newlineIndex)
            newlineSearchIndex = lineStartIndex
            if let line = jsonlLineString(from: lineData) {
                guard try body(line, lineIndex) else { return }
                lineIndex += 1
            }
        }
        if lineStartIndex > pending.startIndex {
            pending.removeSubrange(pending.startIndex..<lineStartIndex)
        }
        newlineSearchOffset = pending.count
        if let maximumLineBytes = limits?.maximumLineBytes,
           pending.count > maximumLineBytes {
            throw PiCompatibleReaderError.lineTooLong(url)
        }
    }

    try Task.checkCancellation()
    if let limits {
        guard try handle.seekToEnd() <= UInt64(limits.maximumFileBytes) else {
            throw PiCompatibleReaderError.fileTooLarge(url)
        }
    }
    if let line = jsonlLineString(from: pending) {
        _ = try body(line, lineIndex)
    }
}

@discardableResult
// The branches model one streaming state machine and keep oversized lines from being buffered.
// swiftlint:disable:next cyclomatic_complexity
func forEachJSONLLineUntil(
    at url: URL,
    startingAt byteOffset: UInt64,
    endingAt endByteOffset: UInt64?,
    initialLineIndex: Int,
    maximumBufferedLineByteCount: Int? = nil,
    shouldKeepOversizedLine: ((Data) -> Bool)? = nil,
    shouldProcessLineData: ((Data) -> Bool)? = nil,
    _ body: (String, Int) -> Bool) -> Bool {
    guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
    defer { try? handle.close() }

    do {
        try handle.seek(toOffset: byteOffset)
    } catch {
        return false
    }

    var lineIndex = initialLineIndex
    var pending = Data()
    var newlineSearchOffset = 0
    var isDiscardingOversizedLine = false

    while true {
        guard !Task.isCancelled else { return false }

        var chunk: Data
        do {
            let maximumReadCount = endByteOffset.map {
                min(64 * 1024, Int(max(0, $0 - handle.offsetInFile)))
            } ?? 64 * 1024
            guard maximumReadCount > 0,
                  let data = try handle.read(upToCount: maximumReadCount),
                  !data.isEmpty else {
                break
            }
            chunk = data
        } catch {
            return false
        }

        if isDiscardingOversizedLine {
            guard let newlineIndex = chunk.firstIndex(of: 0x0A) else { continue }
            guard body("", lineIndex) else { return false }
            lineIndex += 1
            let remainingStartIndex = chunk.index(after: newlineIndex)
            chunk = chunk.subdata(in: remainingStartIndex..<chunk.endIndex)
            isDiscardingOversizedLine = false
            guard !chunk.isEmpty else { continue }
        }

        pending.append(chunk)
        var lineStartIndex = pending.startIndex
        var newlineSearchIndex = pending.index(pending.startIndex, offsetBy: newlineSearchOffset)
        while let newlineIndex = pending[newlineSearchIndex...].firstIndex(of: 0x0A) {
            guard !Task.isCancelled else { return false }

            let lineData = pending.subdata(in: lineStartIndex..<newlineIndex)
            lineStartIndex = pending.index(after: newlineIndex)
            newlineSearchIndex = lineStartIndex
            if shouldProcessLineData?(lineData) == false {
                guard body("", lineIndex) else { return false }
                lineIndex += 1
                continue
            }
            if let line = jsonlLineString(from: lineData) {
                guard body(line, lineIndex) else { return false }
                lineIndex += 1
            }
        }
        if lineStartIndex > pending.startIndex {
            pending.removeSubrange(pending.startIndex..<lineStartIndex)
        }
        newlineSearchOffset = pending.count
        if let maximumBufferedLineByteCount,
           pending.count > maximumBufferedLineByteCount,
           shouldKeepOversizedLine?(pending) == false {
            pending.removeAll(keepingCapacity: false)
            newlineSearchOffset = 0
            isDiscardingOversizedLine = true
        }
    }

    if isDiscardingOversizedLine {
        guard body("", lineIndex) else { return false }
    }
    if !pending.isEmpty, shouldProcessLineData?(pending) == false {
        guard body("", lineIndex) else { return false }
    } else if let line = jsonlLineString(from: pending) {
        guard body(line, lineIndex) else { return false }
    }
    return endByteOffset.map { handle.offsetInFile >= $0 } ?? true
}

func codexIsWholeDayAlignedRange(from startDate: Date, to endDate: Date) -> Bool {
    let calendar = Calendar.current
    return startDate == calendar.startOfDay(for: startDate)
        && endDate == calendar.startOfDay(for: endDate)
        && startDate < endDate
}

private func jsonlLineString(from data: Data) -> String? {
    let trimmedData = data.trimmingCarriageReturn()
    guard !trimmedData.isEmpty,
          let line = String(data: trimmedData, encoding: .utf8) else {
        return nil
    }

    let trimmedLine = line.trimmingCharacters(in: .whitespaces)
    return trimmedLine.isEmpty ? nil : trimmedLine
}

private extension Data {
    func trimmingCarriageReturn() -> Data {
        guard last == 0x0D else { return self }
        return Data(dropLast())
    }
}
