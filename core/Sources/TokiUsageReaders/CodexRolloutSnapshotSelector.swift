import Foundation
import TokiUsageCore

private let codexTokenCountMarker = Array("\"token_count\"".utf8)
private let codexSessionMetaMarker = Array("\"session_meta\"".utf8)
private let codexTurnContextMarker = Array("\"turn_context\"".utf8)
private let codexTaskStartedMarker = Array("\"task_started\"".utf8)
private let codexTypeKey = Array("type".utf8)
private let codexCompactedType = Array("compacted".utf8)
private let codexResponseItemType = Array("response_item".utf8)
private let codexTokenCountMarkerData = Data(codexTokenCountMarker)
private let codexSessionMetaMarkerData = Data(codexSessionMetaMarker)
private let codexTurnContextMarkerData = Data(codexTurnContextMarker)
private let codexTaskStartedMarkerData = Data(codexTaskStartedMarker)

func codexRolloutSnapshots(fromRolloutLines lines: [String]) -> [CodexTimedSnapshot] {
    var selector = CodexRolloutSnapshotSelector()
    return lines.enumerated().compactMap { index, line in
        selector.snapshot(from: line, fileOrder: index)
    }.sorted(by: codexSnapshotOrder)
}

func codexRolloutSnapshots(fromRolloutAt url: URL) -> [CodexTimedSnapshot] {
    var selector = CodexRolloutSnapshotSelector()
    var snapshots: [CodexTimedSnapshot] = []

    forEachJSONLLine(at: url) { line, index in
        if let snapshot = selector.snapshot(from: line, fileOrder: index) {
            snapshots.append(snapshot)
        }
    }

    return snapshots.sorted(by: codexSnapshotOrder)
}

struct CodexRolloutSnapshotSelectorState: Codable {
    var waitingForForkTurnContext = false
    var inheritedForkBaseline: CodexUsageSnapshot?
    var forkChildSessionID: String?
    var replaySessionID: String?
    var taskStartedTurnIDs: Set<String> = []
    var forkChildIsUserFork = false
}

struct CodexRolloutSnapshotSelector {
    private let decoder = JSONDecoder()
    private(set) var state: CodexRolloutSnapshotSelectorState

    init(state: CodexRolloutSnapshotSelectorState = CodexRolloutSnapshotSelectorState()) {
        self.state = state
    }

    mutating func snapshot(from line: String, fileOrder: Int) -> CodexTimedSnapshot? {
        guard codexLineContainsRelevantMarker(
            line,
            includeForkMarkers: state.waitingForForkTurnContext),
            let data = line.data(using: .utf8),
            let entry = try? decoder.decode(CodexRolloutEntry.self, from: data) else {
            return nil
        }

        if state.waitingForForkTurnContext {
            if entry.type == "turn_context" {
                guard isForkChildTurn(entry.payload?.turnID) else { return nil }
                state.waitingForForkTurnContext = false
                state.replaySessionID = nil
                state.taskStartedTurnIDs.removeAll(keepingCapacity: true)
                state.forkChildIsUserFork = false
                return nil
            }

            if entry.type == "event_msg", entry.payload?.type == "task_started",
               let turnID = entry.payload?.turnID?.trimmedNonEmpty {
                state.taskStartedTurnIDs.insert(turnID)
                return nil
            }

            if entry.type == "session_meta" {
                if let sessionID = entry.payload?.id?.trimmedNonEmpty,
                   sessionID != state.forkChildSessionID {
                    state.replaySessionID = sessionID
                }
                return nil
            }
        }

        if entry.type == "session_meta", entry.payload?.forkParentID != nil {
            let childSessionID = entry.payload?.id?.trimmedNonEmpty
            let repeatedActiveChildMetadata = childSessionID != nil
                && state.forkChildSessionID == childSessionID
            state.forkChildSessionID = childSessionID
            if !repeatedActiveChildMetadata {
                state.waitingForForkTurnContext = true
                state.inheritedForkBaseline = nil
                state.replaySessionID = nil
                state.taskStartedTurnIDs.removeAll(keepingCapacity: true)
                state.forkChildIsUserFork = entry.payload?.threadSource == "user"
            }
            return nil
        }

        guard let tokenCount = entry.tokenCount,
              let timestamp = entry.timestamp,
              let date = codexParseTimestamp(timestamp) else {
            return nil
        }

        if state.waitingForForkTurnContext {
            state.inheritedForkBaseline = tokenCount.totalSnapshot
            return nil
        }

        if let baseline = state.inheritedForkBaseline {
            // Fork logs replay parent snapshots with child-local timestamps. Keep
            // suppressing them until both reported totals and component counters advance.
            guard !tokenCount.totalSnapshot.isInheritedReplay(of: baseline) else { return nil }
            state.inheritedForkBaseline = nil
        }

        return CodexTimedSnapshot(date: date, tokenCount: tokenCount, fileOrder: fileOrder)
    }

