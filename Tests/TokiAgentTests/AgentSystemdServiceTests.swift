import Foundation
import XCTest

final class AgentSystemdServiceTests: XCTestCase {
    func test_hardenedNamespaceExposesEverySupportedUsageSource() throws {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let serviceURL = repositoryRoot.appendingPathComponent("packaging/systemd/toki-agent.service")
        let service = try String(contentsOf: serviceURL, encoding: .utf8)

        XCTAssertTrue(service.contains("ProtectHome=tmpfs"))
        XCTAssertTrue(service.contains("PrivateUsers=true"))
        XCTAssertFalse(service.contains("ProtectControlGroups="))
        XCTAssertFalse(service.contains("ProtectKernelLogs="))
        XCTAssertFalse(service.contains("ProtectKernelModules="))
        XCTAssertFalse(service.contains("ProtectKernelTunables="))
        XCTAssertTrue(service.contains("ExecStartPre=/usr/local/bin/toki-agent doctor"))
        let expectedReadOnlyPaths = [
            "%h/.claude/projects",
            "%h/.codex/state_5.sqlite",
            "%h/.codex/state_5.sqlite-wal",
            "%h/.codex/state_5.sqlite-shm",
            "%h/.codex/sessions",
            "%h/.codex/archived_sessions",
            "%h/.hermes/state.db",
            "%h/.hermes/state.db-wal",
            "%h/.hermes/state.db-shm",
            "%h/.config/Cursor/User/globalStorage/state.vscdb",
            "%h/.config/Cursor/User/globalStorage/state.vscdb-wal",
            "%h/.config/Cursor/User/globalStorage/state.vscdb-shm",
            "%h/.gemini/tmp",
            "%h/.gjc/agent/sessions",
            "%h/.local/share/opencode/opencode.db",
            "%h/.local/share/opencode/opencode.db-wal",
            "%h/.local/share/opencode/opencode.db-shm",
            "%h/.openclaw/agents",
        ]
        for path in expectedReadOnlyPaths {
            XCTAssertTrue(service.contains("BindReadOnlyPaths=-\(path)"), path)
        }
        XCTAssertTrue(service.contains("BindPaths=%h/.config/toki-agent"))
        XCTAssertTrue(service.contains("BindPaths=%h/.local/state/toki-agent"))
        XCTAssertTrue(service.contains("BindPaths=%h/.local/share/toki-agent"))
        XCTAssertFalse(service.contains("BindReadOnlyPaths=-%h/.hermes\n"))
        XCTAssertFalse(service.contains("BindReadOnlyPaths=-%h/.config/Cursor\n"))
        XCTAssertFalse(service.contains("BindReadOnlyPaths=-%h/.local/share/opencode\n"))
    }
}
