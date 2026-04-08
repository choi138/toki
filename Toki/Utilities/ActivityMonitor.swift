import Foundation

// Detects whether any AI coding tool is currently active
// by checking file modification times of known data sources.
enum ActivityMonitor {

    private static let activeWindowSeconds: TimeInterval = 30

    static func isAnyToolActive() -> Bool {
        let threshold = Date().addingTimeInterval(-activeWindowSeconds)
        // Cheap single-file checks first; expensive directory scan last
        return isCodexActive(since: threshold)
            || isOpenCodeActive(since: threshold)
            || isClaudeCodeActive(since: threshold)
    }

    // MARK: - Per-tool checks

    private static func isClaudeCodeActive(since threshold: Date) -> Bool {
        let projectsURL = homeDir().appendingPathComponent(".claude/projects")
        guard FileManager.default.fileExists(atPath: projectsURL.path),
              let enumerator = FileManager.default.enumerator(
                  at: projectsURL,
                  includingPropertiesForKeys: [.contentModificationDateKey],
                  options: [.skipsHiddenFiles]
              ) else { return false }

        // Early-exit: return true on first matching file (avoids full scan of 800+ files)
        for case let url as URL in enumerator {
            guard url.pathExtension == "jsonl",
                  let mod = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
            else { continue }
            if mod >= threshold { return true }
        }
        return false
    }

    private static func isCodexActive(since threshold: Date) -> Bool {
        // sqlite-shm is touched whenever Codex holds an active DB connection
        let path = homeDir().appendingPathComponent(".codex/state_5.sqlite-shm").path
        return isFileModified(at: path, since: threshold)
    }

    private static func isOpenCodeActive(since threshold: Date) -> Bool {
        let path = homeDir().appendingPathComponent(".local/share/opencode/opencode.db-wal").path
        return isFileModified(at: path, since: threshold)
    }

    // MARK: - Helpers

    private static func isFileModified(at path: String, since threshold: Date) -> Bool {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: path),
              let modDate = attrs[.modificationDate] as? Date else { return false }
        return modDate > threshold
    }
}
