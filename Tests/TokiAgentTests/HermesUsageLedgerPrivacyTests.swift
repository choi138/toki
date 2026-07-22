import Foundation
import TokiDurableStorage
import TokiSyncProtocol
import XCTest
#if os(Linux)
    import CSQLite
#else
    import SQLite3
#endif
@testable import TokiAgentCore
@testable import TokiUsageReaders

final class HermesUsageLedgerPrivacyTests: XCTestCase {
    func test_freshLedgerSerializationOmitsSensitiveSourceIdentifiers() async throws {
        let fixture = try HermesPrivacyFixture()
        defer { fixture.remove() }
        let sentinel = "TOKI_PRIVACY_SENTINEL"
        let ledger = HermesUsageLedger(fileURL: fixture.ledgerURL)
        let startedAt = Date(timeIntervalSince1970: 1_780_000_000)

        try await ledger.refresh(
            observations: [HermesSessionObservation(
                sessionID: "raw-session-\(sentinel)-thread-1528930867106418749",
                startedAt: startedAt,
                earliestActivityAt: startedAt,
                latestActivityAt: startedAt,
                model: "gpt-test",
                counters: HermesTokenCounters(
                    inputTokens: 10,
                    outputTokens: 2,
                    cacheReadTokens: 3,
                    cacheWriteTokens: 0,
                    reasoningTokens: 1),
                cost: 0.25,
                projectName: "/Users/\(sentinel)/secret-project",
                attributionQuality: .exact)],
            observedAt: startedAt.addingTimeInterval(60))

        let serialized = try String(contentsOf: fixture.ledgerURL, encoding: .utf8)
        XCTAssertFalse(serialized.contains(sentinel))
        XCTAssertFalse(serialized.contains("1528930867106418749"))
        XCTAssertFalse(serialized.contains("raw-session"))
        XCTAssertFalse(serialized.contains("secret-project"))
        XCTAssertFalse(serialized.contains("projectName"))
        XCTAssertFalse(serialized.contains("identifierKey"))
    }

