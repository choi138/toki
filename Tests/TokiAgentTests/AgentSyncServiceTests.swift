import Foundation
import TokiSyncProtocol
import XCTest
@testable import TokiAgentCore
@testable import TokiUsageReaders

final class AgentSyncServiceTests: XCTestCase {
    func test_unchangedSnapshotUsesHeartbeatWithoutUploadingAgain() async throws {
        let fixture = try AgentSyncFixture()
        defer { fixture.remove() }
        try AgentConfigurationStore(paths: fixture.paths).save(fixture.configuration)
        let hubClient = RecordingAgentHubClient()
        let snapshotBuilder = FixedAgentSnapshotBuilder()
        let service = AgentSyncService(
            paths: fixture.paths,
            hubClient: hubClient,
            snapshotBuilder: snapshotBuilder)
        let now = Date(timeIntervalSince1970: 1_780_000_000)

        try await service.syncOnce(now: now)
        try await service.syncOnce(now: now)
        try await service.syncOnce(now: now)

        XCTAssertEqual(hubClient.uploadedSequences, [1])
        XCTAssertEqual(hubClient.heartbeatSequences, [1, 1])
        XCTAssertEqual(snapshotBuilder.buildCallCount, 2)
        let state = try AgentStateStore(paths: fixture.paths).load()
        XCTAssertEqual(state.latestSequence, 1)
        XCTAssertNotNil(state.lastUploadedContentDigest)
        XCTAssertNotNil(state.lastSourceSignature)
        XCTAssertEqual(state.lastSuccessfulSyncAt, now)
        XCTAssertTrue(try AgentSpool(paths: fixture.paths).pendingEnvelopes().isEmpty)
    }

    func test_fullRescanForcesSnapshotBuildWhenSourceSignatureIsUnchanged() async throws {
        let fixture = try AgentSyncFixture()
        defer { fixture.remove() }
        try AgentConfigurationStore(paths: fixture.paths).save(fixture.configuration)
        let hubClient = RecordingAgentHubClient()
        let snapshotBuilder = FixedAgentSnapshotBuilder()
        let service = AgentSyncService(
            paths: fixture.paths,
            hubClient: hubClient,
            snapshotBuilder: snapshotBuilder)
        let now = Date(timeIntervalSince1970: 1_780_000_000)

        try await service.syncOnce(now: now)
        try await service.fullRescanAndSync(now: now)

        XCTAssertEqual(snapshotBuilder.buildCallCount, 2)
        XCTAssertEqual(hubClient.uploadedSequences, [1])
        XCTAssertEqual(hubClient.heartbeatSequences, [1])
    }

    func test_retentionWindowAdvanceRebuildsAndUploadsWithoutSourceChanges() async throws {
        let fixture = try AgentSyncFixture()
        defer { fixture.remove() }
        try AgentConfigurationStore(paths: fixture.paths).save(fixture.configuration)
        let hubClient = RecordingAgentHubClient()
        let snapshotBuilder = AgentSnapshotBuilder(home: fixture.root)
        let service = AgentSyncService(
            paths: fixture.paths,
            hubClient: hubClient,
            snapshotBuilder: snapshotBuilder)
        let firstSync = Date(timeIntervalSince1970: 1_780_000_000)
        let nextDay = try XCTUnwrap(
            Calendar(identifier: .gregorian).date(byAdding: .day, value: 1, to: firstSync))

        let firstSignature = try await snapshotBuilder.sourceSignature(
            configuration: fixture.configuration,
            now: firstSync)
        let nextDaySignature = try await snapshotBuilder.sourceSignature(
            configuration: fixture.configuration,
            now: nextDay)
        try await service.syncOnce(now: firstSync)
        try await service.syncOnce(now: nextDay)

        XCTAssertNotEqual(firstSignature, nextDaySignature)
        XCTAssertEqual(hubClient.uploadedSequences, [1, 2])
        XCTAssertTrue(hubClient.heartbeatSequences.isEmpty)
        XCTAssertEqual(try AgentStateStore(paths: fixture.paths).load().latestSequence, 2)
    }

