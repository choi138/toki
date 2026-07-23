import Foundation
import TokiSyncProtocol
import TokiUsageCore
import XCTest
@testable import TokiAgentCore
@testable import TokiUsageReaders

#if os(Linux)
    import CSQLite
#else
    import SQLite3
#endif

final class AgentSnapshotBuilderTests: XCTestCase {
    func test_coldAndWarmCachesProduceIdenticalMultiSourceSnapshotEventsAndDigest() async throws {
        let fixture = try AgentSnapshotFixture()
        defer { fixture.remove() }
        let cacheURL = fixture.root.appendingPathComponent("state/codex-rollout-cache.json")
        let cache = CodexRolloutUsageCache(cacheURL: cacheURL)
        let environment: [String: String] = [:]
        let paths = LocalUsageReaderPaths(homeDirectory: fixture.root, environment: environment)
        try await HermesUsageLedger(fileURL: hermesUsageLedgerURL(paths: paths, scope: .agent)).refresh(
            observations: [],
            observedAt: fixture.latestEventDate.addingTimeInterval(-7200))
        let builder = AgentSnapshotBuilder(
            home: fixture.root,
            environment: environment,
            rolloutUsageCache: cache,
            retentionTimeZone: .autoupdatingCurrent)

        XCTAssertFalse(FileManager.default.fileExists(atPath: cacheURL.path))
        let coldSnapshot = try await builder.build(configuration: fixture.configuration, now: fixture.now)
        XCTAssertTrue(FileManager.default.fileExists(atPath: cacheURL.path))
        let warmSnapshot = try await builder.build(configuration: fixture.configuration, now: fixture.now)

        XCTAssertEqual(coldSnapshot.tokenEvents.count, 3)
        XCTAssertEqual(coldSnapshot.activityEvents.count, 3)
        XCTAssertEqual(Set(coldSnapshot.tokenEvents.map(\.source)), ["Codex", "Hermes"])
        XCTAssertEqual(Set(coldSnapshot.activityEvents.map(\.source)), ["Codex", "Hermes"])
        let hermesEvent = try XCTUnwrap(coldSnapshot.tokenEvents.first { $0.source == "Hermes" })
        XCTAssertEqual(hermesEvent.inputTokens, 200)
        XCTAssertEqual(hermesEvent.outputTokens, 50)
        XCTAssertEqual(hermesEvent.cacheReadTokens, 10)
        XCTAssertEqual(hermesEvent.cacheWriteTokens, 5)
        XCTAssertEqual(hermesEvent.reasoningTokens, 15)
        XCTAssertEqual(coldSnapshot.tokenEvents.last?.timestamp, fixture.latestEventDate)
        XCTAssertEqual(coldSnapshot.tokenEvents, warmSnapshot.tokenEvents)
        XCTAssertEqual(coldSnapshot.activityEvents, warmSnapshot.activityEvents)
        XCTAssertEqual(
            try builder.contentDigest(coldSnapshot),
            try builder.contentDigest(warmSnapshot))
        let encodedSnapshot = try XCTUnwrap(String(
            data: TokiSyncCoding.makeEncoder().encode(coldSnapshot),
            encoding: .utf8))
        XCTAssertFalse(encodedSnapshot.contains("hermes-session"))
        XCTAssertFalse(encodedSnapshot.contains("/tmp/hermes"))
    }

    func test_agentRegistryContainsEveryLocalTokiReaderAndNoRemoteReader() {
        let names = LocalUsageReaderRegistry.agentDescriptors().map(\.name)

        XCTAssertEqual(
            names,
            [
                "Claude Code",
                "Codex",
                "Hermes",
                "Cursor",
                "Gemini CLI",
                "GJC",
                "OpenCode",
                "OpenClaw",
            ])
        XCTAssertFalse(names.contains("Remote Devices"))
    }