    func test_v2MigrationIsDryRunByDefaultAndApplyIsAtomicAndIdempotent() async throws {
        let fixture = try HermesPrivacyFixture()
        defer { fixture.remove() }
        let sentinel = "TOKI_LEGACY_PRIVACY_SENTINEL"
        let identifierKey = SnapshotCipher.generateKey()
        let identifier = String(repeating: "a", count: 32)
        let timestamp = Date(timeIntervalSince1970: 1_780_000_000)
        let original = try makeV2LedgerData(
            identifierKey: identifierKey,
            identifier: identifier,
            timestamp: timestamp,
            sentinel: sentinel)
        try writePrivateTestData(original, to: fixture.ledgerURL)

        do {
            _ = try await HermesUsageLedger(fileURL: fixture.ledgerURL).status()
            XCTFail("Legacy ledger must require explicit migration")
        } catch HermesUsageLedgerError.migrationRequired {}

        let dryRun = try HermesUsageLedgerMigrator.migrate(fileURL: fixture.ledgerURL)
        XCTAssertEqual(dryRun, .migrationRequired)
        XCTAssertEqual(try Data(contentsOf: fixture.ledgerURL), original)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.backupURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.keyURL.path))

        let applied = try HermesUsageLedgerMigrator.migrate(fileURL: fixture.ledgerURL, mode: .apply)
        XCTAssertEqual(applied, .migrated)
        let migrated = try Data(contentsOf: fixture.ledgerURL)
        let serialized = try XCTUnwrap(String(data: migrated, encoding: .utf8))
        XCTAssertFalse(serialized.contains(sentinel))
        XCTAssertFalse(serialized.contains(identifierKey))
        XCTAssertFalse(serialized.contains("projectName"))
        XCTAssertFalse(serialized.contains("identifierKey"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.backupURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.v1BackupURL.path))
        XCTAssertEqual(try Data(contentsOf: fixture.keyURL), Data(identifierKey.utf8))
        XCTAssertEqual(try permissions(at: fixture.keyURL), 0o600)
        XCTAssertEqual(try permissions(at: fixture.ledgerURL), 0o600)

        let ledger = HermesUsageLedger(fileURL: fixture.ledgerURL)
        let events = try await ledger.events(
            from: timestamp.addingTimeInterval(-1),
            to: timestamp.addingTimeInterval(1))
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events.first?.sessionIdentifier, identifier)
        XCTAssertEqual(events.first?.timestamp, timestamp)
        XCTAssertEqual(events.first?.model, "gpt-test")
        XCTAssertEqual(events.first?.counters.totalTokens, 16)
        XCTAssertEqual(events.first?.cost, 0.25)
        let privateDocument = try JSONDecoder().decode(HermesUsageLedgerPrivateDocument.self, from: migrated)
        XCTAssertEqual(privateDocument.baselines[identifier]?.counters.totalTokens, 16)
        XCTAssertEqual(privateDocument.events.first?.sessionIdentifier, identifier)

        let beforeSecondApply = try Data(contentsOf: fixture.ledgerURL)
        let secondApply = try HermesUsageLedgerMigrator.migrate(fileURL: fixture.ledgerURL, mode: .apply)
        XCTAssertEqual(secondApply, .notRequired)
        XCTAssertEqual(try Data(contentsOf: fixture.ledgerURL), beforeSecondApply)
    }

    func test_mergeAndReplayPreserveAccountingWithoutPersistingSensitiveMetadata() async throws {
        let fixture = try HermesPrivacyFixture()
        defer { fixture.remove() }
        let sentinel = "TOKI_MERGE_PRIVACY_SENTINEL"
        let startedAt = Date(timeIntervalSince1970: 1_780_000_000)
        let observedAt = startedAt.addingTimeInterval(60)
        let ledger = HermesUsageLedger(fileURL: fixture.ledgerURL)

        func observation(inputTokens: Int) -> HermesSessionObservation {
            HermesSessionObservation(
                sessionID: "raw-session-\(sentinel)",
                startedAt: startedAt,
                earliestActivityAt: nil,
                latestActivityAt: startedAt,
                model: "gpt-test",
                counters: HermesTokenCounters(
                    inputTokens: inputTokens,
                    outputTokens: 0,
                    cacheReadTokens: 0,
                    cacheWriteTokens: 0,
                    reasoningTokens: 0),
                cost: Double(inputTokens) / 100,
                projectName: "/Users/private/\(sentinel)",
                attributionQuality: .exact)
        }

        try await ledger.refresh(observations: [observation(inputTokens: 10)], observedAt: startedAt)
        try await ledger.refresh(observations: [observation(inputTokens: 20)], observedAt: observedAt)
        try await ledger.refresh(observations: [observation(inputTokens: 30)], observedAt: observedAt)
        let merged = try await ledger.events(
            from: startedAt.addingTimeInterval(-1),
            to: observedAt.addingTimeInterval(1))
        XCTAssertEqual(merged.count, 1)
        XCTAssertEqual(merged.first?.counters.totalTokens, 20)
        XCTAssertEqual(merged.first?.cost ?? -1, 0.2, accuracy: 0.000_001)

        let beforeReplay = try Data(contentsOf: fixture.ledgerURL)
        let restarted = HermesUsageLedger(fileURL: fixture.ledgerURL)
        try await restarted.refresh(observations: [observation(inputTokens: 30)], observedAt: observedAt)
        let afterReplay = try Data(contentsOf: fixture.ledgerURL)
        XCTAssertEqual(afterReplay, beforeReplay)
        assertSerializedLedgerIsPrivate(
            afterReplay,
            forbidden: [sentinel, "raw-session", "projectName", "identifierKey"])
    }

    func test_freshHermesDatabaseCollectionOmitsRawDatabaseIdentifiersFromLedger() async throws {
        let fixture = try HermesPrivacyFixture()
        defer { fixture.remove() }
        let sentinel = "TOKI_DB_PRIVACY_SENTINEL"
        let databaseURL = fixture.directory.appendingPathComponent("state.db")
        try createHermesPrivacyDatabase(at: databaseURL, sentinel: sentinel)
        let now = Date(timeIntervalSince1970: 1_780_000_060)
        let ledger = HermesUsageLedger(fileURL: fixture.ledgerURL)
        let reader = HermesReader(
            dbPathOverride: databaseURL.path,
            usageLedger: ledger,
            now: { now })

        _ = try await reader.readUsage(
            from: now.addingTimeInterval(-3600),
            to: now.addingTimeInterval(1))

        let serialized = try Data(contentsOf: fixture.ledgerURL)
        assertSerializedLedgerIsPrivate(
            serialized,
            forbidden: [sentinel, "raw-session", "/Users/private", "projectName", "identifierKey"])
    }
}

