import Foundation
import SQLite3

extension CodexReader {
    func overlappingSessions(from startDate: Date, to endDate: Date) -> [CodexSession] {
        let databaseSessions = overlappingSessionsFromDB(from: startDate, to: endDate)
        let jsonlSessions = overlappingSessionsFromJSONL(from: startDate, to: endDate)
        return mergedSessions(databaseSessions: databaseSessions, jsonlSessions: jsonlSessions)
    }

    func mergedSessions(
        databaseSessions: [CodexSession],
        jsonlSessions: [CodexSession]) -> [CodexSession] {
        var sessionsByPath: [String: CodexSession] = [:]
        for session in databaseSessions {
            sessionsByPath[session.rolloutPath] = session
        }
        for session in jsonlSessions {
            if let existing = sessionsByPath[session.rolloutPath] {
                if normalizedModelID(existing.model) == nil,
                   let model = normalizedModelID(session.model) {
                    sessionsByPath[session.rolloutPath] = CodexSession(
                        rolloutPath: existing.rolloutPath,
                        model: model)
                }
            } else {
                sessionsByPath[session.rolloutPath] = session
            }
        }
        return Array(sessionsByPath.values)
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

    private func overlappingSessionsFromJSONL(from startDate: Date, to endDate: Date) -> [CodexSession] {
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

                return CodexSession(rolloutPath: fileURL.path, model: extractModel(from: fileURL))
            }
        }
    }

    private func extractModel(from url: URL) -> String? {
        let decoder = JSONDecoder()

        return readJSONLLines(at: url).compactMap { line -> String? in
            guard let lineData = line.data(using: .utf8),
                  let entry = try? decoder.decode(CodexModelEntry.self, from: lineData),
                  entry.type == "turn_context",
                  let model = entry.payload?.model,
                  !model.isEmpty else {
                return nil
            }
            return model
        }.first
    }
}
