import Foundation
import XCTest

final class AgentSystemdServiceTests: XCTestCase {
    func test_hardenedNamespaceExposesEverySupportedUsageSource() throws {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let serviceURL = repositoryRoot.appendingPathComponent("packaging/systemd/toki-agent.service")
        let service = try String(contentsOf: serviceURL, encoding: .utf8)

        XCTAssertTrue(service.contains("ProtectHome=tmpfs"))
        let temporaryHome = try XCTUnwrap(service.range(of: "TemporaryFileSystem=%h:ro"))
        let firstReadOnlyMount = try XCTUnwrap(service.range(of: "BindReadOnlyPaths="))
        XCTAssertLessThan(temporaryHome.lowerBound, firstReadOnlyMount.lowerBound)
        XCTAssertTrue(service.contains("PrivateUsers=true"))
        XCTAssertFalse(service.contains("ProtectControlGroups="))
        XCTAssertFalse(service.contains("ProtectKernelLogs="))
        XCTAssertFalse(service.contains("ProtectKernelModules="))
        XCTAssertFalse(service.contains("ProtectKernelTunables="))
        let prepareSenpiMounts = try XCTUnwrap(service.range(
            of: "ExecStartPre=+/usr/bin/mkdir -p -m 0700 \"%h/.omo/senpi-task/children\" "
                + "\"%h/.omo/senpi-task/sessions\""))
        let doctor = try XCTUnwrap(service.range(
            of: "ExecStartPre=/usr/local/bin/toki-agent doctor"))
        XCTAssertLessThan(prepareSenpiMounts.lowerBound, doctor.lowerBound)
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
            "%h/.omo/agent/sessions",
            "%h/.senpi/agent/sessions",
            "%h/.omo/senpi-task/children",
            "%h/.omo/senpi-task/sessions",
            "%h/.pi/agent/sessions",
            "%h/.omp/agent/sessions",
            "%h/.config/kimchi/harness/sessions",
            "%h/.copilot/otel",
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
        XCTAssertFalse(service.contains("BindReadOnlyPaths=-%h/.omo/senpi-task\n"))
    }

    func test_restartPolicyRateLimitsRepeatedFailures() throws {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let serviceURL = repositoryRoot.appendingPathComponent("packaging/systemd/toki-agent.service")
        let service = try String(contentsOf: serviceURL, encoding: .utf8)
        let sections = service.components(separatedBy: "\n[Service]\n")
        let unitSection = try XCTUnwrap(sections.first)
        let serviceSection = try XCTUnwrap(sections.last)

        XCTAssertEqual(sections.count, 2)
        XCTAssertTrue(unitSection.contains("StartLimitIntervalSec=10min"))
        XCTAssertTrue(unitSection.contains("StartLimitBurst=5"))
        XCTAssertFalse(serviceSection.contains("StartLimitIntervalSec="))
        XCTAssertFalse(serviceSection.contains("StartLimitBurst="))
        XCTAssertTrue(serviceSection.contains("RestartSec=30s"))
        XCTAssertGreaterThan(10 * 60, 30 * 5)
    }
}