extension HermesUsageLedgerPrivacyTests {
    func test_applicationLedgerAutomaticallyMigratesV2AndRemovesLegacyBackups() async throws {
        let fixture = try HermesPrivacyFixture()
        defer { fixture.remove() }
        let sentinel = "TOKI_AUTOMATIC_MIGRATION_SENTINEL"
        let identifierKey = SnapshotCipher.generateKey()
        let timestamp = Date(timeIntervalSince1970: 1_780_000_000)
        let original = try makeV2LedgerData(
            identifierKey: identifierKey,
            identifier: String(repeating: "d", count: 32),
            timestamp: timestamp,
            sentinel: sentinel)
        try writePrivateTestData(original, to: fixture.ledgerURL)
        try writePrivateTestData(original, to: fixture.backupURL)
        try writePrivateTestData(original, to: fixture.v1BackupURL)
        let ledger = HermesUsageLedger(
            fileURL: fixture.ledgerURL,
            automaticallyMigrateLegacy: true)

        let status = try await ledger.status()

        XCTAssertEqual(status.accurateSince, timestamp)
        try assertSerializedLedgerIsPrivate(
            Data(contentsOf: fixture.ledgerURL),
            forbidden: [sentinel, identifierKey, "projectName", "identifierKey"])
        XCTAssertEqual(try Data(contentsOf: fixture.keyURL), Data(identifierKey.utf8))
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.backupURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.v1BackupURL.path))
    }

    func test_keyDurabilityFailureDoesNotAdoptUnwrittenLedger() async throws {
        let fixture = try HermesPrivacyFixture()
        defer { fixture.remove() }
        let writer = CommittedKeyFailureWriter(keyURL: fixture.keyURL)
        let ledger = HermesUsageLedger(
            fileURL: fixture.ledgerURL,
            privateFileWriter: writer.write)
        let timestamp = Date(timeIntervalSince1970: 1_780_000_000)
        let observation = HermesSessionObservation(
            sessionID: "key-failure-session",
            startedAt: timestamp,
            earliestActivityAt: timestamp,
            latestActivityAt: timestamp,
            model: "gpt-test",
            counters: HermesTokenCounters(
                inputTokens: 10,
                outputTokens: 0,
                cacheReadTokens: 0,
                cacheWriteTokens: 0,
                reasoningTokens: 0),
            cost: 0,
            projectName: nil,
            attributionQuality: .unknown)

        do {
            try await ledger.refresh(observations: [observation], observedAt: timestamp)
            XCTFail("Committed key durability failure must be reported")
        } catch HermesUsageLedgerError.durabilityNotConfirmed {}

        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.keyURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.ledgerURL.path))
        let statusAfterFailure = try await ledger.status()
        XCTAssertNil(statusAfterFailure.accurateSince)

        try await ledger.refresh(observations: [observation], observedAt: timestamp)

        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.ledgerURL.path))
        let persisted = try JSONDecoder().decode(
            HermesUsageLedgerPrivateDocument.self,
            from: Data(contentsOf: fixture.ledgerURL))
        XCTAssertEqual(persisted.schemaVersion, 3)
    }

    func test_v1MigrationPreservesAccountingAsUnattributedAndRemovesSensitiveMetadata() async throws {
        let fixture = try HermesPrivacyFixture()
        defer { fixture.remove() }
        let sentinel = "TOKI_V1_PRIVACY_SENTINEL"
        let identifierKey = SnapshotCipher.generateKey()
        let identifier = String(repeating: "c", count: 32)
        let timestamp = Date(timeIntervalSince1970: 1_780_000_000)
        let original = try makeV1LedgerData(
            identifierKey: identifierKey,
            identifier: identifier,
            timestamp: timestamp,
            sentinel: sentinel)
        try writePrivateTestData(original, to: fixture.ledgerURL)

        XCTAssertEqual(try HermesUsageLedgerMigrator.migrate(fileURL: fixture.ledgerURL), .migrationRequired)
        XCTAssertEqual(try Data(contentsOf: fixture.ledgerURL), original)
        XCTAssertEqual(
            try HermesUsageLedgerMigrator.migrate(fileURL: fixture.ledgerURL, mode: .apply),
            .migrated)

        let migrated = try Data(contentsOf: fixture.ledgerURL)
        assertSerializedLedgerIsPrivate(
            migrated,
            forbidden: [sentinel, identifierKey, "projectName", "identifierKey"])
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.v1BackupURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.backupURL.path))
        let ledger = HermesUsageLedger(fileURL: fixture.ledgerURL)
        let status = try await ledger.status()
        let events = try await ledger.events(
            from: timestamp.addingTimeInterval(-1),
            to: timestamp.addingTimeInterval(1))
        XCTAssertEqual(status.unattributedTokens, 16)
        XCTAssertTrue(events.isEmpty)
        XCTAssertEqual(
            try HermesUsageLedgerMigrator.migrate(fileURL: fixture.ledgerURL, mode: .apply),
            .notRequired)
    }

    func test_agentMigrationCommandUsesDryRunUnlessApplyIsExplicit() throws {
        let fixture = try HermesPrivacyFixture()
        defer { fixture.remove() }
        let paths = AgentPaths(
            environment: [
                "XDG_CONFIG_HOME": fixture.directory.appendingPathComponent("config").path,
                "XDG_STATE_HOME": fixture.directory.appendingPathComponent("state").path,
                "XDG_DATA_HOME": fixture.directory.appendingPathComponent("data").path,
            ],
            home: fixture.directory)
        try paths.prepare()
        let ledgerURL = paths.stateDirectory.appendingPathComponent("hermes-usage-ledger.json")
        let original = try makeV2LedgerData(
            identifierKey: SnapshotCipher.generateKey(),
            identifier: String(repeating: "b", count: 32),
            timestamp: Date(timeIntervalSince1970: 1_780_000_000),
            sentinel: "TOKI_COMMAND_SENTINEL")
        try writePrivateTestData(original, to: ledgerURL)

        XCTAssertEqual(
            try TokiAgentCommand.migrateHermesLedger(arguments: [], paths: paths),
            .migrationRequired)
        XCTAssertEqual(try Data(contentsOf: ledgerURL), original)
        XCTAssertEqual(
            try TokiAgentCommand.migrateHermesLedger(arguments: ["--apply"], paths: paths),
            .migrated)
        do {
            _ = try TokiAgentCommand.migrateHermesLedger(
                arguments: ["--apply", "TOKI_SECRET_ARGUMENT"],
                paths: paths)
            XCTFail("Unexpected migration argument must fail")
        } catch AgentCommandError.invalidMigrationArguments {
            XCTAssertFalse(
                AgentCommandError.invalidMigrationArguments.localizedDescription.contains("TOKI_SECRET_ARGUMENT"))
        }
    }
}

