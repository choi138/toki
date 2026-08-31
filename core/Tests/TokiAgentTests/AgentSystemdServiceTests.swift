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
            of: "ExecStartPre=+/usr/local/bin/toki-agent prepare-senpi-mounts"))
        let doctor = try XCTUnwrap(service.range(
            of: "ExecStartPre=/usr/local/bin/toki-agent doctor"))
        XCTAssertLessThan(prepareSenpiMounts.lowerBound, doctor.lowerBound)
        XCTAssertFalse(service.contains("/usr/bin/mkdir"))
        let readOnlyPaths = service
            .split(whereSeparator: \.isNewline)
            .filter { $0.hasPrefix("BindReadOnlyPaths=") }
            .flatMap { line in
                line.dropFirst("BindReadOnlyPaths=".count)
                    .split(whereSeparator: \.isWhitespace)
                    .map { token -> String in
                        let unprefixed = token.first == "-" ? token.dropFirst() : token[...]
                        return String(
                            unprefixed.split(separator: ":", maxSplits: 1).first ?? unprefixed)
                    }
            }
        for path in Self.expectedReadOnlyPaths {
            XCTAssertTrue(readOnlyPaths.contains(path), path)
        }
        XCTAssertTrue(service.contains("BindPaths=%h/.config/toki-agent"))
        XCTAssertTrue(service.contains("BindPaths=%h/.local/state/toki-agent"))
        XCTAssertTrue(service.contains("BindPaths=%h/.local/share/toki-agent"))
        XCTAssertFalse(readOnlyPaths.contains("%h/.hermes"))
        XCTAssertFalse(readOnlyPaths.contains("%h/.config/Cursor"))
        XCTAssertFalse(readOnlyPaths.contains("%h/.local/share/opencode"))
        XCTAssertFalse(readOnlyPaths.contains("%h/.omo/senpi-task"))
        XCTAssertFalse(readOnlyPaths.contains("%h/.omp/profiles"))
        XCTAssertFalse(readOnlyPaths.contains("%h/.local/share/omp"))
        XCTAssertFalse(readOnlyPaths.contains("%h/.kimi"))
        XCTAssertFalse(readOnlyPaths.contains("%h/.kimi/config.toml"))
        XCTAssertFalse(readOnlyPaths.contains("%h/.kimi/config.json"))
    }

    private static let expectedReadOnlyPaths = [
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
        "%h/.local/share/omp/sessions",
        "%h/.config/kimchi/harness/sessions",
        "%h/.copilot/otel",
        "%h/.local/share/opencode/opencode.db",
        "%h/.local/share/opencode/opencode.db-wal",
        "%h/.local/share/opencode/opencode.db-shm",
        "%h/.openclaw/agents",
        "%h/.kimi/sessions",
        "%h/.kimi-code/sessions",
        "%h/.qwen/projects",
        "%h/.factory/sessions",
        "%h/.local/share/amp/threads",
    ]

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

    func test_overrideDropInExposesOnlyRequiredChineseCLIPaths() throws {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let exampleURL = repositoryRoot.appendingPathComponent(
            "packaging/systemd/toki-agent-overrides.conf.example")
        let documentationURL = repositoryRoot.appendingPathComponent("docs/remote-sync.md")
        let example = try String(contentsOf: exampleURL, encoding: .utf8)
        let documentation = try String(contentsOf: documentationURL, encoding: .utf8)

        for variable in [
            "COPILOT_OTEL_FILE_EXPORTER_PATH",
            "KIMI_SHARE_DIR",
            "KIMI_CODE_HOME",
            "QWEN_HOME",
            "QWEN_RUNTIME_DIR",
        ] {
            XCTAssertTrue(example.contains("Environment=\"\(variable)="), variable)
            XCTAssertTrue(documentation.contains(variable), variable)
        }
        let expectedReadOnlyPaths = [
            "/home/USER/.local/share/copilot/otel.jsonl",
            "/home/USER/.local/share/kimi/sessions",
            "/home/USER/.local/share/kimi-code/sessions",
            "/home/USER/.local/share/qwen/projects",
            "/home/USER/.cache/qwen/projects",
        ]
        for path in expectedReadOnlyPaths {
            XCTAssertTrue(example.contains("BindReadOnlyPaths=\(path)"), path)
        }
        XCTAssertEqual(
            example.components(separatedBy: "BindReadOnlyPaths=").count - 1,
            expectedReadOnlyPaths.count)
        XCTAssertFalse(example.contains("BindReadOnlyPaths=-"))
        XCTAssertFalse(example.contains("BindReadOnlyPaths=/home/USER/.local/share/kimi\n"))
        XCTAssertFalse(example.contains("BindReadOnlyPaths=/home/USER/.local/share/kimi-code\n"))
        XCTAssertFalse(example.contains("BindReadOnlyPaths=/home/USER/.local/share/qwen\n"))
        XCTAssertFalse(example.contains("BindReadOnlyPaths=/home/USER/.cache/qwen\n"))
        XCTAssertFalse(example.contains("BindReadOnlyPaths=/home/USER/.local/share/kimi/config"))
        XCTAssertTrue(documentation.contains("toki-agent-overrides.conf.example"))
        XCTAssertTrue(documentation.contains("systemctl --user edit toki-agent"))
    }
}
