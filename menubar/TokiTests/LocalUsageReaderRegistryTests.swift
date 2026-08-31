import XCTest
@testable import Toki
@testable import TokiUsageReaders

final class LocalUsageReaderRegistryTests: XCTestCase {
    func test_usageAggregatorUsesEveryLocalRegistryReaderPlusRemoteDevices() {
        let localNames = LocalUsageReaderRegistry.readers().map(\.name)
        let aggregatorNames = UsageAggregator.defaultReaders.map(\.name)

        XCTAssertEqual(Array(aggregatorNames.dropLast()), localNames)
        XCTAssertEqual(aggregatorNames.last, "Remote Devices")
        XCTAssertEqual(
            localNames,
            [
                "Claude Code",
                "Codex",
                "Hermes",
                "Cursor",
                "Gemini CLI",
                "GJC",
                "Factory Droid",
                "Amp",
                "Senpi",
                "Pi",
                "Oh My Pi",
                "Kimchi",
                "OpenCode",
                "OpenClaw",
                "GitHub Copilot CLI",
                "Kimi CLI",
                "Kimi Code",
                "Qwen CLI",
            ])
    }

    func test_readerPathsUseInjectedHomeAndXDGDirectories() {
        let home = URL(fileURLWithPath: "/tmp/toki-reader-home")
        let paths = LocalUsageReaderPaths(
            homeDirectory: home,
            environment: [
                "XDG_CONFIG_HOME": "/tmp/toki-xdg-config",
                "XDG_DATA_HOME": "/tmp/toki-xdg-data",
                "XDG_STATE_HOME": "/tmp/toki-xdg-state",
            ])

        XCTAssertEqual(paths.claudeProjects.path, "/tmp/toki-reader-home/.claude/projects")
        XCTAssertEqual(paths.hermesDatabase.path, "/tmp/toki-reader-home/.hermes/state.db")
        XCTAssertEqual(paths.factoryDroidSessions.path, "/tmp/toki-reader-home/.factory/sessions")
        XCTAssertEqual(paths.ampThreads.path, "/tmp/toki-xdg-data/amp/threads")
        XCTAssertEqual(paths.openCodeDatabase.path, "/tmp/toki-xdg-data/opencode/opencode.db")
        XCTAssertEqual(
            paths.senpiSessionDirectories.map(\.path),
            [
                "/tmp/toki-reader-home/.omo/agent/sessions",
                "/tmp/toki-reader-home/.senpi/agent/sessions",
                "/tmp/toki-reader-home/.omo/senpi-task/children",
                "/tmp/toki-reader-home/.omo/senpi-task/sessions",
            ])
        XCTAssertEqual(paths.copilotOTELDirectory.path, "/tmp/toki-reader-home/.copilot/otel")
        XCTAssertNil(paths.copilotOTELExporterFile)
        XCTAssertEqual(paths.agentCacheDirectory.path, "/tmp/toki-xdg-state/toki-agent")
        #if os(Linux)
            XCTAssertEqual(
                paths.cursorDatabase.path,
                "/tmp/toki-xdg-config/Cursor/User/globalStorage/state.vscdb")
        #else
            XCTAssertEqual(
                paths.cursorDatabase.path,
                "/tmp/toki-reader-home/Library/Application Support/Cursor/User/globalStorage/state.vscdb")
        #endif
    }
}

extension LocalUsageReaderRegistryTests {
    func test_factoryDroidAndAmpReadersAreRegisteredExactlyOnce() {
        let home = URL(fileURLWithPath: "/tmp/toki-reader-home")
        let descriptors = LocalUsageReaderRegistry.descriptors(
            home: home,
            environment: ["XDG_DATA_HOME": "/tmp/toki-xdg-data"])

        let droid = descriptors.filter { $0.name == FactoryDroidReader.sourceName }
        let amp = descriptors.filter { $0.name == AmpReader.sourceName }

        XCTAssertEqual(droid.count, 1)
        XCTAssertEqual(amp.count, 1)
        XCTAssertEqual(
            droid.first?.sourceLocations,
            [
                .directory(
                    home.appendingPathComponent(".factory/sessions"),
                    extensions: ["json", "jsonl"]),
            ])
        XCTAssertEqual(
            amp.first?.sourceLocations,
            [
                .directory(
                    URL(fileURLWithPath: "/tmp/toki-xdg-data/amp/threads"),
                    extensions: ["json"]),
            ])
    }
}