private struct HermesPrivacyFixture {
    let directory: URL
    let ledgerURL: URL

    init() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        ledgerURL = directory.appendingPathComponent("hermes-usage-ledger.json")
    }

    var backupURL: URL {
        ledgerURL.appendingPathExtension("v2.backup")
    }

    var v1BackupURL: URL {
        ledgerURL.appendingPathExtension("v1.backup")
    }

    var keyURL: URL {
        ledgerURL.deletingPathExtension().appendingPathExtension("key")
    }

    func remove() {
        try? FileManager.default.removeItem(at: directory)
    }
}

private func makeV2LedgerData(
    identifierKey: String,
    identifier: String,
    timestamp: Date,
    sentinel: String) throws -> Data {
    let counters: [String: Any] = [
        "inputTokens": 10,
        "outputTokens": 2,
        "cacheReadTokens": 3,
        "cacheWriteTokens": 0,
        "reasoningTokens": 1,
    ]
    let baseline: [String: Any] = [
        "startedAt": timestamp.timeIntervalSinceReferenceDate,
        "lastActivityAt": timestamp.timeIntervalSinceReferenceDate,
        "lastObservedAt": timestamp.timeIntervalSinceReferenceDate,
        "model": "gpt-test",
        "counters": counters,
        "cost": 0.25,
        "projectName": "/Users/\(sentinel)/private-project",
        "attributionQuality": "exact",
    ]
    let event: [String: Any] = [
        "sessionIdentifier": identifier,
        "timestamp": timestamp.timeIntervalSinceReferenceDate,
        "model": "gpt-test",
        "counters": counters,
        "cost": 0.25,
        "projectName": "thread-1528930867106418749-\(sentinel)",
        "attributionQuality": "exact",
    ]
    return try JSONSerialization.data(
        withJSONObject: [
            "schemaVersion": 2,
            "identifierKey": identifierKey,
            "accurateSince": timestamp.timeIntervalSinceReferenceDate,
            "lastSuccessfulObservationAt": timestamp.timeIntervalSinceReferenceDate,
            "baselines": [identifier: baseline],
            "unattributed": [:],
            "events": [event],
        ],
        options: [.sortedKeys])
}