    func test_changedWarmSnapshotUploadsAgainBeforeSourceSignatureBecomesStable() async throws {
        let fixture = try AgentSyncFixture()
        defer { fixture.remove() }
        try AgentConfigurationStore(paths: fixture.paths).save(fixture.configuration)
        let hubClient = RecordingAgentHubClient()
        let snapshotBuilder = ColdThenWarmAgentSnapshotBuilder()
        let service = AgentSyncService(
            paths: fixture.paths,
            hubClient: hubClient,
            snapshotBuilder: snapshotBuilder)
        let now = Date(timeIntervalSince1970: 1_780_000_000)

        try await service.syncOnce(now: now)
        try await service.syncOnce(now: now)
        try await service.syncOnce(now: now)
        try await service.syncOnce(now: now)

        XCTAssertEqual(hubClient.uploadedSequences, [1, 2])
        XCTAssertEqual(hubClient.heartbeatSequences, [2, 2])
        XCTAssertEqual(snapshotBuilder.buildCallCount, 3)
        let state = try AgentStateStore(paths: fixture.paths).load()
        XCTAssertEqual(state.latestSequence, 2)
        XCTAssertNotNil(state.lastUploadedContentDigest)
        XCTAssertNotNil(state.lastSourceSignature)
    }

    func test_uploadFailureRecoversPendingSpoolAfterServiceRestart() async throws {
        let fixture = try AgentSyncFixture()
        defer { fixture.remove() }
        try AgentConfigurationStore(paths: fixture.paths).save(fixture.configuration)
        let hubClient = FailFirstUploadAgentHubClient()
        let firstBuilder = FixedAgentSnapshotBuilder()
        let firstService = AgentSyncService(
            paths: fixture.paths,
            hubClient: hubClient,
            snapshotBuilder: firstBuilder)
        let now = Date(timeIntervalSince1970: 1_780_000_000)

        do {
            try await firstService.syncOnce(now: now)
            XCTFail("Expected the first upload to fail")
        } catch AgentSyncTestError.uploadFailed {}

        var state = try AgentStateStore(paths: fixture.paths).load()
        XCTAssertEqual(state.latestSequence, 1)
        XCTAssertNil(state.lastUploadedContentDigest)
        XCTAssertNil(state.lastSourceSignature)
        XCTAssertNil(state.lastSuccessfulSyncAt)
        XCTAssertEqual(try AgentSpool(paths: fixture.paths).pendingEnvelopes().count, 1)

        let restartedBuilder = FixedAgentSnapshotBuilder()
        let restartedService = AgentSyncService(
            paths: fixture.paths,
            hubClient: hubClient,
            snapshotBuilder: restartedBuilder)
        try await restartedService.syncOnce(now: now)
        try await restartedService.syncOnce(now: now)

        state = try AgentStateStore(paths: fixture.paths).load()
        XCTAssertEqual(hubClient.uploadAttempts, [1, 1])
        XCTAssertEqual(hubClient.successfulUploads, [1])
        XCTAssertEqual(hubClient.heartbeatSequences, [1, 1])
        XCTAssertEqual(restartedBuilder.buildCallCount, 1)
        XCTAssertNotNil(state.lastUploadedContentDigest)
        XCTAssertNotNil(state.lastSourceSignature)
        XCTAssertEqual(state.lastSuccessfulSyncAt, now)
        XCTAssertTrue(try AgentSpool(paths: fixture.paths).pendingEnvelopes().isEmpty)
    }