extension LocalUsageReaderRegistryTests {
    func test_senpiPathsUseOnlyAbsoluteOverridesAndIncludeDelegatedRoots() {
        let home = URL(fileURLWithPath: "/tmp/toki-reader-home")
        let paths = LocalUsageReaderPaths(
            homeDirectory: home,
            environment: [
                "PWD": "/tmp/toki-project",
                "SENPI_CODING_AGENT_DIR": "/tmp/senpi-agent",
                "SENPI_CODING_AGENT_SESSION_DIR": "/tmp/senpi-sessions",
            ])

        XCTAssertEqual(paths.senpiSessionDirectories.map(\.path), [
            "/tmp/toki-reader-home/.omo/agent/sessions",
            "/tmp/toki-reader-home/.senpi/agent/sessions",
            "/tmp/toki-reader-home/.omo/senpi-task/children",
            "/tmp/toki-reader-home/.omo/senpi-task/sessions",
            "/tmp/senpi-agent/sessions",
            "/tmp/senpi-sessions",
            "/tmp/toki-project/.omo/senpi-task/children",
            "/tmp/toki-project/.omo/senpi-task/sessions",
        ])

        let ignored = LocalUsageReaderPaths(
            homeDirectory: home,
            environment: [
                "PWD": "",
                "SENPI_CODING_AGENT_DIR": "relative-agent",
                "SENPI_CODING_AGENT_SESSION_DIR": "relative-sessions",
            ])

        XCTAssertEqual(
            ignored.senpiSessionDirectories.map(\.path),
            [
                "/tmp/toki-reader-home/.omo/agent/sessions",
                "/tmp/toki-reader-home/.senpi/agent/sessions",
                "/tmp/toki-reader-home/.omo/senpi-task/children",
                "/tmp/toki-reader-home/.omo/senpi-task/sessions",
            ])
    }

    func test_copilotExporterPathRequiresAnAbsoluteNonEmptyJSONLFile() {
        let home = URL(fileURLWithPath: "/tmp/toki-reader-home")

        XCTAssertEqual(
            LocalUsageReaderPaths(
                homeDirectory: home,
                environment: ["COPILOT_OTEL_FILE_EXPORTER_PATH": "/tmp/copilot.jsonl"])
                .copilotOTELExporterFile?.path,
            "/tmp/copilot.jsonl")
        XCTAssertNil(
            LocalUsageReaderPaths(
                homeDirectory: home,
                environment: ["COPILOT_OTEL_FILE_EXPORTER_PATH": "relative/copilot.jsonl"])
                .copilotOTELExporterFile)
        XCTAssertNil(
            LocalUsageReaderPaths(
                homeDirectory: home,
                environment: ["COPILOT_OTEL_FILE_EXPORTER_PATH": ""])
                .copilotOTELExporterFile)
        XCTAssertNil(
            LocalUsageReaderPaths(
                homeDirectory: home,
                environment: ["COPILOT_OTEL_FILE_EXPORTER_PATH": "/tmp"])
                .copilotOTELExporterFile)
    }

    func test_copilotReaderIsRegisteredOnceWithDefaultAndOverrideLocations() {
        let home = URL(fileURLWithPath: "/tmp/toki-reader-home")
        let descriptors = LocalUsageReaderRegistry.descriptors(
            home: home,
            environment: ["COPILOT_OTEL_FILE_EXPORTER_PATH": "/tmp/copilot.jsonl"])
        let copilotDescriptors = descriptors.filter { $0.name == CopilotCLIReader.sourceName }

        XCTAssertEqual(copilotDescriptors.count, 1)
        XCTAssertEqual(
            copilotDescriptors.first?.sourceLocations,
            [
                .directory(home.appendingPathComponent(".copilot/otel"), extensions: ["jsonl"]),
                .file(URL(fileURLWithPath: "/tmp/copilot.jsonl"), includesSQLiteSidecars: false),
            ])
    }

