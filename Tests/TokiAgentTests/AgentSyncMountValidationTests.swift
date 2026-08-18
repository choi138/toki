import Foundation
import TokiSyncProtocol
import XCTest
@testable import TokiAgentCore
@testable import TokiUsageReaders

/// Mount revalidation must bracket the source reads, not only precede them.
///
/// `AgentSnapshotBuilding` gives `validateSourceMounts()` a no-op default, so a test double that
/// does not override it keeps passing even if the service stops calling it. These tests drive the
/// call sites directly: each fails if the corresponding `validateSourceMounts()` call is removed
/// from `AgentSyncService`.
final class AgentSyncMountValidationTests: XCTestCase {
    func test_replacementDuringBuildStopsUploadAndSpooling() async throws {
        let fixture = try AgentSyncFixture()
        defer { fixture.remove() }
        try AgentConfigurationStore(paths: fixture.paths).save(fixture.configuration)
        let hubClient = MountValidationHubClient()
        let snapshotBuilder = MountValidatingSnapshotBuilder(failingAfterBuild: true)
        let service = AgentSyncService(
            paths: fixture.paths,
            hubClient: hubClient,
            snapshotBuilder: snapshotBuilder)

        do {
            try await service.syncOnce(now: Date(timeIntervalSince1970: 1_780_000_000))
            XCTFail("Expected the post-build mount check to stop synchronization")
        } catch let error as AgentSnapshotBuilderError {
            XCTAssertTrue(error.requiresProcessRestart)
        }

        XCTAssertEqual(snapshotBuilder.buildCallCount, 1, "the snapshot must be built before the check")
        XCTAssertTrue(hubClient.uploadedSequences.isEmpty)
        XCTAssertTrue(hubClient.heartbeatSequences.isEmpty)
        let state = try AgentStateStore(paths: fixture.paths).load()
        XCTAssertEqual(state.latestSequence, 0)
        XCTAssertNil(state.lastUploadedContentDigest)
        XCTAssertTrue(try AgentSpool(paths: fixture.paths).pendingEnvelopes().isEmpty)
    }

    func test_replacementBeforeHeartbeatStopsTheUnchangedSnapshotReport() async throws {
        let fixture = try AgentSyncFixture()
        defer { fixture.remove() }
        try AgentConfigurationStore(paths: fixture.paths).save(fixture.configuration)
        let hubClient = MountValidationHubClient()
        let snapshotBuilder = MountValidatingSnapshotBuilder(failingAfterBuild: false)
        let service = AgentSyncService(
            paths: fixture.paths,
            hubClient: hubClient,
            snapshotBuilder: snapshotBuilder)
        let now = Date(timeIntervalSince1970: 1_780_000_000)

        // The first sync uploads. The second rebuilds, matches the stored digest, and reports the
        // device with a heartbeat instead.
        try await service.syncOnce(now: now)
        XCTAssertEqual(hubClient.uploadedSequences, [1])

        // Let the second sync's post-build check pass so only its heartbeat check can fail.
        // Without this offset the post-build call would raise first and mask the heartbeat path.
        snapshotBuilder.failMountValidation(fromCall: snapshotBuilder.validationCallCount + 2)
        do {
            try await service.syncOnce(now: now)
            XCTFail("Expected the heartbeat mount check to stop synchronization")
        } catch let error as AgentSnapshotBuilderError {
            XCTAssertTrue(error.requiresProcessRestart)
        }

        XCTAssertEqual(
            hubClient.heartbeatSequences,
            [UInt64](),
            "a stale mount must not report a healthy device")
        XCTAssertEqual(hubClient.uploadedSequences, [1])
    }
}

private final class MountValidationHubClient: AgentHubClientProtocol {
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

/// Snapshot builder whose mount validation can be armed to fail, either only after the first build
/// or on demand.
private final class MountValidatingSnapshotBuilder: AgentSnapshotBuilding {
    private let lock = NSLock()
    private let failingAfterBuild: Bool
    private var builds = 0
    private var validations = 0
    private var failFromCall: Int?

    init(failingAfterBuild: Bool) {
        self.failingAfterBuild = failingAfterBuild
    }

    var buildCallCount: Int {
        lock.withLock { builds }
    }

    var validationCallCount: Int {
        lock.withLock { validations }
    }

    /// Fails every mount validation from the given 1-based call index onward, so a test can target
    /// one specific call site instead of the first one reached.
    func failMountValidation(fromCall call: Int) {
        lock.withLock { failFromCall = call }
    }

    func validateSourceMounts() throws {
        let shouldFail = lock.withLock { () -> Bool in
            validations += 1
            if let failFromCall { return validations >= failFromCall }
            return failingAfterBuild && builds > 0
        }
        guard shouldFail else { return }
        throw AgentSnapshotBuilderError.sourceMountRefreshRequired
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
        SnapshotCipher.digest("mount-validating-source")
    }
}