    private func isForkChildTurn(_ turnID: String?) -> Bool {
        guard state.replaySessionID != nil else { return true }
        guard let turnID = turnID?.trimmedNonEmpty else { return true }
        guard let childID = state.forkChildSessionID,
              let turnKey = codexUUIDv7OrderKey(turnID),
              let childKey = codexUUIDv7OrderKey(childID) else {
            return true
        }
        let turnTimestamp = turnKey.prefix(12)
        let childTimestamp = childKey.prefix(12)
        if turnTimestamp > childTimestamp { return true }
        if turnTimestamp < childTimestamp { return false }
        return state.forkChildIsUserFork || state.taskStartedTurnIDs.contains(turnID)
    }
}

func codexParseTimestamp(_ timestamp: String) -> Date? {
    let fastDate = timestamp.utf8.withContiguousStorageIfAvailable { buffer in
        codexParseRFC3339Timestamp(buffer)
    } ?? Array(timestamp.utf8).withUnsafeBufferPointer { buffer in
        codexParseRFC3339Timestamp(buffer)
    }
    return fastDate ?? DateParser.parse(timestamp)
}

private func codexParseRFC3339Timestamp(_ bytes: UnsafeBufferPointer<UInt8>) -> Date? {
    guard bytes.count >= 20,
          bytes[4] == 0x2D, bytes[7] == 0x2D,
          bytes[10] == 0x54, bytes[13] == 0x3A, bytes[16] == 0x3A,
          let year = codexDecimal(bytes, at: 0, count: 4),
          let month = codexDecimal(bytes, at: 5, count: 2),
          let day = codexDecimal(bytes, at: 8, count: 2),
          let hour = codexDecimal(bytes, at: 11, count: 2),
          let minute = codexDecimal(bytes, at: 14, count: 2),
          let second = codexDecimal(bytes, at: 17, count: 2),
          (1...12).contains(month),
          (1...codexDaysInMonth(month, year: year)).contains(day),
          (0...23).contains(hour),
          (0...59).contains(minute),
          (0...59).contains(second) else {
        return nil
    }

    var offset = 19
    var fractionalSeconds = 0.0
    if offset < bytes.count, bytes[offset] == 0x2E {
        offset += 1
        let fractionStart = offset
        var scale = 0.1
        while offset < bytes.count, bytes[offset] >= 0x30, bytes[offset] <= 0x39 {
            fractionalSeconds += Double(bytes[offset] - 0x30) * scale
            scale *= 0.1
            offset += 1
        }
        guard offset > fractionStart else { return nil }
    }

    let timeZoneOffset: Int
    if offset < bytes.count, bytes[offset] == 0x5A, offset + 1 == bytes.count {
        timeZoneOffset = 0
    } else if offset + 6 == bytes.count,
              bytes[offset] == 0x2B || bytes[offset] == 0x2D,
              bytes[offset + 3] == 0x3A,
              let offsetHour = codexDecimal(bytes, at: offset + 1, count: 2),
              let offsetMinute = codexDecimal(bytes, at: offset + 4, count: 2),
              (0...23).contains(offsetHour),
              (0...59).contains(offsetMinute) {
        let magnitude = offsetHour * 3600 + offsetMinute * 60
        timeZoneOffset = bytes[offset] == 0x2B ? magnitude : -magnitude
    } else {
        return nil
    }

    let secondsSinceEpoch = codexDaysSinceUnixEpoch(year: year, month: month, day: day) * 86400
        + hour * 3600 + minute * 60 + second - timeZoneOffset
    return Date(timeIntervalSince1970: Double(secondsSinceEpoch) + fractionalSeconds)
}