    func test_snapshotPreservesTokenSourcesAndNamespacesActivityStreamsByReader() async throws {
        let now = Date(timeIntervalSince1970: 1_784_200_000)
        let eventDate = now.addingTimeInterval(-60)
        let firstUsage = Self.usage(source: "Claude Code", timestamp: eventDate, streamID: "shared-stream")
        let secondUsage = Self.usage(source: "Hermes", timestamp: eventDate, streamID: "shared-stream")
        let descriptors = [
            LocalUsageReaderDescriptor(
                reader: FixedTokenReader(name: "Hermes", usage: secondUsage),
                sourceLocations: []),
            LocalUsageReaderDescriptor(
                reader: FixedTokenReader(name: "Claude Code", usage: firstUsage),
                sourceLocations: []),
        ]
        let fixture = try AgentSnapshotFixture()
        defer { fixture.remove() }
        let builder = AgentSnapshotBuilder(
            home: fixture.root,
            readerDescriptors: descriptors)

        let snapshot = try await builder.build(configuration: fixture.configuration, now: now)

        XCTAssertEqual(snapshot.tokenEvents.map(\.source), ["Claude Code", "Hermes"])
        XCTAssertEqual(snapshot.activityEvents.map(\.source), ["Claude Code", "Hermes"])
        XCTAssertEqual(Set(snapshot.activityEvents.map(\.streamID)).count, 2)
        XCTAssertFalse(snapshot.activityEvents.contains { $0.streamID.contains("shared-stream") })
    }

    func test_sourceSignatureTracksSQLiteSidecarsAndRetainedLogsForEveryReaderStrategy() async throws {
        let fixture = try AgentSnapshotFixture()
        defer { fixture.remove() }
        let builder = AgentSnapshotBuilder(home: fixture.root)
        let initial = try await builder.sourceSignature(
            configuration: fixture.configuration,
            now: fixture.now)

        let hermesWAL = fixture.root.appendingPathComponent(".hermes/state.db-wal")
        try Data("wal metadata".utf8).write(to: hermesWAL)
        let afterWAL = try await builder.sourceSignature(
            configuration: fixture.configuration,
            now: fixture.now)

        let claudeLog = fixture.root.appendingPathComponent(".claude/projects/project/session.jsonl")
        try FileManager.default.createDirectory(
            at: claudeLog.deletingLastPathComponent(),
            withIntermediateDirectories: true)
        try Data("{}\n".utf8).write(to: claudeLog)
        try FileManager.default.setAttributes(
            [.modificationDate: fixture.now],
            ofItemAtPath: claudeLog.path)
        let afterLog = try await builder.sourceSignature(
            configuration: fixture.configuration,
            now: fixture.now)

        XCTAssertNotEqual(initial, afterWAL)
        XCTAssertNotEqual(afterWAL, afterLog)
    }

    func test_sourceSignatureTracksLedgerCreationAndStabilizesAfterVerificationBuild() async throws {
        let fixture = try AgentSnapshotFixture()
        defer { fixture.remove() }
        let environment: [String: String] = [:]
        let paths = LocalUsageReaderPaths(homeDirectory: fixture.root, environment: environment)
        let ledgerURL = hermesUsageLedgerURL(paths: paths, scope: .agent)
        let ledger = HermesUsageLedger(fileURL: ledgerURL)
        let descriptor = LocalUsageReaderDescriptor(
            reader: HermesReader(
                dbPathOverride: paths.hermesDatabase.path,
                usageLedger: ledger,
                now: { fixture.now }),
            sourceLocations: [
                .file(paths.hermesDatabase, includesSQLiteSidecars: true),
                .file(ledgerURL, includesSQLiteSidecars: false),
            ])
        let builder = AgentSnapshotBuilder(
            home: fixture.root,
            environment: environment,
            readerDescriptors: [descriptor])

        let missingLedgerSignature = try await builder.sourceSignature(
            configuration: fixture.configuration,
            now: fixture.now)
        let firstSnapshot = try await builder.build(configuration: fixture.configuration, now: fixture.now)
        let createdLedgerSignature = try await builder.sourceSignature(
            configuration: fixture.configuration,
            now: fixture.now)
        let verificationSnapshot = try await builder.build(
            configuration: fixture.configuration,
            now: fixture.now)
        let stableSignature = try await builder.sourceSignature(
            configuration: fixture.configuration,
            now: fixture.now)

        XCTAssertTrue(FileManager.default.fileExists(atPath: ledgerURL.path))
        XCTAssertNotEqual(missingLedgerSignature, createdLedgerSignature)
        XCTAssertEqual(createdLedgerSignature, stableSignature)
        XCTAssertEqual(firstSnapshot.tokenEvents, verificationSnapshot.tokenEvents)
        XCTAssertEqual(
            try builder.contentDigest(firstSnapshot),
            try builder.contentDigest(verificationSnapshot))
    }