private func makeV1LedgerData(
    identifierKey: String,
    identifier: String,
    timestamp: Date,
    sentinel: String) throws -> Data {
    let v2 = try XCTUnwrap(
        JSONSerialization.jsonObject(with: makeV2LedgerData(
            identifierKey: identifierKey,
            identifier: identifier,
            timestamp: timestamp,
            sentinel: sentinel)) as? [String: Any])
    return try JSONSerialization.data(
        withJSONObject: [
            "schemaVersion": 1,
            "identifierKey": identifierKey,
            "baselines": v2["baselines"] as Any,
            "events": v2["events"] as Any,
        ],
        options: [.sortedKeys])
}

private func assertSerializedLedgerIsPrivate(
    _ data: Data,
    forbidden values: [String],
    file: StaticString = #filePath,
    line: UInt = #line) {
    guard let serialized = String(bytes: data, encoding: .utf8) else {
        XCTFail("serialized ledger is not valid UTF-8", file: file, line: line)
        return
    }
    for value in values {
        XCTAssertFalse(
            serialized.contains(value),
            "serialized ledger contains forbidden value",
            file: file,
            line: line)
    }
}

private func createHermesPrivacyDatabase(at url: URL, sentinel: String) throws {
    var database: OpaquePointer?
    guard sqlite3_open(url.path, &database) == SQLITE_OK else {
        sqlite3_close(database)
        throw HermesPrivacyDatabaseError.open
    }
    defer { sqlite3_close(database) }
    let sql = """
    CREATE TABLE sessions (
        id TEXT PRIMARY KEY, started_at REAL, model TEXT, cwd TEXT, git_repo_root TEXT,
        input_tokens INTEGER, output_tokens INTEGER, cache_read_tokens INTEGER,
        cache_write_tokens INTEGER, reasoning_tokens INTEGER,
        estimated_cost_usd REAL, actual_cost_usd REAL
    );
    INSERT INTO sessions VALUES (
        'raw-session-\(sentinel)', 1780000000, 'gpt-test', '/Users/private/\(sentinel)', '',
        10, 2, 3, 0, 1, 0.25, 0.25
    );
    """
    guard sqlite3_exec(database, sql, nil, nil, nil) == SQLITE_OK else {
        throw HermesPrivacyDatabaseError.statement
    }
}

private enum HermesPrivacyDatabaseError: Error {
    case open
    case statement
}

private final class CommittedKeyFailureWriter {
    private let keyURL: URL
    private var shouldFailKeyWrite = true

    init(keyURL: URL) {
        self.keyURL = keyURL
    }

    func write(_ data: Data, _ url: URL) throws {
        try DurableFileIO.writePrivate(data, to: url)
        if url == keyURL, shouldFailKeyWrite {
            shouldFailKeyWrite = false
            throw DurableFileIOError.replacementCommittedDirectorySyncFailed
        }
    }
}

private func writePrivateTestData(_ data: Data, to url: URL) throws {
    try data.write(to: url)
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
}

private func permissions(at url: URL) throws -> Int {
    let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
    return (attributes[.posixPermissions] as? NSNumber)?.intValue ?? -1
}