private func codexDecimal(
    _ bytes: UnsafeBufferPointer<UInt8>,
    at start: Int,
    count: Int) -> Int? {
    guard start >= 0, count > 0, start + count <= bytes.count else { return nil }
    var value = 0
    var offset = start
    while offset < start + count {
        let byte = bytes[offset]
        guard byte >= 0x30, byte <= 0x39 else { return nil }
        value = value * 10 + Int(byte - 0x30)
        offset += 1
    }
    return value
}

private func codexDaysInMonth(_ month: Int, year: Int) -> Int {
    switch month {
    case 2:
        year.isMultiple(of: 400) || (year.isMultiple(of: 4) && !year.isMultiple(of: 100)) ? 29 : 28
    case 4, 6, 9, 11:
        30
    default:
        31
    }
}

private func codexDaysSinceUnixEpoch(year: Int, month: Int, day: Int) -> Int {
    let adjustedYear = year - (month <= 2 ? 1 : 0)
    let era = (adjustedYear >= 0 ? adjustedYear : adjustedYear - 399) / 400
    let yearOfEra = adjustedYear - era * 400
    let adjustedMonth = month + (month > 2 ? -3 : 9)
    let dayOfYear = (153 * adjustedMonth + 2) / 5 + day - 1
    let dayOfEra = yearOfEra * 365 + yearOfEra / 4 - yearOfEra / 100 + dayOfYear
    return era * 146_097 + dayOfEra - 719_468
}

private func codexLineContainsRelevantMarker(
    _ line: String,
    includeForkMarkers: Bool) -> Bool {
    if let result = line.utf8.withContiguousStorageIfAvailable({ buffer in
        codexBufferContainsRelevantMarker(buffer, includeForkMarkers: includeForkMarkers)
    }) {
        return result
    }

    return Array(line.utf8).withUnsafeBufferPointer { buffer in
        codexBufferContainsRelevantMarker(buffer, includeForkMarkers: includeForkMarkers)
    }
}

func codexDataContainsRelevantMarker(
    _ data: Data,
    includeForkMarkers: Bool) -> Bool {
    if data.range(of: codexTokenCountMarkerData) != nil
        || data.range(of: codexSessionMetaMarkerData) != nil {
        return true
    }
    return includeForkMarkers
        && (data.range(of: codexTurnContextMarkerData) != nil
            || data.range(of: codexTaskStartedMarkerData) != nil)
}

func codexDataShouldProcessRolloutLine(
    _ data: Data,
    includeForkMarkers: Bool) -> Bool {
    !codexDataIsCompactedRolloutEntry(data)
        && codexDataContainsRelevantMarker(data, includeForkMarkers: includeForkMarkers)
}

func codexDataShouldKeepOversizedRolloutLine(_ data: Data) -> Bool {
    !codexDataHasTopLevelType(data, matching: codexCompactedType)
        && !codexDataHasTopLevelType(data, matching: codexResponseItemType)
}

func codexDataIsCompactedRolloutEntry(_ data: Data) -> Bool {
    codexDataHasTopLevelType(data, matching: codexCompactedType)
}