    func test_defaultSourceSignatureTracksAgentHermesLedgerCreation() async throws {
        let fixture = try AgentSnapshotFixture()
        defer { fixture.remove() }
        let environment: [String: String] = [:]
        let paths = LocalUsageReaderPaths(homeDirectory: fixture.root, environment: environment)
        let ledgerURL = hermesUsageLedgerURL(paths: paths, scope: .agent)
        let builder = AgentSnapshotBuilder(
            home: fixture.root,
            environment: environment)

        let missingLedgerSignature = try await builder.sourceSignature(
            configuration: fixture.configuration,
            now: fixture.now)
        try await HermesUsageLedger(fileURL: ledgerURL).refresh(
            observations: [],
            observedAt: fixture.now)
        let createdLedgerSignature = try await builder.sourceSignature(
            configuration: fixture.configuration,
            now: fixture.now)

        XCTAssertNotEqual(missingLedgerSignature, createdLedgerSignature)
    }

    func test_retentionWindowCoversExactlyConfiguredCalendarDays() async throws {
        let fixture = try AgentSnapshotFixture()
        defer { fixture.remove() }
        let retentionDays = 7
        let hubURL = try XCTUnwrap(URL(string: "https://hub.example.test"))
        let configuration = try AgentConfiguration(bundle: AgentPairingBundle(
            hubURL: hubURL,
            deviceID: "retention-device",
            deviceName: "ubuntu",
            uploadToken: SnapshotCipher.randomToken(),
            encryptionKey: SnapshotCipher.generateKey(),
            retentionDays: retentionDays,
            syncIntervalSeconds: 900))
        let timeZone = TimeZone(secondsFromGMT: 0) ?? .current
        let builder = AgentSnapshotBuilder(
            home: fixture.root,
            readerDescriptors: [],
            retentionTimeZone: timeZone)

        let snapshot = try await builder.build(configuration: configuration, now: fixture.now)

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        XCTAssertEqual(
            calendar.dateComponents(
                [.day],
                from: snapshot.coveredFrom,
                to: snapshot.coveredTo).day,
            retentionDays)
    }
}

extension AgentSnapshotBuilderTests {
    func test_sourceSignatureIgnoresSymlinkedCodexRollouts() async throws {
        let fixture = try AgentSnapshotFixture()
        defer { fixture.remove() }
        let archiveDirectory = fixture.root.appendingPathComponent(".codex/archived_sessions")
        try FileManager.default.createDirectory(at: archiveDirectory, withIntermediateDirectories: true)
        let targetURL = fixture.root.appendingPathComponent("outside-rollout.jsonl")
        let linkURL = archiveDirectory.appendingPathComponent("linked-rollout.jsonl")
        try Data("{\"value\":1}\n".utf8).write(to: targetURL)
        try FileManager.default.createSymbolicLink(at: linkURL, withDestinationURL: targetURL)
        let builder = AgentSnapshotBuilder(home: fixture.root)

        let before = try await builder.sourceSignature(
            configuration: fixture.configuration,
            now: fixture.now)
        try Data("{\"value\":2}\n".utf8).write(to: targetURL)
        let after = try await builder.sourceSignature(
            configuration: fixture.configuration,
            now: fixture.now)

        XCTAssertEqual(before, after)
    }

    func test_sharedReaderFileDiscoverySkipsSymbolicLinks() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("toki-reader-symlink-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let logsDirectory = root.appendingPathComponent("logs", isDirectory: true)
        try FileManager.default.createDirectory(at: logsDirectory, withIntermediateDirectories: true)
        let target = root.appendingPathComponent("target.jsonl")
        try Data("{}\n".utf8).write(to: target)
        let link = logsDirectory.appendingPathComponent("session.jsonl")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)

        let files = findFiles(
            in: logsDirectory,
            withExtension: "jsonl",
            modifiedAfter: Date.distantPast)

