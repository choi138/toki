import Foundation
import TokiUsageCore

#if os(Linux)
    import CSQLite
#else
    import SQLite3
#endif

extension CodexReader {
    public func databaseRolloutPaths(from startDate: Date, to endDate: Date) -> [String] {
        Array(Set(overlappingSessionsFromDB(from: startDate, to: endDate).map(\.rolloutPath))).sorted()
    }

    func overlappingSessions(
        from startDate: Date,
        to endDate: Date,
        requiresProjectAttribution: Bool = true) -> [CodexSession] {
        guard !Task.isCancelled else { return [] }

        let databaseSessions = deduplicatedSessionsPreferringModel(
            overlappingSessionsFromDB(from: startDate, to: endDate))
        guard !Task.isCancelled else { return [] }

        let jsonlSessions = overlappingSessionsFromJSONL(
            from: startDate,
            to: endDate,
            pathsWithCompleteDatabaseAttribution: pathsWithCompleteDatabaseAttribution(
                in: databaseSessions,
                requiresProjectAttribution: requiresProjectAttribution))
        return mergedSessions(databaseSessions: databaseSessions, jsonlSessions: jsonlSessions)
    }

    func mergedSessions(
        databaseSessions: [CodexSession],
        jsonlSessions: [CodexSession]) -> [CodexSession] {
        // Prefer the in-file session_meta id over a path fingerprint. Archived/current
        // copies of one session collapse, while unrelated sessions with equal counters do not.
        var sessionsByIdentity: [String: CodexSession] = [:]
        for session in databaseSessions {
            mergeSessionPreferringModel(session, into: &sessionsByIdentity)
        }
        for session in jsonlSessions {
            mergeSessionPreferringModel(session, into: &sessionsByIdentity)
        }
        return Array(sessionsByIdentity.values)
    }

    private func deduplicatedSessionsPreferringModel(_ sessions: [CodexSession]) -> [CodexSession] {
        var sessionsByIdentity: [String: CodexSession] = [:]
        for session in sessions {
            mergeSessionPreferringModel(session, into: &sessionsByIdentity)
        }
        return Array(sessionsByIdentity.values)
    }

    private func mergeSessionPreferringModel(
        _ session: CodexSession,
        into sessionsByIdentity: inout [String: CodexSession]) {
        let identity = session.upstreamSessionID
        guard let existing = sessionsByIdentity[identity] else {
            sessionsByIdentity[identity] = session
            return
        }

        let mergedAgentKind = existing.agentKind == .subagent || session.agentKind == .subagent
            ? WorkTimeAgentKind.subagent
            : .main
        let mergedHasSourceAttribution = existing.hasSourceAttribution || session.hasSourceAttribution
        let mergedProjectPath = bestProjectPath(existing: existing, candidate: session)
        let mergedProjectQuality = bestProjectQuality(existing: existing, candidate: session)
        let preferredRolloutPath = preferredRolloutPath(existing: existing, candidate: session)

        guard normalizedModelID(existing.model) == nil,
              let model = normalizedModelID(session.model) else {
            if existing.agentKind != mergedAgentKind
                || existing.hasSourceAttribution != mergedHasSourceAttribution
                || existing.projectPath != mergedProjectPath
                || existing.projectAttributionQuality != mergedProjectQuality
                || existing.rolloutPath != preferredRolloutPath {
                sessionsByIdentity[identity] = CodexSession(
                    rolloutPath: preferredRolloutPath,
                    model: existing.model,
                    agentKind: mergedAgentKind,
                    hasSourceAttribution: mergedHasSourceAttribution,
                    projectPath: mergedProjectPath,
                    projectAttributionQuality: mergedProjectQuality,
                    upstreamSessionID: identity)
            }
            return
        }

        sessionsByIdentity[identity] = CodexSession(
            rolloutPath: preferredRolloutPath,
            model: model,
            agentKind: mergedAgentKind,
            hasSourceAttribution: mergedHasSourceAttribution,
            projectPath: mergedProjectPath,
            projectAttributionQuality: mergedProjectQuality,
            upstreamSessionID: identity)
    }

    private func preferredRolloutPath(existing: CodexSession, candidate: CodexSession) -> String {
        let keys: Set<URLResourceKey> = [.fileSizeKey, .contentModificationDateKey]
        let existingValues = try? URL(fileURLWithPath: existing.rolloutPath).resourceValues(forKeys: keys)
        let candidateValues = try? URL(fileURLWithPath: candidate.rolloutPath).resourceValues(forKeys: keys)
        let existingSize = existingValues?.fileSize ?? 0
        let candidateSize = candidateValues?.fileSize ?? 0

        if candidateSize != existingSize {
            return candidateSize > existingSize ? candidate.rolloutPath : existing.rolloutPath
        }

        let existingDate = existingValues?.contentModificationDate ?? .distantPast
        let candidateDate = candidateValues?.contentModificationDate ?? .distantPast
        return candidateDate > existingDate ? candidate.rolloutPath : existing.rolloutPath
    }

