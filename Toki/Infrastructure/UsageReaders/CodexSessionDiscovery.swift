import Foundation
import SQLite3

extension CodexReader {
    func overlappingSessions(from startDate: Date, to endDate: Date) -> [CodexSession] {
        let databaseSessions = deduplicatedSessionsPreferringModel(
            overlappingSessionsFromDB(from: startDate, to: endDate))
        let jsonlSessions = overlappingSessionsFromJSONL(
            from: startDate,
            to: endDate,
            pathsWithDatabaseModel: pathsWithValidModel(in: databaseSessions))
        return mergedSessions(databaseSessions: databaseSessions, jsonlSessions: jsonlSessions)
    }

    func mergedSessions(
        databaseSessions: [CodexSession],
        jsonlSessions: [CodexSession]) -> [CodexSession] {
        var sessionsByPath: [String: CodexSession] = [:]
        for session in databaseSessions {
            mergeSessionPreferringModel(session, into: &sessionsByPath)
        }
        for session in jsonlSessions {
            mergeSessionPreferringModel(session, into: &sessionsByPath)
        }
        return Array(sessionsByPath.values)
    }

    private func deduplicatedSessionsPreferringModel(_ sessions: [CodexSession]) -> [CodexSession] {
        var sessionsByPath: [String: CodexSession] = [:]
        for session in sessions {
            mergeSessionPreferringModel(session, into: &sessionsByPath)
        }
        return Array(sessionsByPath.values)
    }

    private func mergeSessionPreferringModel(
        _ session: CodexSession,
        into sessionsByPath: inout [String: CodexSession]) {
        guard let existing = sessionsByPath[session.rolloutPath] else {
            sessionsByPath[session.rolloutPath] = session
            return
        }

        guard normalizedModelID(existing.model) == nil,
              let model = normalizedModelID(session.model) else {
            return
        }

        sessionsByPath[session.rolloutPath] = CodexSession(
            rolloutPath: existing.rolloutPath,
            model: model)
    }

    private func pathsWithValidModel(in sessions: [CodexSession]) -> Set<String> {
        Set(sessions.compactMap { session in
            normalizedModelID(session.model) == nil ? nil : session.rolloutPath
        })
    }

    private func overlappingSessionsFromDB(from startDate: Date, to endDate: Date) -> [CodexSession] {
        var database: OpaquePointer?
        defer { sqlite3_close(database) }
        guard sqlite3_open_v2(dbPath, &database, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
            return []
        }
        sqlite3_busy_timeout(database, 2000)

        let startEpoch = startDate.timeIntervalSince1970
        let endEpoch = endDate.timeIntervalSince1970
        let query = """
            SELECT DISTINCT rollout_path, COALESCE(model, '')
            FROM threads
            WHERE updated_at >= ? AND created_at < ?
        """

        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, query, -1, &statement, nil) == SQLITE_OK else {
            return []
        }
        defer { sqlite3_finalize(statement) }

        sqlite3_bind_int64(statement, 1, Int64(startEpoch))
        sqlite3_bind_int64(statement, 2, Int64(endEpoch))

        var sessions: [CodexSession] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let rolloutPathPointer = sqlite3_column_text(statement, 0) else { continue }
            let rolloutPath = String(cString: rolloutPathPointer)
            let rawModel = sqlite3_column_text(statement, 1).map { String(cString: $0) } ?? ""
            let model = rawModel.isEmpty ? nil : rawModel
            sessions.append(CodexSession(rolloutPath: rolloutPath, model: model))
        }
        return sessions
    }

    private func overlappingSessionsFromJSONL(
        from startDate: Date,
        to endDate: Date,
        pathsWithDatabaseModel: Set<String>) -> [CodexSession] {
        let calendar = Calendar.autoupdatingCurrent
        let startDay = calendar.startOfDay(for: startDate)
        let endDay = calendar.startOfDay(for: endDate)
        let numberOfDays = calendar.dateComponents([.day], from: startDay, to: endDay).day ?? 0
        let lookback = [-3, -2, -1]
        let directoryURLs = (lookback + (0...max(0, numberOfDays)).map { $0 })
            .compactMap { offset in
                calendar.date(byAdding: .day, value: offset, to: startDay)
            }
            .map { day -> URL in
                let components = calendar.dateComponents([.year, .month, .day], from: day)
                return homeDir()
                    .appendingPathComponent(".codex/sessions")
                    .appendingPathComponent(String(format: "%04d", components.year ?? 0))
                    .appendingPathComponent(String(format: "%02d", components.month ?? 0))
                    .appendingPathComponent(String(format: "%02d", components.day ?? 0))
            }

        return directoryURLs.flatMap { directoryURL -> [CodexSession] in
            guard FileManager.default.fileExists(atPath: directoryURL.path),
                  let contents = try? FileManager.default.contentsOfDirectory(
                      at: directoryURL,
                      includingPropertiesForKeys: [.contentModificationDateKey],
                      options: [.skipsHiddenFiles]) else {
                return []
            }

            return contents.compactMap { fileURL -> CodexSession? in
                guard fileURL.pathExtension == "jsonl",
                      let modifiedDate = (try? fileURL.resourceValues(forKeys: [.contentModificationDateKey]))?
                      .contentModificationDate,
                      modifiedDate >= startDate else {
                    return nil
                }

                guard !pathsWithDatabaseModel.contains(fileURL.path) else {
                    return nil
                }

                return CodexSession(rolloutPath: fileURL.path, model: extractModel(from: fileURL))
            }
        }
    }

    private func extractModel(from url: URL) -> String? {
        let decoder = JSONDecoder()
        return firstJSONLLine(at: url) { line in
            guard let lineData = line.data(using: .utf8),
                  let entry = try? decoder.decode(CodexModelEntry.self, from: lineData),
                  entry.type == "turn_context",
                  let model = entry.payload?.model,
                  !model.isEmpty else {
                return nil
            }
            return model
        }
    }

    private func firstJSONLLine<T>(at url: URL, matching transform: (String) -> T?) -> T? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }

        var pending = Data()
        while true {
            let chunk = handle.readData(ofLength: 64 * 1024)
            if chunk.isEmpty { break }

            pending.append(chunk)
            while let newlineRange = pending.firstRange(of: Data([0x0A])) {
                let lineData = pending.subdata(in: pending.startIndex..<newlineRange.lowerBound)
                pending.removeSubrange(pending.startIndex..<newlineRange.upperBound)

                if let result = transformLineData(lineData, using: transform) {
                    return result
                }
            }
        }

        return transformLineData(pending, using: transform)
    }

    private func transformLineData<T>(_ data: Data, using transform: (String) -> T?) -> T? {
        let trimmedData = data.trimmingCarriageReturn()
        guard !trimmedData.isEmpty,
              let line = String(data: trimmedData, encoding: .utf8) else {
            return nil
        }
        return transform(line.trimmingCharacters(in: .whitespaces))
    }
}

private extension Data {
    func trimmingCarriageReturn() -> Data {
        guard last == 0x0D else { return self }
        return Data(dropLast())
    }
}