    func test_verificationHeartbeatFailureDoesNotRepeatSnapshotBuild() async throws {
        let fixture = try AgentSyncFixture()
        defer { fixture.remove() }
        try AgentConfigurationStore(paths: fixture.paths).save(fixture.configuration)
        let hubClient = FailFirstHeartbeatAgentHubClient()
        let snapshotBuilder = FixedAgentSnapshotBuilder()
        let service = AgentSyncService(
            paths: fixture.paths,
            hubClient: hubClient,
            snapshotBuilder: snapshotBuilder)
        let now = Date(timeIntervalSince1970: 1_780_000_000)

        try await service.syncOnce(now: now)
        do {
            try await service.syncOnce(now: now)
            XCTFail("Expected the verification heartbeat to fail")
        } catch AgentSyncTestError.heartbeatFailed {}

        var state = try AgentStateStore(paths: fixture.paths).load()
        XCTAssertNotNil(state.lastSourceSignature)
        XCTAssertEqual(state.lastSuccessfulSyncAt, now)
        XCTAssertNotNil(state.lastError)
        XCTAssertEqual(snapshotBuilder.buildCallCount, 2)

        try await service.syncOnce(now: now)

        state = try AgentStateStore(paths: fixture.paths).load()
        XCTAssertEqual(hubClient.uploadedSequences, [1])
        XCTAssertEqual(hubClient.heartbeatAttempts, [1, 1])
        XCTAssertEqual(hubClient.successfulHeartbeats, [1])
        XCTAssertEqual(snapshotBuilder.buildCallCount, 2)
        XCTAssertEqual(state.lastSuccessfulSyncAt, now)
        XCTAssertNil(state.lastError)
    }

    func test_readerFailureDuringVerificationPreservesPreviousSnapshot() async throws {
        let fixture = try AgentSyncFixture()
        defer { fixture.remove() }
        try AgentConfigurationStore(paths: fixture.paths).save(fixture.configuration)
        let hubClient = RecordingAgentHubClient()
        let snapshotBuilder = FailAfterFirstAgentSnapshotBuilder()
        let service = AgentSyncService(
            paths: fixture.paths,
            hubClient: hubClient,
            snapshotBuilder: snapshotBuilder)
        let now = Date(timeIntervalSince1970: 1_780_000_000)

        try await service.syncOnce(now: now)
        let uploadedState = try AgentStateStore(paths: fixture.paths).load()

        do {
            try await service.syncOnce(now: now)
            XCTFail("Expected the verification build to fail")
        } catch let error as AgentSnapshotBuilderError {
            guard case let .readerFailed(name) = error else {
                return XCTFail("Expected readerFailed, got \(error)")
            }
            XCTAssertEqual(name, "Hermes")
        }

        let failedState = try AgentStateStore(paths: fixture.paths).load()
        XCTAssertEqual(hubClient.uploadedSequences, [1])
        XCTAssertTrue(hubClient.heartbeatSequences.isEmpty)
        XCTAssertEqual(failedState.latestSequence, uploadedState.latestSequence)
        XCTAssertEqual(failedState.lastUploadedContentDigest, uploadedState.lastUploadedContentDigest)
        XCTAssertNil(failedState.lastSourceSignature)
        XCTAssertNotNil(failedState.lastError)
        XCTAssertTrue(try AgentSpool(paths: fixture.paths).pendingEnvelopes().isEmpty)
    }
}

extension AgentSyncServiceTests {
    func test_sourceSignatureIgnoresJsonlOutsideRetainedWindow() async throws {
        let fixture = try AgentSyncFixture()
        defer { fixture.remove() }
        let builder = AgentSnapshotBuilder(home: fixture.root)
        let now = Date(timeIntervalSince1970: 1_780_000_000)
        let oldDirectory = fixture.root.appendingPathComponent(".codex/sessions/2001/01/01")
        let archiveDirectory = fixture.root.appendingPathComponent(".codex/archived_sessions")
        try FileManager.default.createDirectory(at: oldDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: archiveDirectory, withIntermediateDirectories: true)

        let before = try await builder.sourceSignature(configuration: fixture.configuration, now: now)
        let activeURL = oldDirectory.appendingPathComponent("old.jsonl")
        let archivedURL = archiveDirectory.appendingPathComponent("old.jsonl")
        try Data("{}\n".utf8).write(to: activeURL)
        try Data("{}\n".utf8).write(to: archivedURL)
        let oldDate = Date(timeIntervalSince1970: 978_307_200)
        try FileManager.default.setAttributes([.modificationDate: oldDate], ofItemAtPath: activeURL.path)
        try FileManager.default.setAttributes([.modificationDate: oldDate], ofItemAtPath: archivedURL.path)
        let after = try await builder.sourceSignature(configuration: fixture.configuration, now: now)

        XCTAssertEqual(before, after)
    }

