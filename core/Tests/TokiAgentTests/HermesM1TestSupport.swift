import Foundation
import TokiDurableStorage
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

/// Synthetic fixtures for the existing Toki Hermes schema; no personal databases or credentials.
struct HermesM1Fixture {
    let root: URL
    let now = Date(timeIntervalSince1970: 1_780_000_000)

    init() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("TokiHermesM1-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
    }

    var home: URL {
        root.appendingPathComponent("home", isDirectory: true)
    }

    var hermesHome: URL {
        home.appendingPathComponent(".hermes", isDirectory: true)
    }

    var start: Date {
        now.addingTimeInterval(-3600)
    }

    var end: Date {
        now.addingTimeInterval(3600)
    }

    var activityAt: Date {
        now.addingTimeInterval(-120)
    }

    var environment: [String: String] {
        [
            "XDG_CONFIG_HOME": root.appendingPathComponent("config").path,
            "XDG_DATA_HOME": root.appendingPathComponent("data").path,
            "XDG_STATE_HOME": root.appendingPathComponent("state").path,
        ]
    }

    func database(_ profile: String? = nil) -> URL {
        (profile.map { hermesHome.appendingPathComponent("profiles/\($0)") } ?? hermesHome)
            .appendingPathComponent("state.db")
    }

    func ledgerDirectory(_ scope: LocalUsageCacheScope = .application) -> URL {
        LocalUsageReaderPaths(homeDirectory: home, environment: environment)
            .cacheDirectory(for: scope).appendingPathComponent("hermes-profile-ledgers")
    }

    func ledgerURL(for database: URL? = nil, scope: LocalUsageCacheScope = .application) -> URL {
        guard let database else {
            return hermesUsageLedgerURL(
                paths: LocalUsageReaderPaths(homeDirectory: home, environment: environment), scope: scope)
        }
        // The candidate's existing flat ledger layout is a compatibility fixture.
        let identifier = SnapshotCipher.digest(
            "toki.hermes.profile-ledger.v1:\(database.resolvingSymlinksInPath().standardizedFileURL.path)")
        return ledgerDirectory(scope).appendingPathComponent("hermes-usage-ledger-profile-\(identifier).json")
    }

    func reader(at selectedHome: URL? = nil, ledger: HermesUsageLedger? = nil) -> HermesReader {
        HermesReader(
            hermesHomeURL: selectedHome ?? hermesHome,
            includesProfiles: selectedHome == nil,
            usesLegacyDefaultLedger: selectedHome == nil,
            usageLedger: ledger ?? HermesUsageLedger(fileURL: ledgerURL()),
            profileLedgerDirectory: ledgerDirectory(),
            now: { [now] in now })
    }

    func registryReader(at selectedHome: URL? = nil) throws -> any TokenReader {
        var selectedEnvironment = environment
        selectedEnvironment["HERMES_HOME"] = selectedHome?.path
        return try XCTUnwrap(LocalUsageReaderRegistry.readers(home: home, environment: selectedEnvironment)
            .first { $0.name == HermesReader.sourceName })
    }

    func agentDescriptor() throws -> LocalUsageReaderDescriptor {
        try XCTUnwrap(LocalUsageReaderRegistry.agentDescriptors(home: home, environment: environment)
            .first { $0.name == HermesReader.sourceName })
    }

    func configuration() throws -> AgentConfiguration {
        try AgentConfiguration(bundle: AgentPairingBundle(
            hubURL: XCTUnwrap(URL(string: "https://hermes-fixture.example.test")),
            deviceID: "hermes-fixture", deviceName: "hermes-fixture",
            uploadToken: SnapshotCipher.randomToken(), encryptionKey: SnapshotCipher.generateKey(),
            retentionDays: 7, syncIntervalSeconds: 900))
    }

    func seedLedger(at url: URL) async throws {
        // Deliberately identical synthetic keys model independently copied profile ledgers.
        try DurableFileIO.writePrivate(
            Data(Data(repeating: 7, count: 32).base64EncodedString().utf8),
            to: hermesUsageLedgerIdentifierKeyURL(for: url))
        try await HermesUsageLedger(fileURL: url).refresh(
            observations: [], observedAt: now.addingTimeInterval(-600))
    }

    func createDatabase(at url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try sql(at: url, """
        CREATE TABLE sessions (
            id TEXT PRIMARY KEY, started_at REAL NOT NULL, model TEXT,
            cwd TEXT, git_repo_root TEXT, input_tokens INTEGER, output_tokens INTEGER,
            cache_read_tokens INTEGER, cache_write_tokens INTEGER, reasoning_tokens INTEGER,
            estimated_cost_usd REAL, actual_cost_usd REAL
        );
        CREATE TABLE messages (session_id TEXT, timestamp REAL);
        """)
    }

    func insert(at url: URL, tokens: Int, model: String = "fixture-model", id: String = "shared-session") throws {
        // Callers supply only literal synthetic values.
        try sql(at: url, """
        INSERT INTO sessions VALUES (
            '\(id)', \(activityAt.timeIntervalSince1970), '\(model)', '', '',
            \(tokens), 2, 3, 4, 5, 0, 0.25
        );
        """)
    }

    func sql(at url: URL, _ sql: String) throws {
        let database = try open(at: url)
        defer { sqlite3_close(database) }
        try execute(sql, in: database)
    }

    func open(at url: URL) throws -> OpaquePointer {
        var database: OpaquePointer?
        let status = sqlite3_open(url.path, &database)
        guard status == SQLITE_OK, let database else {
            sqlite3_close(database)
            throw HermesM1FixtureError.sqlite(status)
        }
        return database
    }

    func execute(_ sql: String, in database: OpaquePointer) throws {
        let status = sqlite3_exec(database, sql, nil, nil, nil)
        guard status == SQLITE_OK else { throw HermesM1FixtureError.sqlite(status) }
    }

    func remove() {
        try? FileManager.default.removeItem(at: root)
    }
}

enum HermesM1FixtureError: Error {
    case sqlite(Int32)
}

final class HermesM1Clock: @unchecked Sendable {
    private let lock = NSLock()
    private let dates: [Date]
    private var index = 0

    init(_ dates: [Date]) {
        self.dates = dates
    }

    func next() -> Date {
        lock.lock()
        defer { lock.unlock() }
        let date = dates[min(index, dates.count - 1)]
        index += 1
        return date
    }
}