    private func bestProjectPath(existing: CodexSession, candidate: CodexSession) -> String? {
        let existingRank = codexProjectQualityRank(existing.projectAttributionQuality)
        let candidateRank = codexProjectQualityRank(candidate.projectAttributionQuality)

        if candidate.projectPath != nil, candidateRank > existingRank {
            return candidate.projectPath
        }
        return existing.projectPath ?? candidate.projectPath
    }

    private func bestProjectQuality(existing: CodexSession, candidate: CodexSession) -> AttributionQuality {
        let existingRank = codexProjectQualityRank(existing.projectAttributionQuality)
        let candidateRank = codexProjectQualityRank(candidate.projectAttributionQuality)

        if candidate.projectPath != nil, candidateRank > existingRank {
            return candidate.projectAttributionQuality
        }
        if existing.projectPath != nil {
            return existing.projectAttributionQuality
        }
        return candidate.projectPath == nil ? .unknown : candidate.projectAttributionQuality
    }

    func pathsWithCompleteDatabaseAttribution(
        in sessions: [CodexSession],
        requiresProjectAttribution: Bool = true) -> Set<String> {
        Set(sessions.compactMap { session in
            let hasRequiredProjectAttribution = !requiresProjectAttribution || session.projectPath != nil
            guard normalizedModelID(session.model) != nil,
                  session.hasSourceAttribution,
                  hasRequiredProjectAttribution else {
                return nil
            }
            return session.rolloutPath
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
        let projectPathExpression = codexSQLiteTable(database, tableName: "threads", hasColumn: "cwd")
            ? "COALESCE(cwd, '')"
            : "''"
        let query = """
            SELECT DISTINCT rollout_path, COALESCE(model, ''), COALESCE(source, ''), \(projectPathExpression)
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
            guard !Task.isCancelled else { return sessions }

            guard let rolloutPathPointer = sqlite3_column_text(statement, 0) else { continue }
            let rolloutURL = canonicalCodexRolloutURL(
                URL(fileURLWithPath: String(cString: rolloutPathPointer)))
            let rolloutPath = rolloutURL.path
            let model = codexSQLiteText(statement, at: 1).trimmedNonEmpty
            let source = codexSQLiteText(statement, at: 2).trimmedNonEmpty
            let projectPath = codexSQLiteText(statement, at: 3).trimmedNonEmpty
            sessions.append(
                CodexSession(
                    rolloutPath: rolloutPath,
                    model: model,
                    agentKind: codexAgentKind(fromSource: source),
                    hasSourceAttribution: source != nil,
                    projectPath: projectPath,
                    projectAttributionQuality: .exact,
                    upstreamSessionID: extractSessionID(from: rolloutURL)))
        }
        return sessions
    }

    private func overlappingSessionsFromJSONL(
        from startDate: Date,
        to endDate: Date,
        pathsWithCompleteDatabaseAttribution: Set<String>) -> [CodexSession] {
        let calendar = Calendar.autoupdatingCurrent
        let codexHomeURL = URL(fileURLWithPath: dbPath)
            .deletingLastPathComponent()
            .standardizedFileURL
            .resolvingSymlinksInPath()
        let startDay = calendar.startOfDay(for: startDate)
        let endDay = calendar.startOfDay(for: endDate)
        let numberOfDays = calendar.dateComponents([.day], from: startDay, to: endDay).day ?? 0
        let lookback = [-3, -2, -1]
        let activeDirectoryURLs = (lookback + (0...max(0, numberOfDays)).map { $0 })
            .compactMap { offset in
                calendar.date(byAdding: .day, value: offset, to: startDay)
            }
            .map { day -> URL in
                let components = calendar.dateComponents([.year, .month, .day], from: day)
                return codexHomeURL
                    .appendingPathComponent("sessions")
                    .appendingPathComponent(String(format: "%04d", components.year ?? 0))
                    .appendingPathComponent(String(format: "%02d", components.month ?? 0))
                    .appendingPathComponent(String(format: "%02d", components.day ?? 0))
            }
        let directoryURLs = activeDirectoryURLs + [codexHomeURL.appendingPathComponent("archived_sessions")]

        var sessions: [CodexSession] = []
        for directoryURL in directoryURLs {
            guard !Task.isCancelled else { break }
            guard FileManager.default.fileExists(atPath: directoryURL.path),
                  let contents = try? FileManager.default.contentsOfDirectory(
                      at: directoryURL,
                      includingPropertiesForKeys: [
                          .contentModificationDateKey,
                          .isRegularFileKey,
                          .isSymbolicLinkKey,
                      ],
                      options: [.skipsHiddenFiles]) else {
                continue
            }

            for fileURL in contents.sorted(by: { $0.path < $1.path }) {
                guard !Task.isCancelled else { break }
                guard let values = try? fileURL.resourceValues(forKeys: [
                    .contentModificationDateKey,
                    .isRegularFileKey,
                    .isSymbolicLinkKey,
                ]),
                    values.isRegularFile == true,
                    values.isSymbolicLink != true,
                    fileURL.pathExtension == "jsonl",
                    let modifiedDate = values.contentModificationDate,
                    modifiedDate >= startDate else {
                    continue
                }

                let rolloutURL = canonicalCodexRolloutURL(fileURL)
                guard !pathsWithCompleteDatabaseAttribution.contains(rolloutURL.path) else {
                    continue
                }

                let attribution = extractAttribution(from: rolloutURL)
                sessions.append(
                    CodexSession(
                        rolloutPath: rolloutURL.path,
                        model: attribution.model,
                        agentKind: attribution.agentKind,
                        hasSourceAttribution: attribution.hasSourceAttribution,
                        projectPath: attribution.projectPath,
                        projectAttributionQuality: attribution.projectPath == nil ? .unknown : .exact,
                        upstreamSessionID: attribution.upstreamSessionID))
            }
        }
        return sessions
    }

    private func extractAttribution(from url: URL) -> CodexSessionAttribution {
        let decoder = JSONDecoder()
        var model: String?
        var agentKind = WorkTimeAgentKind.main
        var hasSourceAttribution = false
        var projectPath: String?
        var upstreamSessionID: String?

        forEachJSONLLineUntil(at: url) { line, _ in
            guard model == nil || !hasSourceAttribution || projectPath == nil || upstreamSessionID == nil else {
                return false
            }
            guard let lineData = line.data(using: .utf8) else { return true }

            if let entry = try? decoder.decode(CodexModelEntry.self, from: lineData),
               entry.type == "turn_context" {
                if model == nil,
                   let entryModel = entry.payload?.model,
                   !entryModel.isEmpty {
                    model = entryModel
                }
                if projectPath == nil {
                    projectPath = entry.payload?.resolvedProjectPath
                }
            }

            if let entry = try? decoder.decode(CodexSessionMetaEntry.self, from: lineData),
               entry.type == "session_meta" {
                if upstreamSessionID == nil {
                    upstreamSessionID = entry.payload?.id?.trimmedNonEmpty
                }
                if !hasSourceAttribution, let source = entry.payload?.source {
                    agentKind = source.isSubagent ? .subagent : .main
                    hasSourceAttribution = true
                }
                if projectPath == nil {
                    projectPath = entry.payload?.resolvedProjectPath
                }
            }

            return model == nil || !hasSourceAttribution || projectPath == nil || upstreamSessionID == nil
        }

        return CodexSessionAttribution(
            model: model,
            agentKind: agentKind,
            hasSourceAttribution: hasSourceAttribution,
            projectPath: projectPath,
            upstreamSessionID: upstreamSessionID)
    }

    private func extractSessionID(from url: URL) -> String? {
        let decoder = JSONDecoder()
        return firstJSONLLine(at: url) { line in
            guard let lineData = line.data(using: .utf8),
                  let entry = try? decoder.decode(CodexSessionMetaEntry.self, from: lineData),
                  entry.type == "session_meta" else {
                return nil
            }
            return entry.payload?.id?.trimmedNonEmpty
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

    private func extractAgentKind(from url: URL) -> WorkTimeAgentKind {
        let decoder = JSONDecoder()
        return firstJSONLLine(at: url) { line in
            guard let lineData = line.data(using: .utf8),
                  let entry = try? decoder.decode(CodexSessionMetaEntry.self, from: lineData),
                  entry.type == "session_meta",
                  let source = entry.payload?.source else {
                return nil
            }
            return source.isSubagent ? .subagent : .main
        } ?? .main
    }

    private func firstJSONLLine<T>(at url: URL, matching transform: (String) -> T?) -> T? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }

        var pending = Data()
        while true {
            guard !Task.isCancelled else { return nil }

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
                guard !Task.isCancelled else { return nil }

                let lineData = pending.subdata(in: pending.startIndex..<newlineIndex)
                pending.removeSubrange(pending.startIndex...newlineIndex)

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

private func canonicalCodexRolloutURL(_ url: URL) -> URL {
    url.standardizedFileURL.resolvingSymlinksInPath()
}

private func codexSQLiteText(_ statement: OpaquePointer?, at index: Int32) -> String {
    sqlite3_column_text(statement, index).map { String(cString: $0) } ?? ""
}

private func codexSQLiteTable(
    _ database: OpaquePointer?,
    tableName: String,
    hasColumn columnName: String) -> Bool {
    var statement: OpaquePointer?
    guard sqlite3_prepare_v2(database, "PRAGMA table_info(\(tableName))", -1, &statement, nil) == SQLITE_OK else {
        return false
    }
    defer { sqlite3_finalize(statement) }

    while sqlite3_step(statement) == SQLITE_ROW {
        guard codexSQLiteText(statement, at: 1) == columnName else { continue }
        return true
    }

    return false
}

private func codexProjectQualityRank(_ quality: AttributionQuality) -> Int {
    switch quality {
    case .exact:
        3
    case .inferred:
        2
    case .unknown:
        1
    }
}

private extension Data {
    func trimmingCarriageReturn() -> Data {
        guard last == 0x0D else { return self }
        return Data(dropLast())
    }
}
