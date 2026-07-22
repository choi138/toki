import XCTest
@testable import Toki
@testable import TokiUsageReaders

final class LocalUsageReaderRegistryTests: XCTestCase {
    func test_usageAggregatorUsesEveryLocalRegistryReader() {
        let localNames = LocalUsageReaderRegistry.readers().map(\.name)
        let aggregatorNames = UsageAggregator.defaultReaders.map(\.name)

        XCTAssertEqual(aggregatorNames, localNames)
        XCTAssertEqual(
            localNames,
            ["Claude Code", "Codex", "Hermes", "Cursor", "Gemini CLI", "GJC", "OpenCode", "OpenClaw"])
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
        XCTAssertEqual(paths.openCodeDatabase.path, "/tmp/toki-xdg-data/opencode/opencode.db")
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