private func codexDataHasTopLevelType(_ data: Data, matching expectedType: [UInt8]) -> Bool {
    data.withUnsafeBytes { rawBuffer in
        let buffer = rawBuffer.bindMemory(to: UInt8.self)
        var offset = 0
        var depth = 0
        var expectingTopLevelKey = false

        while offset < buffer.count {
            switch buffer[offset] {
            case 0x7B: // {
                depth += 1
                if depth == 1 { expectingTopLevelKey = true }
                offset += 1
            case 0x7D: // }
                depth -= 1
                offset += 1
            case 0x2C where depth == 1: // ,
                expectingTopLevelKey = true
                offset += 1
            case 0x22: // "
                guard let stringEnd = codexJSONStringEnd(in: buffer, startingAt: offset) else {
                    return false
                }
                guard depth == 1, expectingTopLevelKey else {
                    offset = stringEnd + 1
                    continue
                }

                let keyStart = offset + 1
                let isTypeKey = codexBuffer(
                    buffer,
                    exactlyMatches: codexTypeKey,
                    from: keyStart,
                    to: stringEnd)
                expectingTopLevelKey = false
                offset = stringEnd + 1
                while offset < buffer.count, codexIsJSONWhitespace(buffer[offset]) {
                    offset += 1
                }
                guard offset < buffer.count, buffer[offset] == 0x3A else { continue }
                offset += 1
                guard isTypeKey else { continue }
                while offset < buffer.count, codexIsJSONWhitespace(buffer[offset]) {
                    offset += 1
                }
                guard offset < buffer.count, buffer[offset] == 0x22,
                      let valueEnd = codexJSONStringEnd(in: buffer, startingAt: offset) else {
                    return false
                }
                return codexBuffer(
                    buffer,
                    exactlyMatches: expectedType,
                    from: offset + 1,
                    to: valueEnd)
            default:
                offset += 1
            }
        }

        return false
    }
}

private func codexJSONStringEnd(
    in buffer: UnsafeBufferPointer<UInt8>,
    startingAt openingQuote: Int) -> Int? {
    var offset = openingQuote + 1
    var isEscaped = false
    while offset < buffer.count {
        let byte = buffer[offset]
        if byte == 0x22, !isEscaped { return offset }
        if byte == 0x5C {
            isEscaped.toggle()
        } else {
            isEscaped = false
        }
        offset += 1
    }
    return nil
}

private func codexIsJSONWhitespace(_ byte: UInt8) -> Bool {
    byte == 0x20 || byte == 0x09 || byte == 0x0A || byte == 0x0D
}

private func codexBuffer(
    _ buffer: UnsafeBufferPointer<UInt8>,
    exactlyMatches value: [UInt8],
    from start: Int,
    to end: Int) -> Bool {
    guard end - start == value.count else { return false }
    var offset = 0
    while offset < value.count {
        if buffer[start + offset] != value[offset] { return false }
        offset += 1
    }
    return true
}

private func codexBufferContainsRelevantMarker(
    _ buffer: UnsafeBufferPointer<UInt8>,
    includeForkMarkers: Bool) -> Bool {
    var offset = 0
    while offset < buffer.count {
        if buffer[offset] == 0x22 {
            if codexBuffer(buffer, matches: codexTokenCountMarker, at: offset)
                || codexBuffer(buffer, matches: codexSessionMetaMarker, at: offset) {
                return true
            }

            if includeForkMarkers,
               codexBuffer(buffer, matches: codexTurnContextMarker, at: offset)
               || codexBuffer(buffer, matches: codexTaskStartedMarker, at: offset) {
                return true
            }
        }
        offset += 1
    }

    return false
}

private func codexBuffer(
    _ buffer: UnsafeBufferPointer<UInt8>,
    matches marker: [UInt8],
    at offset: Int) -> Bool {
    guard offset <= buffer.count - marker.count else { return false }

    var markerOffset = 0
    while markerOffset < marker.count {
        if buffer[offset + markerOffset] != marker[markerOffset] {
            return false
        }
        markerOffset += 1
    }

    return true
}
