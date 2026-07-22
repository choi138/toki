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
    forEachJSONLLineUntil(at: url) { line, index in
        body(line, index)
        return true
    }
}

func forEachJSONLLineUntil(at url: URL, _ body: (String, Int) -> Bool) {
    guard let handle = try? FileHandle(forReadingFrom: url) else { return }
    defer { try? handle.close() }

    var lineIndex = 0
    var pending = Data()

    while true {
        guard !Task.isCancelled else { return }

        let chunk: Data
        do {
            guard let data = try handle.read(upToCount: 64 * 1024),
                  !data.isEmpty else {
                break
            }
            chunk = data
        } catch {
            break
        }

        pending.append(chunk)
        while let newlineIndex = pending.firstIndex(of: 0x0A) {
            guard !Task.isCancelled else { return }

            let lineData = pending.subdata(in: pending.startIndex..<newlineIndex)
            pending.removeSubrange(pending.startIndex...newlineIndex)
            if let line = jsonlLineString(from: lineData) {
                guard body(line, lineIndex) else { return }
                lineIndex += 1
            }
        }
    }

    if let line = jsonlLineString(from: pending) {
        _ = body(line, lineIndex)
    }
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
