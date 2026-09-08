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

final class HermesProfileConsumerTests: XCTestCase {
    func test_identicalProfileSessionsKeepIndependentAttributionAndSnapshotWorkTime() async throws {
        let fixture = try HermesM1Fixture()
        defer { fixture.remove() }
        for profile in ["first", "second"] {
            let database = fixture.database(profile)
            try fixture.createDatabase(at: database)
            try await fixture.seedLedger(at: fixture.ledgerURL(for: database))
            try fixture.insert(at: database, tokens: 10)
        }
        let reader = fixture.reader()
        let usage = try await reader.readUsage(from: fixture.start, to: fixture.end)
        let restarted = try await fixture.reader().readUsage(from: fixture.start, to: fixture.end)
        let identities = Set(usage.tokenEvents.compactMap { $0.attribution?.sessionID })
        XCTAssertEqual(identities.count, 2)
        XCTAssertEqual(Set(restarted.tokenEvents.compactMap { $0.attribution?.sessionID }), identities)
        XCTAssertTrue(identities.allSatisfy { SnapshotCipher.isSHA256Digest($0) })
        XCTAssertEqual(usage.inputTokens, 20)
        XCTAssertEqual(usage.outputTokens, 4)
        XCTAssertEqual(usage.cacheReadTokens, 6)
        XCTAssertEqual(usage.cacheWriteTokens, 8)
        XCTAssertEqual(usage.reasoningTokens, 10)
        XCTAssertEqual(usage.totalTokens, 48)
        XCTAssertEqual(usage.cost, 0.5, accuracy: 0.000_001)
        XCTAssertEqual(usage.perModel["fixture-model"]?.totalTokens, 48)
        XCTAssertEqual(usage.workTime.agentSeconds, 60)
        XCTAssertEqual(usage.workTime.wallClockSeconds, 30)
        XCTAssertEqual(usage.workTime.activeStreamCount, 2)
        XCTAssertEqual(usage.workTime.maxConcurrentStreams, 2)
        XCTAssertEqual(usage.perModel["fixture-model"]?.activeSeconds, 60)

        let configuration = try fixture.configuration()
        let builder = AgentSnapshotBuilder(
            home: fixture.home,
            environment: fixture.environment,
            readerDescriptors: [LocalUsageReaderDescriptor(
                reader: reader, sourceLocations: [])])
        let snapshot = try await builder.build(configuration: configuration, now: fixture.now)
        XCTAssertEqual(snapshot.tokenEvents.count, 2)
        XCTAssertEqual(snapshot.activityEvents.count, 2)
        XCTAssertEqual(Set(snapshot.activityEvents.map(\.streamID)).count, 2)
        let estimate = ActivityTimeEstimator.estimate(events: snapshot.activityEvents.map {
            ActivityTimeEvent(streamID: $0.streamID, timestamp: $0.timestamp, key: $0.model)
        })
        XCTAssertEqual(estimate.totalSeconds, 60)
        XCTAssertEqual(estimate.wallClockSeconds, 30)
        XCTAssertEqual(snapshot.tokenEvents.reduce(0) { $0 + $1.inputTokens }, 20)
        let encoded = try XCTUnwrap(String(data: TokiSyncCoding.makeEncoder().encode(snapshot), encoding: .utf8))
        XCTAssertFalse(encoded.contains(fixture.root.path))
        XCTAssertFalse(encoded.contains("shared-session"))
        XCTAssertFalse(encoded.contains("profiles/first"))
    }

