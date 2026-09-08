import Foundation
import TokiSyncProtocol
import XCTest
@testable import TokiAgentCore
@testable import TokiUsageReaders

final class SourceCoverageIntegrationTests: XCTestCase {
    func test_hermesLateSymlinkProfileTargetAndWALInvalidateWithoutMtimeCutoff() async throws {
        let fixture = try HermesM1Fixture()
        defer { fixture.remove() }
        let builder = AgentSnapshotBuilder(home: fixture.home, environment: fixture.environment)
        let before = try await signature(builder, fixture)
        let external = fixture.root.appendingPathComponent("selected/state.db")
        try fixture.createDatabase(at: external)
        let profile = fixture.hermesHome.appendingPathComponent("profiles/alias")
        try FileManager.default.createDirectory(
            at: profile.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(
            at: profile, withDestinationURL: external.deletingLastPathComponent())
        let added = try await signature(builder, fixture)
        XCTAssertNotEqual(before, added)
        // Metadata-only sidecar fixture; actual WAL coherence is covered by the Hermes lane.
        try Data("synthetic-wal".utf8).write(to: URL(fileURLWithPath: external.path + "-wal"))
        try oldDate(URL(fileURLWithPath: external.path + "-wal"))
        let wal = try await signature(builder, fixture)
        XCTAssertNotEqual(added, wal)
        try FileManager.default.removeItem(at: URL(fileURLWithPath: external.path + "-wal"))
        try fixture.sql(at: external, "CREATE TABLE extra (value INTEGER);")
        let changed = try await signature(builder, fixture)
        XCTAssertNotEqual(wal, changed)
        try FileManager.default.removeItem(at: profile)
        let removed = try await signature(builder, fixture)
        XCTAssertNotEqual(changed, removed)
    }

    func test_hermesRetainedLedgerAndKeyInvalidateAfterProfileRemovalAndRestart() async throws {
        let fixture = try HermesM1Fixture()
        defer { fixture.remove() }
        let database = fixture.database("named")
        try fixture.createDatabase(at: database)
        _ = try await fixture.agentDescriptor().reader.readUsage(from: fixture.start, to: fixture.end)
        try FileManager.default.removeItem(at: database.deletingLastPathComponent())
        let builder = AgentSnapshotBuilder(home: fixture.home, environment: fixture.environment)
        let before = try await signature(builder, fixture)
        let ledger = fixture.ledgerURL(for: database, scope: .agent)
        try oldDate(ledger)
        let edited = try await signature(builder, fixture)
        XCTAssertNotEqual(before, edited)
        try FileManager.default.removeItem(at: hermesUsageLedgerIdentifierKeyURL(for: ledger))
        let removedKey = try await signature(builder, fixture)
        XCTAssertNotEqual(edited, removedKey)
        let membership = try XCTUnwrap(FileManager.default.contentsOfDirectory(
            at: fixture.ledgerDirectory(.agent), includingPropertiesForKeys: nil)
            .first { $0.lastPathComponent.hasPrefix("hermes-profile-collection-") })
        try oldDate(membership)
        let changedMembership = try await signature(builder, fixture)
        XCTAssertNotEqual(removedKey, changedMembership)
        let unrelated = fixture.ledgerDirectory(.agent)
            .appendingPathComponent("hermes-usage-ledger-profile-unrelated.json")
        try Data("unrelated".utf8).write(to: unrelated)
        let afterUnrelated = try await signature(builder, fixture)
        XCTAssertEqual(changedMembership, afterUnrelated)
    }

    func test_openCodeLateChannelLegacyJSONAndExplicitAliasRetargetInvalidate() async throws {
        let fixture = try HermesM1Fixture()
        let code = try OpenCodeFixture()
        defer { fixture.remove()
            code.remove()
        }
        let selected = fixture.root.appendingPathComponent("selected.db")
        let first = try OpenCodeTestDatabase(at: code.root.appendingPathComponent("first.db"))
        let second = try OpenCodeTestDatabase(at: code.root.appendingPathComponent("second.db"))
        try FileManager.default.createSymbolicLink(at: selected, withDestinationURL: first.url)
        var environment = fixture.environment
        environment["OPENCODE_DB"] = selected.path
        let builder = AgentSnapshotBuilder(home: fixture.home, environment: environment)
        let before = try await signature(builder, fixture)
        let dataRoot = fixture.root.appendingPathComponent("data/opencode")
        let channel = try OpenCodeTestDatabase(at: dataRoot.appendingPathComponent("opencode-next.db"))
        try oldDate(channel.url)
        let added = try await signature(builder, fixture)
        XCTAssertNotEqual(before, added)
        let json = try code.writeJSON(code.payload(), root: dataRoot)
        try oldDate(json)
        let legacy = try await signature(builder, fixture)
        XCTAssertNotEqual(added, legacy)
        try FileManager.default.removeItem(at: selected)
        try FileManager.default.createSymbolicLink(at: selected, withDestinationURL: second.url)
        let retargeted = try await signature(builder, fixture)
        XCTAssertNotEqual(legacy, retargeted)
        try Data("wal-only".utf8).write(to: URL(fileURLWithPath: second.url.path + "-wal"))
        let wal = try await signature(builder, fixture)
        XCTAssertNotEqual(retargeted, wal)
    }

    func test_openClawOldArbitraryArchiveAndSQLiteSidecarInvalidate() async throws {
        let fixture = try HermesM1Fixture()
        defer { fixture.remove() }
        let builder = AgentSnapshotBuilder(home: fixture.home, environment: fixture.environment)
        let before = try await signature(builder, fixture)
        let archive = fixture.home.appendingPathComponent(".moltbot/agents/main/sessions/a.jsonl.reset.custom-suffix")
        try FileManager.default.createDirectory(
            at: archive.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(OpenClawFixture.event().utf8).write(to: archive)
        try oldDate(archive)
        let added = try await signature(builder, fixture)
        XCTAssertNotEqual(before, added)
        let database = archive.deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("agent/openclaw-agent.sqlite")
        try FileManager.default.createDirectory(
            at: database.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data().write(to: database)
        let db = try await signature(builder, fixture)
        XCTAssertNotEqual(added, db)
        try Data("sidecar".utf8).write(to: URL(fileURLWithPath: database.path + "-shm"))
        let sidecar = try await signature(builder, fixture)
        XCTAssertNotEqual(db, sidecar)
        try FileManager.default.removeItem(at: archive)
        let removed = try await signature(builder, fixture)
        XCTAssertNotEqual(sidecar, removed)
    }

    func test_dynamicCanonicalProfileMountIsValidatedAfterDiscovery() throws {
        let fixture = try HermesM1Fixture()
        defer { fixture.remove() }
        let database = fixture.root.appendingPathComponent("external/state.db")
        try fixture.createDatabase(at: database)
        let path = database.resolvingSymlinksInPath().standardizedFileURL.path
        var mountInfo = "100 1 8:1 /original \(path) ro - ext4 /dev/test rw"
        let builder = AgentSnapshotBuilder(
            home: fixture.home, environment: fixture.environment, sourceMountInfoProvider: { mountInfo })
        let profile = fixture.hermesHome.appendingPathComponent("profiles/new")
        try FileManager.default.createDirectory(
            at: profile.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(
            at: profile, withDestinationURL: database.deletingLastPathComponent())
        XCTAssertNoThrow(try builder.validateSourceMounts())
        mountInfo = "100 1 8:1 /original//deleted \(path) ro - ext4 /dev/test rw"
        XCTAssertThrowsError(try builder.validateSourceMounts())
    }

    func test_discoveryErrorsAreNotEmptySignatures() async throws {
        let fixture = try HermesM1Fixture()
        defer { fixture.remove() }
        let root = fixture.root.appendingPathComponent("data/opencode")
        try FileManager.default.createDirectory(at: root.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("not-a-directory".utf8).write(to: root)
        let builder = AgentSnapshotBuilder(home: fixture.home, environment: fixture.environment)
        do {
            _ = try await signature(builder, fixture)
            XCTFail("Discovery failure must propagate")
        } catch {}
        XCTAssertThrowsError(try builder.validateSourceMounts())
    }

    func test_changedCollectorInvalidatesOldSignatureOnceAndSurvivesRestart() async throws {
        let fixture = try HermesM1Fixture()
        defer { fixture.remove() }
        let canonicalHome = fixture.home.resolvingSymlinksInPath().standardizedFileURL
        let actual = try XCTUnwrap(LocalUsageReaderRegistry.agentDescriptors(
            home: canonicalHome, environment: fixture.environment).first { $0.name == "Claude Code" })
        // The old initializer has no revision. No new API is needed to compile this against baseline.
        let previous = LocalUsageReaderDescriptor(
            reader: actual.reader,
            sourceLocations: actual.sourceLocations.map {
                .directory($0.url.resolvingSymlinksInPath().standardizedFileURL, extensions: ["jsonl"])
            },
            sourceSignatureStrategy: actual.sourceSignatureStrategy)
        let old = AgentSnapshotBuilder(
            home: fixture.home, environment: fixture.environment, readerDescriptors: [previous])
        let current = AgentSnapshotBuilder(
            home: fixture.home, environment: fixture.environment, readerDescriptors: [actual])
        let restarted = AgentSnapshotBuilder(
            home: fixture.home, environment: fixture.environment, readerDescriptors: [actual])
        let oldSignature = try await signature(old, fixture)
        let newSignature = try await signature(current, fixture)
        let repeated = try await signature(current, fixture)
        let afterRestart = try await signature(restarted, fixture)
        XCTAssertNotEqual(oldSignature, newSignature)
        XCTAssertEqual(newSignature, repeated)
        XCTAssertEqual(newSignature, afterRestart)
    }

    func test_signatureCancellationPropagates() async throws {
        let fixture = try HermesM1Fixture()
        defer { fixture.remove() }
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            let builder = AgentSnapshotBuilder(home: fixture.home, environment: fixture.environment)
            return try await signature(builder, fixture)
        }
        do {
            _ = try await task.value
            XCTFail("Cancelled discovery must not produce an empty signature")
        } catch is CancellationError {} catch {
            XCTFail("Expected cancellation, received \(error)")
        }
    }
}

extension SourceCoverageIntegrationTests {
    func test_openCodeJournalOwningHardlinkInvalidatesSignatureOnEachWALCommit() async throws {
        let fixture = try HermesM1Fixture()
        let code = try OpenCodeFixture()
        defer { fixture.remove()
            code.remove()
        }
        let producer = fixture.root.appendingPathComponent("data/opencode/opencode-next.db")
        do { _ = try OpenCodeTestDatabase(at: producer) }
        let alias = producer.deletingLastPathComponent().appendingPathComponent("opencode.db")
        try FileManager.default.linkItem(at: producer, to: alias)
        let writer = try OpenCodeTestDatabase(at: producer, schema: "")
        try writer.execute("PRAGMA journal_mode=WAL; PRAGMA wal_autocheckpoint=0;")
        let pinned = try OpenCodeTestDatabase(at: producer, schema: "BEGIN; SELECT COUNT(*) FROM message;")
        let builder = AgentSnapshotBuilder(home: fixture.home, environment: fixture.environment)
        try writer.insert(code.payload())
        let checkpointed = try Data(contentsOf: producer)
        let first = try await signature(builder, fixture)
        try writer.insert(code.payload(id: "second"), id: "second")
        XCTAssertEqual(try Data(contentsOf: producer), checkpointed)
        let updated = try await signature(builder, fixture)
        XCTAssertNotEqual(first, updated)
        try pinned.execute("ROLLBACK;")
    }

    func test_hermesDiscoveryRejectsNonDirectoryProfilesAndBoundsAllEntries() async throws {
        let fixture = try HermesM1Fixture()
        defer { fixture.remove() }
        let profiles = fixture.hermesHome.appendingPathComponent("profiles")
        try FileManager.default.createDirectory(at: fixture.hermesHome, withIntermediateDirectories: true)
        try Data("invalid-profile-root".utf8).write(to: profiles)
        let builder = AgentSnapshotBuilder(home: fixture.home, environment: fixture.environment)
        do {
            _ = try await signature(builder, fixture)
            XCTFail("Invalid profile root must fail discovery")
        } catch {}
        try FileManager.default.removeItem(at: profiles)
        for index in 0...1024 {
            try FileManager.default.createDirectory(
                at: profiles.appendingPathComponent("empty-\(index)"), withIntermediateDirectories: true)
        }
        do {
            _ = try await signature(builder, fixture)
            XCTFail("Empty entries also consume the bounded profile discovery budget")
        } catch {}
    }

    func test_retargetedOpenCodeAliasRefreshesMountPaths() throws {
        let fixture = try HermesM1Fixture()
        let code = try OpenCodeFixture()
        defer { fixture.remove()
            code.remove()
        }
        let first = try OpenCodeTestDatabase(at: code.root.appendingPathComponent("first.db"))
        let second = try OpenCodeTestDatabase(at: code.root.appendingPathComponent("second.db"))
        let alias = fixture.root.appendingPathComponent("alias.db")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: first.url)
        var environment = fixture.environment
        environment["OPENCODE_DB"] = alias.path
        let canonical = second.url.resolvingSymlinksInPath().standardizedFileURL.path
        var mountInfo = "100 1 8:1 /original \(canonical) ro - ext4 /dev/test rw"
        let builder = AgentSnapshotBuilder(
            home: fixture.home, environment: environment, sourceMountInfoProvider: { mountInfo })
        XCTAssertNoThrow(try builder.validateSourceMounts())
        try FileManager.default.removeItem(at: alias)
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: second.url)
        XCTAssertNoThrow(try builder.validateSourceMounts())
        mountInfo = "100 1 8:1 /original//deleted \(canonical) ro - ext4 /dev/test rw"
        XCTAssertThrowsError(try builder.validateSourceMounts())
    }

    func test_openCodeSignatureEnforcesChannelDatabaseBudget() async throws {
        let fixture = try HermesM1Fixture()
        defer { fixture.remove() }
        let dataRoot = fixture.root.appendingPathComponent("data/opencode")
        try FileManager.default.createDirectory(at: dataRoot, withIntermediateDirectories: true)
        // Signature discovery inspects metadata only; 65 selected files exceed the 64 DB limit.
        for index in 0...64 {
            try Data().write(to: dataRoot.appendingPathComponent("opencode-channel-\(index).db"))
        }
        let builder = AgentSnapshotBuilder(home: fixture.home, environment: fixture.environment)
        do {
            _ = try await signature(builder, fixture)
            XCTFail("The signature must share the reader's database budget")
        } catch {}
    }

    func test_actualClaudeSignatureObservesOldMtimeRecordings() async throws {
        let fixture = try HermesM1Fixture()
        defer { fixture.remove() }
        let directory = fixture.home.appendingPathComponent(".claude/transcripts")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let builder = AgentSnapshotBuilder(home: fixture.home, environment: fixture.environment)
        let before = try await signature(builder, fixture)
        let file = directory.appendingPathComponent("old.jsonl")
        try Data("{}\n".utf8).write(to: file)
        try oldDate(file)
        let after = try await signature(builder, fixture)
        XCTAssertNotEqual(before, after)
    }

    private func signature(_ builder: AgentSnapshotBuilder, _ fixture: HermesM1Fixture) async throws -> String? {
        try await builder.sourceSignature(configuration: fixture.configuration(), now: fixture.now)
    }

    private func oldDate(_ url: URL) throws {
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSince1970: 1)], ofItemAtPath: url.path)
    }
}