    func test_sourceSignatureTracksRetainedArchivedJsonlWithoutDatabaseIndex() async throws {
        let fixture = try AgentSyncFixture()
        defer { fixture.remove() }
        let builder = AgentSnapshotBuilder(home: fixture.root)
        let now = Date(timeIntervalSince1970: 1_780_000_000)
        let archiveDirectory = fixture.root.appendingPathComponent(".codex/archived_sessions")
        try FileManager.default.createDirectory(at: archiveDirectory, withIntermediateDirectories: true)
        let archivedURL = archiveDirectory.appendingPathComponent("retained.jsonl")
        try Data("{\"value\":1}\n".utf8).write(to: archivedURL)
        try FileManager.default.setAttributes(
            [.modificationDate: now.addingTimeInterval(-60)],
            ofItemAtPath: archivedURL.path)
        let before = try await builder.sourceSignature(configuration: fixture.configuration, now: now)

        try Data("{\"value\":22}\n".utf8).write(to: archivedURL)
        try FileManager.default.setAttributes([.modificationDate: now], ofItemAtPath: archivedURL.path)
        let after = try await builder.sourceSignature(configuration: fixture.configuration, now: now)

        XCTAssertNotEqual(before, after)
    }

    func test_initialAndSuccessJitterAreStableAndBounded() {
        let interval = 900
        let deviceID = "device-stable-jitter"
        let initial = AgentSyncService.scheduledDelay(
            interval: interval,
            deviceID: deviceID,
            phase: "initial")
        let success = AgentSyncService.scheduledDelay(
            interval: interval,
            deviceID: deviceID,
            phase: "success")

        XCTAssertEqual(
            initial,
            AgentSyncService.scheduledDelay(interval: interval, deviceID: deviceID, phase: "initial"))
        XCTAssertEqual(
            success,
            AgentSyncService.scheduledDelay(interval: interval, deviceID: deviceID, phase: "success"))
        XCTAssertTrue((0...(interval / 10)).contains(initial))
        XCTAssertTrue((interval...(interval + interval / 10)).contains(success))
    }

    func test_unknownCommandDoesNotEchoPairingSecret() async {
        let pairingSecret = Data(repeating: 0x41, count: 512).base64EncodedString()

        do {
            try await TokiAgentCommand.execute(arguments: [pairingSecret])
            XCTFail("Expected an unknown command error")
        } catch {
            let description = AgentSyncService.publicErrorDescription(error)
            XCTAssertFalse(description.contains(pairingSecret))
            XCTAssertFalse(description.contains(String(pairingSecret.prefix(100))))
            XCTAssertEqual(description, "Unknown command. Run `toki-agent help`.")
        }
    }
}

struct AgentSyncFixture {
    let root: URL
    let paths: AgentPaths
    let configuration: AgentConfiguration

    init() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("toki-agent-sync-tests-\(UUID().uuidString)")
        paths = AgentPaths(environment: [
            "XDG_CONFIG_HOME": root.appendingPathComponent("config").path,
            "XDG_STATE_HOME": root.appendingPathComponent("state").path,
            "XDG_DATA_HOME": root.appendingPathComponent("data").path,
        ], home: root)
        configuration = try AgentConfiguration(bundle: AgentPairingBundle(
            hubURL: URL(string: "https://hub.example.test")!,
            deviceID: "device-1",
            deviceName: "ubuntu",
            uploadToken: SnapshotCipher.randomToken(),
            encryptionKey: SnapshotCipher.generateKey(),
            retentionDays: 30,
            syncIntervalSeconds: 900))
    }

    func remove() {
        try? FileManager.default.removeItem(at: root)
    }
}

