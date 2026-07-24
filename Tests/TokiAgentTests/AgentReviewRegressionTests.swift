import Foundation
import TokiSyncProtocol
import XCTest
@testable import TokiAgentCore

final class AgentReviewRegressionTests: XCTestCase {
    func test_buildMutationInvalidatesHeartbeatFastPath() async throws {
        let fixture = try AgentSyncFixture()
        defer { fixture.remove() }
        try AgentConfigurationStore(paths: fixture.paths).save(fixture.configuration)
        let hubClient = ReviewHubClient()
        let snapshotBuilder = SignatureMutatingBuilder()
        let service = AgentSyncService(
            paths: fixture.paths,
            hubClient: hubClient,
            snapshotBuilder: snapshotBuilder)
        let now = Date(timeIntervalSince1970: 1_780_000_000)

        try await service.syncOnce(now: now)
        try await service.syncOnce(now: now)
        try await service.syncOnce(now: now)

        XCTAssertEqual(snapshotBuilder.buildCallCount, 3)
        XCTAssertEqual(hubClient.uploadedSequences, [1])
        XCTAssertEqual(hubClient.heartbeatSequences, [1, 1])
        XCTAssertNil(try AgentStateStore(paths: fixture.paths).load().lastSourceSignature)
    }

    func test_hubRejectedTimestampIsNotAddedToSpool() async throws {
        let fixture = try AgentSyncFixture()
        defer { fixture.remove() }
        try AgentConfigurationStore(paths: fixture.paths).save(fixture.configuration)
        let hubClient = ReviewHubClient()
        let service = AgentSyncService(
            paths: fixture.paths,
            hubClient: hubClient,
            snapshotBuilder: ReviewFixedBuilder())
        let now = Date(timeIntervalSince1970: 946_684_799)

        do {
            try await service.syncOnce(now: now)
            XCTFail("Expected the timestamp to be rejected")
        } catch let error as AgentSyncError {
            guard case .invalidEnvelopeTimestamp = error else {
                return XCTFail("Expected invalidEnvelopeTimestamp, got \(error)")
            }
        }

        XCTAssertTrue(hubClient.uploadedSequences.isEmpty)
        XCTAssertTrue(try AgentSpool(paths: fixture.paths).pendingEnvelopes().isEmpty)
        XCTAssertEqual(try AgentStateStore(paths: fixture.paths).load().latestSequence, 0)
    }

    func test_recoveryErrorsDirectOperatorsThroughUnpair() throws {
        for error in [AgentSyncError.pendingDeviceMismatch, .sequenceExhausted] {
            let description = try XCTUnwrap(error.errorDescription)
            XCTAssertTrue(description.contains("`toki-agent unpair`"))
        }
    }

    func test_sourceDiagnosticsRejectExistingSQLiteSidecarWithWrongType() throws {
        let fixture = try AgentSyncFixture()
        defer { fixture.remove() }
        let hermesURL = fixture.root.appendingPathComponent(".hermes/state.db")
        try FileManager.default.createDirectory(
            at: hermesURL.deletingLastPathComponent(),
            withIntermediateDirectories: true)
        try Data().write(to: hermesURL)
        try FileManager.default.createDirectory(
            at: URL(fileURLWithPath: hermesURL.path + "-wal"),
            withIntermediateDirectories: false)

        let diagnostics = TokiAgentCommand.sourceDiagnostics(
            home: fixture.root,
            environment: [:])

        XCTAssertEqual(diagnostics.first(where: { $0.name == "Hermes" })?.status, .error)
    }

    func test_heartbeatSequenceConflictFallsBackToSnapshotUpload() async throws {
        let fixture = try AgentSyncFixture()
        defer { fixture.remove() }
        try AgentConfigurationStore(paths: fixture.paths).save(fixture.configuration)
        let hubClient = SequenceConflictHubClient()
        let service = AgentSyncService(
            paths: fixture.paths,
            hubClient: hubClient,
            snapshotBuilder: ReviewFixedBuilder())
        let now = Date(timeIntervalSince1970: 1_780_000_000)

        try await service.syncOnce(now: now)
        try await service.syncOnce(now: now)
        hubClient.rejectNextHeartbeat()
        try await service.syncOnce(now: now)
        try await service.syncOnce(now: now)

        XCTAssertEqual(hubClient.uploadedSequences, [1, 2])
        XCTAssertEqual(hubClient.heartbeatSequences, [1, 1, 2])
        let state = try AgentStateStore(paths: fixture.paths).load()
        XCTAssertEqual(state.latestSequence, 2)
        XCTAssertNotNil(state.lastUploadedContentDigest)
        XCTAssertNotNil(state.lastSourceSignature)
    }