        XCTAssertTrue(files.isEmpty)
    }

    func test_sourceSignatureIgnoresGenericLogsOutsideRetentionWindow() async throws {
        let fixture = try AgentSnapshotFixture()
        defer { fixture.remove() }
        let claudeProjects = fixture.root.appendingPathComponent(".claude/projects")
        try FileManager.default.createDirectory(at: claudeProjects, withIntermediateDirectories: true)
        let builder = AgentSnapshotBuilder(home: fixture.root)
        let before = try await builder.sourceSignature(
            configuration: fixture.configuration,
            now: fixture.now)

        let oldLog = claudeProjects.appendingPathComponent("old.jsonl")
        try Data("{}\n".utf8).write(to: oldLog)
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSince1970: 978_307_200)],
            ofItemAtPath: oldLog.path)
        let after = try await builder.sourceSignature(
            configuration: fixture.configuration,
            now: fixture.now)

        XCTAssertEqual(before, after)
    }
}

extension AgentSnapshotBuilderTests {
    func test_fullRescanCacheResetRemovesCodexAndClaudeCaches() async throws {
        let fixture = try AgentSnapshotFixture()
        defer { fixture.remove() }
        let cacheDirectory = fixture.root.appendingPathComponent("cache")
        let codexCacheURL = cacheDirectory.appendingPathComponent("codex.json")
        let claudeCacheURL = cacheDirectory.appendingPathComponent("claude.json")
        try FileManager.default.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: codexCacheURL)
        try Data("{}".utf8).write(to: claudeCacheURL)
        let builder = AgentSnapshotBuilder(
            home: fixture.root,
            rolloutUsageCache: CodexRolloutUsageCache(cacheURL: codexCacheURL),
            claudeUsageCache: ClaudeUsageCache(cacheURL: claudeCacheURL),
            readerDescriptors: [])

        try await builder.resetCaches()

        XCTAssertFalse(FileManager.default.fileExists(atPath: codexCacheURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: claudeCacheURL.path))
    }

    func test_fullRescanCacheResetPreservesHermesAccountingLedger() async throws {
        let fixture = try AgentSnapshotFixture()
        defer { fixture.remove() }
        let ledgerURL = fixture.root.appendingPathComponent("state/hermes-usage-ledger.json")
        let ledger = HermesUsageLedger(fileURL: ledgerURL)
        try await ledger.refresh(
            observations: [],
            observedAt: fixture.now.addingTimeInterval(-7200))
        try await ledger.refresh(
            observations: [HermesSessionObservation(
                sessionID: "full-rescan-session",
                startedAt: fixture.now.addingTimeInterval(-3600),
                earliestActivityAt: fixture.now.addingTimeInterval(-60),
                latestActivityAt: fixture.now.addingTimeInterval(-60),
                model: "gpt-5",
                counters: HermesTokenCounters(
                    inputTokens: 100,
                    outputTokens: 20,
                    cacheReadTokens: 0,
                    cacheWriteTokens: 0,
                    reasoningTokens: 0),
                cost: 0,
                projectName: nil,
                attributionQuality: .unknown)],
            observedAt: fixture.now)
        let builder = AgentSnapshotBuilder(
            home: fixture.root,
            rolloutUsageCache: CodexRolloutUsageCache(
                cacheURL: fixture.root.appendingPathComponent("state/codex-rollout-cache.json")),
            claudeUsageCache: ClaudeUsageCache(
                cacheURL: fixture.root.appendingPathComponent("state/claude-usage-cache.json")),
            readerDescriptors: [])

        try await builder.resetCaches()

        let restartedLedger = HermesUsageLedger(fileURL: ledgerURL)
        let events = try await restartedLedger.events(
            from: fixture.now.addingTimeInterval(-7200),
            to: fixture.now.addingTimeInterval(3600))
        XCTAssertEqual(events.map(\.counters.totalTokens), [120])
    }

    private static func usage(source: String, timestamp: Date, streamID: String) -> RawTokenUsage {
        var usage = RawTokenUsage()
        usage.recordTokenEvent(
            timestamp: timestamp,
            source: source,
            model: "test-model",
            inputTokens: 10,
            outputTokens: 5)
        usage.activityEvents = [
            ActivityTimeEvent(
                streamID: streamID,
                timestamp: timestamp,
                key: "test-model"),
        ]
        return usage
    }
}