    func test_partialCoverageKeepsSuccessfulCountAndSnapshotRejectsIncompleteCollection() async throws {
        let fixture = try HermesM1Fixture()
        defer { fixture.remove() }
        let healthy = fixture.database("healthy")
        try fixture.createDatabase(at: healthy)
        try await fixture.seedLedger(at: fixture.ledgerURL(for: healthy))
        try await fixture.seedLedger(at: fixture.ledgerURL(for: healthy, scope: .agent))
        try fixture.insert(at: healthy, tokens: 12)
        try fixture.sql(at: healthy, """
        CREATE TABLE session_model_usage (
            session_id TEXT, model TEXT, task TEXT, api_call_count INTEGER,
            input_tokens INTEGER, output_tokens INTEGER, cache_read_tokens INTEGER,
            cache_write_tokens INTEGER, reasoning_tokens INTEGER,
            estimated_cost_usd REAL, actual_cost_usd REAL
        );
        INSERT INTO session_model_usage VALUES ('shared-session', 'fixture-model', '', 3, 0, 0, 0, 0, 0, 0, 0);
        """)
        let corrupt = fixture.database("corrupt")
        try FileManager.default.createDirectory(
            at: corrupt.deletingLastPathComponent(),
            withIntermediateDirectories: true)
        try Data("synthetic invalid sqlite".utf8).write(to: corrupt)

        let usage = try await fixture.registryReader().readUsage(from: fixture.start, to: fixture.end)
        XCTAssertEqual(usage.inputTokens, 12)
        XCTAssertEqual(usage.supplemental.first { $0.id == "hermes-profile-read-errors" }?.value, 1)
        do {
            let coverage = try fixture.reader().coverageStatus()
            XCTAssertEqual(coverage.unmeteredMainAPICallCount, 3)
            // Source compatible with the candidate: partial coverage must differ from clean coverage.
            XCTAssertNotEqual(coverage, HermesUsageCoverageStatus(unmeteredMainAPICallCount: 3))
        } catch {
            XCTFail("Successful coverage must survive a corrupt sibling")
        }

        let builder = try AgentSnapshotBuilder(
            home: fixture.home,
            environment: fixture.environment,
            readerDescriptors: [fixture.agentDescriptor()])
        do {
            _ = try await builder.build(configuration: fixture.configuration(), now: fixture.now)
            XCTFail("A partial profile read must not publish an apparently complete snapshot")
        } catch let AgentSnapshotBuilderError.readerFailed(source) {
            XCTAssertEqual(source, HermesReader.sourceName)
        }
    }

    func test_unrecognizedOnlyDatabaseFailsUsageAndCoverage() async throws {
        let fixture = try HermesM1Fixture()
        defer { fixture.remove() }
        let database = fixture.database("unknown")
        try FileManager.default.createDirectory(
            at: database.deletingLastPathComponent(),
            withIntermediateDirectories: true)
        try fixture.sql(at: database, "CREATE TABLE unrelated (value INTEGER)")
        do {
            _ = try await fixture.reader().readUsage(from: fixture.start, to: fixture.end)
            XCTFail("An unrecognized schema is not empty usage")
        } catch {}
        XCTAssertThrowsError(try fixture.reader().coverageStatus())
    }