func hermesSyncObservation(
    startedAt: Date,
    latestActivityAt: Date,
    inputTokens: Int) -> HermesSessionObservation {
    HermesSessionObservation(
        sessionID: "hermes-sync-session",
        startedAt: startedAt,
        earliestActivityAt: latestActivityAt,
        latestActivityAt: latestActivityAt,
        model: "gpt-5",
        counters: HermesTokenCounters(
            inputTokens: inputTokens,
            outputTokens: 0,
            cacheReadTokens: 0,
            cacheWriteTokens: 0,
            reasoningTokens: 0),
        cost: 0,
        projectName: nil,
        attributionQuality: .unknown)
}

func hermesLedgerSnapshotBuilder(
    fixture: AgentSyncFixture,
    ledger: HermesUsageLedger,
    ledgerURL: URL,
    now: Date) -> AgentSnapshotBuilder {
    let missingDatabaseURL = fixture.root.appendingPathComponent("missing-hermes-state.db")
    let descriptor = LocalUsageReaderDescriptor(
        reader: HermesReader(
            dbPathOverride: missingDatabaseURL.path,
            usageLedger: ledger,
            now: { now }),
        sourceLocations: [.file(ledgerURL, includesSQLiteSidecars: false)])
    return AgentSnapshotBuilder(
        home: fixture.root,
        readerDescriptors: [descriptor])
}

func remoteSnapshotTotalTokens(_ snapshot: RemoteUsageSnapshot) -> Int {
    snapshot.tokenEvents.reduce(0) { total, event in
        total
            + event.inputTokens
            + event.outputTokens
            + event.cacheReadTokens
            + event.cacheWriteTokens
            + event.reasoningTokens
    }
}

private final class FixedAgentSnapshotBuilder: AgentSnapshotBuilding {
    private let lock = NSLock()
    private var builds = 0

    var buildCallCount: Int {
        lock.withLock { builds }
    }

    func build(configuration: AgentConfiguration, now: Date) async throws -> RemoteUsageSnapshot {
        lock.withLock { builds += 1 }
        return RemoteUsageSnapshot(
            device: RemoteDeviceDescriptor(
                id: configuration.deviceID,
                name: configuration.deviceName,
                platform: "linux"),
            generatedAt: now,
            coveredFrom: now.addingTimeInterval(-3600),
            coveredTo: now.addingTimeInterval(3600),
            tokenEvents: [],
            activityEvents: [])
    }

    func contentDigest(_ snapshot: RemoteUsageSnapshot) throws -> String {
        try AgentSnapshotBuilder().contentDigest(snapshot)
    }

    func sourceSignature(configuration _: AgentConfiguration, now _: Date) async throws -> String? {
        SnapshotCipher.digest("fixed-source")
    }
}

private final class ColdThenWarmAgentSnapshotBuilder: AgentSnapshotBuilding {
    private let lock = NSLock()
    private var builds = 0

    var buildCallCount: Int {
        lock.withLock { builds }
    }

    func build(configuration: AgentConfiguration, now: Date) async throws -> RemoteUsageSnapshot {
        let buildNumber = lock.withLock {
            builds += 1
            return builds
        }
        let tokenEvents: [RemoteTokenEvent] = buildNumber == 1
            ? []
            : [RemoteTokenEvent(
                timestamp: now,
                source: "Codex",
                model: "gpt-5",
                inputTokens: 20,
                outputTokens: 5,
                cacheReadTokens: 0,
                cacheWriteTokens: 0,
                reasoningTokens: 0)]
        return RemoteUsageSnapshot(
            device: RemoteDeviceDescriptor(
                id: configuration.deviceID,
                name: configuration.deviceName,
                platform: "linux"),
            generatedAt: now,
            coveredFrom: now.addingTimeInterval(-3600),
            coveredTo: now.addingTimeInterval(3600),
            tokenEvents: tokenEvents,
            activityEvents: [])
    }