    func test_senpiReaderIsRegisteredExactlyOnceWithEveryDiscoveryRoot() {
        let home = URL(fileURLWithPath: "/tmp/toki-reader-home")
        let descriptors = LocalUsageReaderRegistry.descriptors(
            home: home,
            environment: [
                "PWD": "/tmp/toki-project",
                "SENPI_CODING_AGENT_SESSION_DIR": "/tmp/senpi-sessions",
            ])
        let senpiDescriptors = descriptors.filter { $0.name == SenpiReader.sourceName }

        XCTAssertEqual(senpiDescriptors.count, 1)
        XCTAssertEqual(
            senpiDescriptors.first?.sourceLocations,
            [
                .directory(
                    home.appendingPathComponent(".omo/agent/sessions"),
                    extensions: ["jsonl"]),
                .directory(
                    home.appendingPathComponent(".senpi/agent/sessions"),
                    extensions: ["jsonl"]),
                .directory(
                    home.appendingPathComponent(".omo/senpi-task/children"),
                    extensions: ["jsonl"]),
                .directory(
                    home.appendingPathComponent(".omo/senpi-task/sessions"),
                    extensions: ["jsonl"]),
                .directory(
                    URL(fileURLWithPath: "/tmp/senpi-sessions"),
                    extensions: ["jsonl"]),
                .directory(
                    URL(fileURLWithPath: "/tmp/toki-project/.omo/senpi-task/children"),
                    extensions: ["jsonl"]),
                .directory(
                    URL(fileURLWithPath: "/tmp/toki-project/.omo/senpi-task/sessions"),
                    extensions: ["jsonl"]),
            ])
    }

    func test_readerCachesUseExplicitApplicationAndAgentScopes() {
        let paths = LocalUsageReaderPaths(
            homeDirectory: URL(fileURLWithPath: "/tmp/toki-reader-home"),
            environment: ["XDG_STATE_HOME": "/tmp/toki-xdg-state"])

        #if os(macOS)
            XCTAssertEqual(
                paths.applicationCacheDirectory.path,
                "/tmp/toki-reader-home/Library/Application Support/Toki")
        #else
            XCTAssertEqual(paths.applicationCacheDirectory.path, "/tmp/toki-xdg-state/toki")
        #endif
        XCTAssertEqual(
            codexRolloutUsageCacheURL(paths: paths, scope: .agent).path,
            "/tmp/toki-xdg-state/toki-agent/codex-rollout-cache.json")
        XCTAssertEqual(
            claudeUsageCacheURL(paths: paths, scope: .agent).path,
            "/tmp/toki-xdg-state/toki-agent/claude-usage-cache.json")
        XCTAssertEqual(
            hermesUsageLedgerURL(paths: paths, scope: .agent).path,
            "/tmp/toki-xdg-state/toki-agent/hermes-usage-ledger.json")
    }

    func test_applicationCodexCacheUsesInjectedHome() async throws {
        let home = URL(fileURLWithPath: "/tmp/toki-injected-reader-home")
        let readers = LocalUsageReaderRegistry.readers(home: home, environment: [:])
        let reader = try XCTUnwrap(readers.first { $0.name == "Codex" } as? CodexReader)
        let paths = LocalUsageReaderPaths(homeDirectory: home, environment: [:])
        let expectedCacheURL = codexRolloutUsageCacheURL(paths: paths, scope: .application)

        let cacheURL = await reader.rolloutUsageCache.cacheURL

        XCTAssertEqual(cacheURL, expectedCacheURL)
    }
}