    func test_runtimeProfileAndWALChangesInvalidateExistingAgentSignature() async throws {
        let fixture = try HermesM1Fixture()
        defer { fixture.remove() }
        let builder = try AgentSnapshotBuilder(
            home: fixture.home,
            environment: fixture.environment,
            readerDescriptors: [fixture.agentDescriptor()])
        let configuration = try fixture.configuration()
        let initial = try await builder.sourceSignature(configuration: configuration, now: fixture.now)
        let databaseURL = fixture.database("runtime")
        try fixture.createDatabase(at: databaseURL)
        try await fixture.seedLedger(at: fixture.ledgerURL(for: databaseURL, scope: .agent))
        let database = try fixture.open(at: databaseURL)
        defer { sqlite3_close(database) }
        try fixture.execute("PRAGMA journal_mode = WAL; PRAGMA wal_autocheckpoint = 0", in: database)
        // An idle handle does not prevent a closing writer from checkpointing on system SQLite.
        // Pin a read snapshot so the regression's mutation is genuinely WAL-only.
        try fixture.execute("BEGIN DEFERRED TRANSACTION; SELECT COUNT(*) FROM sessions", in: database)
        defer { _ = sqlite3_exec(database, "ROLLBACK", nil, nil, nil) }
        let afterCreation = try await builder.sourceSignature(configuration: configuration, now: fixture.now)
        XCTAssertNotEqual(initial, afterCreation)
        let databaseBytes = try Data(contentsOf: databaseURL)
        try fixture.insert(at: databaseURL, tokens: 21)
        XCTAssertEqual(try Data(contentsOf: databaseURL), databaseBytes, "The regression must be WAL-only")
        let afterWAL = try await builder.sourceSignature(configuration: configuration, now: fixture.now)
        XCTAssertNotEqual(afterCreation, afterWAL)
        let snapshot = try await builder.build(configuration: configuration, now: fixture.now)
        XCTAssertEqual(snapshot.tokenEvents.reduce(0) { $0 + $1.inputTokens }, 21)
        XCTAssertEqual(snapshot.activityEvents.count, 1)
        let stable = try await builder.sourceSignature(configuration: configuration, now: fixture.now)
        let repeated = try await builder.sourceSignature(configuration: configuration, now: fixture.now)
        XCTAssertEqual(stable, repeated)
    }

    func test_profileModelTasksConserveEveryTokenBucketAndReportedCost() async throws {
        let fixture = try HermesM1Fixture()
        defer { fixture.remove() }
        for profile in ["one", "two"] {
            let database = fixture.database(profile)
            try fixture.createDatabase(at: database)
            try await fixture.seedLedger(at: fixture.ledgerURL(for: database))
            try fixture.insert(at: database, tokens: 10)
            try fixture.sql(at: database, """
            CREATE TABLE session_model_usage (
                session_id TEXT, model TEXT, task TEXT, api_call_count INTEGER,
                input_tokens INTEGER, output_tokens INTEGER, cache_read_tokens INTEGER,
                cache_write_tokens INTEGER, reasoning_tokens INTEGER,
                estimated_cost_usd REAL, actual_cost_usd REAL
            );
            INSERT INTO session_model_usage VALUES ('shared-session', 'main-model', '', 1, 6, 2, 3, 0, 0, 0, 0.15);
            INSERT INTO session_model_usage VALUES (
                'shared-session', 'task-model', 'summary', 1, 4, 0, 0, 4, 5, 0, 0.10);
            """)
        }
        let usage = try await fixture.reader().readUsage(from: fixture.start, to: fixture.end)
        XCTAssertEqual(usage.inputTokens, 20)
        XCTAssertEqual(usage.outputTokens, 4)
        XCTAssertEqual(usage.cacheReadTokens, 6)
        XCTAssertEqual(usage.cacheWriteTokens, 8)
        XCTAssertEqual(usage.reasoningTokens, 10)
        XCTAssertEqual(usage.totalTokens, 48)
        XCTAssertEqual(usage.perModel["main-model"]?.totalTokens, 22)
        XCTAssertEqual(usage.perModel["task-model"]?.totalTokens, 26)
        XCTAssertEqual(try XCTUnwrap(usage.perModel["main-model"]?.cost), 0.3, accuracy: 0.000_001)
        XCTAssertEqual(try XCTUnwrap(usage.perModel["task-model"]?.cost), 0.2, accuracy: 0.000_001)
        XCTAssertEqual(usage.cost, 0.5, accuracy: 0.000_001)
        XCTAssertEqual(usage.tokenEvents.reduce(0) { $0 + $1.totalTokens }, 48)
        XCTAssertEqual(usage.tokenEvents.reduce(0) { $0 + $1.cost }, usage.cost, accuracy: 0.000_001)
        XCTAssertEqual(usage.workTime.activeStreamCount, 2)
        XCTAssertEqual(usage.workTime.agentSeconds, 60)
    }
}