private struct AgentSnapshotFixture {
    let root: URL
    let configuration: AgentConfiguration
    let now: Date
    let latestEventDate: Date

    init() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("toki-agent-snapshot-tests-\(UUID().uuidString)")
        now = try Self.date("2026-07-16T12:00:00Z")
        let firstEventDate = try Self.date("2026-07-16T09:00:00Z")
        latestEventDate = try Self.date("2026-07-16T10:00:00Z")
        configuration = try AgentConfiguration(bundle: AgentPairingBundle(
            hubURL: URL(string: "https://hub.example.test")!,
            deviceID: "snapshot-device",
            deviceName: "ubuntu",
            uploadToken: SnapshotCipher.randomToken(),
            encryptionKey: SnapshotCipher.generateKey(),
            retentionDays: 7,
            syncIntervalSeconds: 900))

        let codexHome = root.appendingPathComponent(".codex")
        let sessionDirectory = Self.sessionDirectory(codexHome: codexHome, for: firstEventDate)
        try FileManager.default.createDirectory(at: sessionDirectory, withIntermediateDirectories: true)
        let firstRollout = sessionDirectory.appendingPathComponent("first.jsonl")
        let secondRollout = sessionDirectory.appendingPathComponent("second.jsonl")
        try Self.writeRollout(
            to: firstRollout,
            sessionID: "session-first",
            eventDate: firstEventDate,
            inputTokens: 120,
            outputTokens: 30)
        try Self.writeRollout(
            to: secondRollout,
            sessionID: "session-second",
            eventDate: latestEventDate,
            inputTokens: 80,
            outputTokens: 20)
        try Self.createDatabase(
            at: codexHome.appendingPathComponent("state_5.sqlite"),
            sessions: [
                (firstRollout, firstEventDate),
                (secondRollout, latestEventDate),
            ])
        try Self.createHermesDatabase(
            at: root.appendingPathComponent(".hermes/state.db"),
            eventDate: firstEventDate.addingTimeInterval(30 * 60))
    }

    func remove() {
        try? FileManager.default.removeItem(at: root)
    }

    private static func sessionDirectory(codexHome: URL, for date: Date) -> URL {
        let components = Calendar.autoupdatingCurrent.dateComponents([.year, .month, .day], from: date)
        return codexHome
            .appendingPathComponent("sessions")
            .appendingPathComponent(String(format: "%04d", components.year ?? 0))
            .appendingPathComponent(String(format: "%02d", components.month ?? 0))
            .appendingPathComponent(String(format: "%02d", components.day ?? 0))
    }

    private static func writeRollout(
        to url: URL,
        sessionID: String,
        eventDate: Date,
        inputTokens: Int,
        outputTokens: Int) throws {
        let timestamp = timestamp(eventDate)
        let lines = [
            "{\"timestamp\":\"\(timestamp)\",\"type\":\"session_meta\",\"payload\":{" +
                "\"id\":\"\(sessionID)\",\"source\":\"vscode\",\"cwd\":\"/tmp/project\"}}",
            "{\"timestamp\":\"\(timestamp)\",\"type\":\"turn_context\",\"payload\":{" +
                "\"model\":\"gpt-5\",\"cwd\":\"/tmp/project\"}}",
            "{\"timestamp\":\"\(timestamp)\",\"type\":\"event_msg\",\"payload\":{" +
                "\"type\":\"token_count\",\"info\":{\"total_token_usage\":{" +
                "\"input_tokens\":\(inputTokens),\"cached_input_tokens\":0," +
                "\"output_tokens\":\(outputTokens),\"reasoning_output_tokens\":0," +
                "\"total_tokens\":\(inputTokens + outputTokens)}}}}",
        ]
        try Data((lines.joined(separator: "\n") + "\n").utf8).write(to: url)
        try FileManager.default.setAttributes([.modificationDate: eventDate], ofItemAtPath: url.path)
    }

    private static func createDatabase(at url: URL, sessions: [(URL, Date)]) throws {
        var database: OpaquePointer?
        guard sqlite3_open(url.path, &database) == SQLITE_OK else {
            sqlite3_close(database)
            throw AgentSnapshotFixtureError.sqlite
        }
        defer { sqlite3_close(database) }
        try execute(
            """
            CREATE TABLE threads (
                rollout_path TEXT NOT NULL,
                model TEXT,
                source TEXT,
                cwd TEXT,
                created_at INTEGER NOT NULL,
                updated_at INTEGER NOT NULL
            )
            """,
            in: database)
        for (rolloutURL, eventDate) in sessions {
            let path = rolloutURL.path.replacingOccurrences(of: "'", with: "''")
            let epoch = Int64(eventDate.timeIntervalSince1970)
            try execute(
                """
                INSERT INTO threads (rollout_path, model, source, cwd, created_at, updated_at)
                VALUES ('\(path)', 'gpt-5', 'vscode', '/tmp/project', \(epoch - 60), \(epoch + 60))
                """,
                in: database)
        }
    }

    private static func createHermesDatabase(at url: URL, eventDate: Date) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true)
        var database: OpaquePointer?
        guard sqlite3_open(url.path, &database) == SQLITE_OK else {
            sqlite3_close(database)
            throw AgentSnapshotFixtureError.sqlite
        }
        defer { sqlite3_close(database) }
        try execute(
            """
            CREATE TABLE sessions (
                id TEXT NOT NULL,
                started_at REAL NOT NULL,
                model TEXT,
                cwd TEXT,
                git_repo_root TEXT,
                input_tokens INTEGER,
                output_tokens INTEGER,
                cache_read_tokens INTEGER,
                cache_write_tokens INTEGER,
                reasoning_tokens INTEGER,
                estimated_cost_usd REAL,
                actual_cost_usd REAL
            )
            """,
            in: database)
        try execute(
            """
            INSERT INTO sessions (
                id, started_at, model, cwd, git_repo_root,
                input_tokens, output_tokens, cache_read_tokens, cache_write_tokens,
                reasoning_tokens, estimated_cost_usd, actual_cost_usd
            ) VALUES (
                'hermes-session', \(eventDate.timeIntervalSince1970), 'gpt-5', '/tmp/hermes', '',
                0, 0, 0, 0, 0, 0, 0
            )
            """,
            in: database)
        try execute(
            """
            CREATE TABLE session_model_usage (
                session_id TEXT NOT NULL,
                billing_provider TEXT NOT NULL,
                model TEXT NOT NULL,
                task TEXT NOT NULL,
                api_call_count INTEGER NOT NULL,
                input_tokens INTEGER NOT NULL,
                output_tokens INTEGER NOT NULL,
                cache_read_tokens INTEGER NOT NULL,
                cache_write_tokens INTEGER NOT NULL,
                reasoning_tokens INTEGER NOT NULL,
                estimated_cost_usd REAL NOT NULL,
                actual_cost_usd REAL NOT NULL
            )
            """,
            in: database)
        try execute(
            """
            INSERT INTO session_model_usage (
                session_id, billing_provider, model, task, api_call_count,
                input_tokens, output_tokens, cache_read_tokens, cache_write_tokens,
                reasoning_tokens, estimated_cost_usd, actual_cost_usd
            ) VALUES (
                'hermes-session', 'openrouter', 'gpt-5', '', 1,
                200, 50, 10, 5, 15, 0, 0
            )
            """,
            in: database)
    }

    private static func execute(_ statement: String, in database: OpaquePointer?) throws {
        guard sqlite3_exec(database, statement, nil, nil, nil) == SQLITE_OK else {
            throw AgentSnapshotFixtureError.sqlite
        }
    }

    private static func date(_ value: String) throws -> Date {
        guard let date = ISO8601DateFormatter().date(from: value) else {
            throw AgentSnapshotFixtureError.date
        }
        return date
    }

    private static func timestamp(_ date: Date) -> String {
        ISO8601DateFormatter().string(from: date)
    }
}

private struct FixedTokenReader: TokenReader {
    let name: String
    let usage: RawTokenUsage

    func readUsage(from _: Date, to _: Date) async throws -> RawTokenUsage {
        usage
    }
}

private enum AgentSnapshotFixtureError: Error {
    case date
    case sqlite
}
