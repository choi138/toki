import Foundation

extension SecurityAuditScanner {
    static func defaultSources(homeDirectory: URL = homeDir()) -> [SecurityAuditFileSource] {
        [
            SecurityAuditFileSource(
                name: "Claude Code",
                rootURL: homeDirectory.appendingPathComponent(".claude/projects"),
                allowedExtensions: ["jsonl"]),
            SecurityAuditFileSource(
                name: "Codex",
                rootURL: homeDirectory.appendingPathComponent(".codex/sessions"),
                allowedExtensions: ["jsonl"]),
            SecurityAuditFileSource(
                name: "Cursor",
                rootURL: homeDirectory.appendingPathComponent(
                    "Library/Application Support/Cursor/User/globalStorage"),
                allowedExtensions: ["vscdb"],
                sqliteTextQueries: [
                    "SELECT value FROM cursorDiskKV WHERE value IS NOT NULL",
                ]),
            SecurityAuditFileSource(
                name: "Gemini CLI",
                rootURL: homeDirectory.appendingPathComponent(".gemini/tmp"),
                allowedExtensions: ["json"]),
            SecurityAuditFileSource(
                name: "OpenCode",
                rootURL: homeDirectory.appendingPathComponent(".local/share/opencode"),
                allowedExtensions: ["db"],
                sqliteTextQueries: [
                    "SELECT data FROM message WHERE data IS NOT NULL",
                ]),
            SecurityAuditFileSource(
                name: "OpenClaw",
                rootURL: homeDirectory.appendingPathComponent(".openclaw/agents"),
                allowedExtensions: ["jsonl"]),
        ]
    }
}