    func contentDigest(_ snapshot: RemoteUsageSnapshot) throws -> String {
        try AgentSnapshotBuilder().contentDigest(snapshot)
    }

    func sourceSignature(configuration _: AgentConfiguration, now _: Date) async throws -> String? {
        SnapshotCipher.digest("unchanged-cold-warm-source")
    }
}

private final class FailAfterFirstAgentSnapshotBuilder: AgentSnapshotBuilding {
    private let lock = NSLock()
    private var builds = 0

    func build(configuration: AgentConfiguration, now: Date) async throws -> RemoteUsageSnapshot {
        let buildNumber = lock.withLock {
            builds += 1
            return builds
        }
        guard buildNumber == 1 else {
            throw AgentSnapshotBuilderError.readerFailed("Hermes")
        }
        return RemoteUsageSnapshot(
            device: RemoteDeviceDescriptor(
                id: configuration.deviceID,
                name: configuration.deviceName,
                platform: "linux"),
            generatedAt: now,
            coveredFrom: now.addingTimeInterval(-3600),
            coveredTo: now.addingTimeInterval(3600),
            tokenEvents: [],
            activityEvents: [])
    }

    func contentDigest(_ snapshot: RemoteUsageSnapshot) throws -> String {
        try AgentSnapshotBuilder().contentDigest(snapshot)
    }

    func sourceSignature(configuration _: AgentConfiguration, now _: Date) async throws -> String? {
        SnapshotCipher.digest("partial-reader-failure")
    }
}

private final class RecordingAgentHubClient: AgentHubClientProtocol {
    private let lock = NSLock()
    private var uploads: [UInt64] = []
    private var heartbeats: [UInt64] = []

    var uploadedSequences: [UInt64] {
        lock.withLock { uploads }
    }

    var heartbeatSequences: [UInt64] {
        lock.withLock { heartbeats }
    }

    func upload(_ envelope: EncryptedUsageEnvelope, configuration _: AgentConfiguration) async throws {
        lock.withLock { uploads.append(envelope.sequence) }
    }

    func heartbeat(configuration _: AgentConfiguration, latestSequence: UInt64) async throws {
        lock.withLock { heartbeats.append(latestSequence) }
    }
}

enum AgentSyncTestError: Error {
    case heartbeatFailed
    case uploadFailed
}

final class FailFirstUploadAgentHubClient: AgentHubClientProtocol {
    private let lock = NSLock()
    private var shouldFailUpload = true
    private var attempts: [UInt64] = []
    private var uploads: [UInt64] = []
    private var envelopes: [EncryptedUsageEnvelope] = []
    private var heartbeats: [UInt64] = []

    var uploadAttempts: [UInt64] {
        lock.withLock { attempts }
    }

    var successfulUploads: [UInt64] {
        lock.withLock { uploads }
    }

    var successfulEnvelopes: [EncryptedUsageEnvelope] {
        lock.withLock { envelopes }
    }

    var heartbeatSequences: [UInt64] {
        lock.withLock { heartbeats }
    }

    func upload(_ envelope: EncryptedUsageEnvelope, configuration _: AgentConfiguration) async throws {
        let shouldFail = lock.withLock {
            attempts.append(envelope.sequence)
            if shouldFailUpload {
                shouldFailUpload = false
                return true
            }
            uploads.append(envelope.sequence)
            envelopes.append(envelope)
            return false
        }
        if shouldFail {
            throw AgentSyncTestError.uploadFailed
        }
    }

    func heartbeat(configuration _: AgentConfiguration, latestSequence: UInt64) async throws {
        lock.withLock { heartbeats.append(latestSequence) }
    }
}
