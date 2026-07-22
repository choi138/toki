import Foundation
import TokiUsageCore

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

private struct CodexRolloutSnapshotSelector {
    private let decoder = JSONDecoder()
    private var waitingForForkTurnContext = false
    private var inheritedForkBaseline: CodexUsageSnapshot?
    private var forkChildSessionID: String?
    private var replaySessionID: String?
    private var taskStartedTurnIDs: Set<String> = []
    private var forkChildIsUserFork = false

    mutating func snapshot(from line: String, fileOrder: Int) -> CodexTimedSnapshot? {
        guard let data = line.data(using: .utf8),
              let entry = try? decoder.decode(CodexRolloutEntry.self, from: data) else {
            return nil
        }

        if waitingForForkTurnContext {
            if entry.type == "turn_context" {
                guard isForkChildTurn(entry.payload?.turnID) else { return nil }
                waitingForForkTurnContext = false
                replaySessionID = nil
                taskStartedTurnIDs.removeAll(keepingCapacity: true)
                forkChildIsUserFork = false
                return nil
            }

            if entry.type == "event_msg", entry.payload?.type == "task_started",
               let turnID = entry.payload?.turnID?.trimmedNonEmpty {
                taskStartedTurnIDs.insert(turnID)
                return nil
            }

            if entry.type == "session_meta" {
                if let sessionID = entry.payload?.id?.trimmedNonEmpty,
                   sessionID != forkChildSessionID {
                    replaySessionID = sessionID
                }
                return nil
            }
        }

        if entry.type == "session_meta", entry.payload?.forkParentID != nil {
            let childSessionID = entry.payload?.id?.trimmedNonEmpty
            let repeatedActiveChildMetadata = childSessionID != nil
                && forkChildSessionID == childSessionID
            forkChildSessionID = childSessionID
            if !repeatedActiveChildMetadata {
                waitingForForkTurnContext = true
                inheritedForkBaseline = nil
                replaySessionID = nil
                taskStartedTurnIDs.removeAll(keepingCapacity: true)
                forkChildIsUserFork = entry.payload?.threadSource == "user"
            }
            return nil
        }

        guard let timestamp = entry.timestamp,
              let date = DateParser.parse(timestamp),
              let tokenCount = entry.tokenCount else {
            return nil
        }

        if waitingForForkTurnContext {
            inheritedForkBaseline = tokenCount.totalSnapshot
            return nil
        }

        if let baseline = inheritedForkBaseline {
            // Fork logs replay parent snapshots with child-local timestamps. Keep
            // suppressing them until both reported totals and component counters advance.
            guard !tokenCount.totalSnapshot.isInheritedReplay(of: baseline) else { return nil }
            inheritedForkBaseline = nil
        }

        return CodexTimedSnapshot(date: date, tokenCount: tokenCount, fileOrder: fileOrder)
    }

    private func isForkChildTurn(_ turnID: String?) -> Bool {
        guard replaySessionID != nil else { return true }
        guard let turnID = turnID?.trimmedNonEmpty else { return true }
        guard let childID = forkChildSessionID,
              let turnKey = codexUUIDv7OrderKey(turnID),
              let childKey = codexUUIDv7OrderKey(childID) else {
            return true
        }
        let turnTimestamp = turnKey.prefix(12)
        let childTimestamp = childKey.prefix(12)
        if turnTimestamp > childTimestamp { return true }
        if turnTimestamp < childTimestamp { return false }
        return forkChildIsUserFork || taskStartedTurnIDs.contains(turnID)
    }
}