    func test_freshUploadSequenceConflictProvidesRecoveryGuidance() async throws {
        let fixture = try AgentSyncFixture()
        defer { fixture.remove() }
        try AgentConfigurationStore(paths: fixture.paths).save(fixture.configuration)
        let service = AgentSyncService(
            paths: fixture.paths,
            hubClient: ReviewUploadConflictHubClient(),
            snapshotBuilder: ReviewFixedBuilder())
        let now = Date(timeIntervalSince1970: 1_780_000_000)
        var caughtError: Error?

        do {
            try await service.syncOnce(now: now)
            XCTFail("Expected the fresh upload to report a sequence conflict")
        } catch {
            caughtError = error
        }

        let syncError = try XCTUnwrap(caughtError as? AgentSyncError)
        guard case .uploadSequenceConflict = syncError else {
            return XCTFail("Expected uploadSequenceConflict, got \(syncError)")
        }
        XCTAssertEqual(
            syncError.errorDescription,
            "The Hub already has an upload at this sequence. Revoke the existing device in Hub, "
                + "run `toki-agent unpair`, then pair again as a new device.")
        XCTAssertEqual(try AgentSpool(paths: fixture.paths).pendingEnvelopes().count, 1)
    }

    func test_pendingReplaySequenceConflictPreservesSpool() async throws {
        let fixture = try AgentSyncFixture()
        defer { fixture.remove() }
        try AgentConfigurationStore(paths: fixture.paths).save(fixture.configuration)
        let now = Date(timeIntervalSince1970: 1_780_000_000)
        let snapshot = try await ReviewFixedBuilder().build(
            configuration: fixture.configuration,
            now: now)
        let envelope = try SnapshotCipher.seal(
            snapshot,
            sequence: 1,
            key: fixture.configuration.encryptionKey)
        _ = try AgentSpool(paths: fixture.paths).enqueue(envelope)
        let service = AgentSyncService(
            paths: fixture.paths,
            hubClient: ReviewUploadConflictHubClient(),
            snapshotBuilder: ReviewFixedBuilder())
        var caughtError: Error?

        do {
            try await service.syncOnce(now: now)
            XCTFail("Expected the pending upload to report a sequence conflict")
        } catch {
            caughtError = error
        }

        let syncError = try XCTUnwrap(caughtError as? AgentSyncError)
        guard case .uploadSequenceConflict = syncError else {
            return XCTFail("Expected uploadSequenceConflict, got \(syncError)")
        }
        XCTAssertEqual(
            syncError.errorDescription,
            "The Hub already has an upload at this sequence. Revoke the existing device in Hub, "
                + "run `toki-agent unpair`, then pair again as a new device.")
        let pending = try AgentSpool(paths: fixture.paths).pendingEnvelopes()
        XCTAssertEqual(pending.map(\.envelope.sequence), [1])
    }

    func test_commandRejectsTrailingArgumentsBeforeDispatch() async throws {
        do {
            try await TokiAgentCommand.execute(arguments: ["version", "--unexpected"])
            XCTFail("Expected trailing arguments to be rejected")
        } catch let error as AgentCommandError {
            guard case .unexpectedArguments = error else {
                return XCTFail("Expected unexpectedArguments, got \(error)")
            }
        }
    }
}

private final class ReviewHubClient: AgentHubClientProtocol {
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

private final class SequenceConflictHubClient: AgentHubClientProtocol {
    private let lock = NSLock()
    private var uploads: [UInt64] = []
    private var heartbeats: [UInt64] = []
    private var shouldRejectNextHeartbeat = false

    var uploadedSequences: [UInt64] {
        lock.withLock { uploads }
    }

    var heartbeatSequences: [UInt64] {
        lock.withLock { heartbeats }
    }

    func rejectNextHeartbeat() {
        lock.withLock { shouldRejectNextHeartbeat = true }
    }

    func upload(_ envelope: EncryptedUsageEnvelope, configuration _: AgentConfiguration) async throws {
        lock.withLock { uploads.append(envelope.sequence) }
    }

    func heartbeat(configuration _: AgentConfiguration, latestSequence: UInt64) async throws {
        let shouldReject = lock.withLock {
            heartbeats.append(latestSequence)
            defer { shouldRejectNextHeartbeat = false }
            return shouldRejectNextHeartbeat
        }
        if shouldReject {
            throw AgentHubClientError.httpStatus(409)
        }
    }
}

private final class ReviewUploadConflictHubClient: AgentHubClientProtocol {
    func upload(_: EncryptedUsageEnvelope, configuration _: AgentConfiguration) async throws {
        throw AgentHubClientError.httpStatus(409)
    }

    func heartbeat(configuration _: AgentConfiguration, latestSequence _: UInt64) async throws {}
}

private class ReviewFixedBuilder: AgentSnapshotBuilding {
    func build(configuration: AgentConfiguration, now: Date) async throws -> RemoteUsageSnapshot {
        RemoteUsageSnapshot(
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
        SnapshotCipher.digest("review-fixed-source")
    }
}

private final class SignatureMutatingBuilder: ReviewFixedBuilder {
    private let lock = NSLock()
    private var builds = 0
    private var sourceRevision = 0

    var buildCallCount: Int {
        lock.withLock { builds }
    }

    var currentSourceSignature: String {
        lock.withLock { SnapshotCipher.digest("build-mutated-source-\(sourceRevision)") }
    }

    override func build(configuration: AgentConfiguration, now: Date) async throws -> RemoteUsageSnapshot {
        lock.withLock {
            builds += 1
            sourceRevision += 1
        }
        return try await super.build(configuration: configuration, now: now)
    }

    override func sourceSignature(configuration _: AgentConfiguration, now _: Date) async throws -> String? {
        currentSourceSignature
    }
}
