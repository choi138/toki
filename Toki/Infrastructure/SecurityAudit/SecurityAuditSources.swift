import Foundation
import TokiUsageCore
import TokiUsageReaders

extension SecurityAuditScanner {
    static func defaultSources(
        homeDirectory: URL = homeDir(),
        environment: [String: String] = ProcessInfo.processInfo.environment) -> [SecurityAuditFileSource] {
        let paths = LocalUsageReaderPaths(homeDirectory: homeDirectory, environment: environment)
        return [
            SecurityAuditFileSource(
                name: "Claude Code",
                rootURL: paths.claudeProjects,
                allowedExtensions: ["jsonl"]),
            SecurityAuditFileSource(
                name: "Codex",
                rootURL: paths.codexSessions,
                allowedExtensions: ["jsonl"]),
            SecurityAuditFileSource(
                name: "Cursor",
                rootURL: paths.cursorDatabase.deletingLastPathComponent(),
                allowedExtensions: ["vscdb"],
                sqliteTextQueries: [
                    "SELECT value FROM cursorDiskKV WHERE value IS NOT NULL",
                ]),
            SecurityAuditFileSource(
                name: "Gemini CLI",
                rootURL: paths.geminiChats,
                allowedExtensions: ["json"]),
            SecurityAuditFileSource(
                name: "OpenCode",
                rootURL: paths.openCodeDatabase.deletingLastPathComponent(),
                allowedExtensions: ["db"],
                sqliteTextQueries: [
                    "SELECT data FROM message WHERE data IS NOT NULL",
                ]),
            SecurityAuditFileSource(
                name: "OpenClaw",
                rootURL: paths.openClawAgents,
                allowedExtensions: ["jsonl"]),
        ]
    }
}
