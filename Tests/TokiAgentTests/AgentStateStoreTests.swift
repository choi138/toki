import Foundation
import TokiSyncProtocol
import XCTest
@testable import TokiAgentCore

final class AgentStateStoreTests: XCTestCase {
    func test_stateStoreFailsClosedForCorruptedState() throws {
        let fixture = makeAgentStateFixture()
        defer { fixture.remove() }
        try fixture.paths.prepare()
        try Data("not-json".utf8).write(to: fixture.paths.runtimeStateURL)

        XCTAssertThrowsError(try AgentStateStore(paths: fixture.paths).load()) { error in
            XCTAssertTrue(error is AgentStateStoreError)
        }
    }

    func test_stateAndConfigurationUsePrivatePermissions() throws {
        let fixture = makeAgentStateFixture()
        defer { fixture.remove() }
        let stateStore = AgentStateStore(paths: fixture.paths)
        try stateStore.save(AgentRuntimeState(latestSequence: 7))

        let bundle = try AgentPairingBundle(
            hubURL: XCTUnwrap(URL(string: "https://hub.example.test")),
            deviceID: "device-1",
            deviceName: "ubuntu",
            uploadToken: SnapshotCipher.randomToken(),
            encryptionKey: SnapshotCipher.generateKey())
        try AgentConfigurationStore(paths: fixture.paths).save(AgentConfiguration(bundle: bundle))

        XCTAssertEqual(try stateStore.load().latestSequence, 7)
        XCTAssertEqual(try filePermissions(at: fixture.paths.runtimeStateURL), 0o600)
        XCTAssertEqual(try filePermissions(at: fixture.paths.configurationURL), 0o600)
    }

    func test_configurationStoreRejectsGroupReadableCredentials() throws {
        let fixture = makeAgentStateFixture()
        defer { fixture.remove() }
        let bundle = try AgentPairingBundle(
            hubURL: XCTUnwrap(URL(string: "https://hub.example.test")),
            deviceID: "device-1",
            deviceName: "ubuntu",
            uploadToken: SnapshotCipher.randomToken(),
            encryptionKey: SnapshotCipher.generateKey())
        let store = AgentConfigurationStore(paths: fixture.paths)
        try store.save(AgentConfiguration(bundle: bundle))
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: 0o640)],
            ofItemAtPath: fixture.paths.configurationURL.path)

        XCTAssertThrowsError(try store.load()) { error in
            guard let configurationError = error as? AgentConfigurationError,
                  case .invalidConfigurationFile = configurationError else {
                return XCTFail("Expected invalidConfigurationFile, got \(error)")
            }
        }
    }

    func test_stateStoreRejectsUploadedDigestWithoutSequence() {
        let fixture = makeAgentStateFixture()
        defer { fixture.remove() }
        let state = AgentRuntimeState(
            latestSequence: 0,
            lastUploadedContentDigest: String(repeating: "a", count: 64))

        XCTAssertThrowsError(try AgentStateStore(paths: fixture.paths).save(state)) { error in
            XCTAssertTrue(error is AgentStateStoreError)
        }
    }

    func test_processLockRejectsConcurrentAgentOperation() throws {
        let fixture = makeAgentStateFixture()
        defer { fixture.remove() }
        do {
            let firstLock = try AgentProcessLock.acquire(paths: fixture.paths)
            XCTAssertThrowsError(try AgentProcessLock.acquire(paths: fixture.paths)) { error in
                XCTAssertTrue(error is AgentProcessLockError)
            }
            withExtendedLifetime(firstLock) {}
        }

        XCTAssertNoThrow(try AgentProcessLock.acquire(paths: fixture.paths))
    }

    func test_spoolRejectsEnvelopeWhoseSequenceDoesNotMatchFilename() throws {
        let fixture = makeAgentStateFixture()
        defer { fixture.remove() }
        try fixture.paths.prepare()
        let envelope = EncryptedUsageEnvelope(
            deviceID: "device-1",
            sequence: 2,
            generatedAt: Date(timeIntervalSince1970: 1_750_000_000),
            payload: Data("ciphertext".utf8).base64EncodedString())
        let data = try TokiSyncCoding.makeEncoder().encode(envelope)
        try data.write(
            to: fixture.paths.spoolDirectory.appendingPathComponent("00000000000000000001.json"))

        XCTAssertThrowsError(try AgentSpool(paths: fixture.paths).pendingEnvelopes()) { error in
            guard let spoolError = error as? AgentSpoolError,
                  case .invalidEnvelope = spoolError else {
                return XCTFail("Expected invalidEnvelope, got \(error)")
            }
        }
    }

    func test_spoolRejectsFifthEnvelopeWithoutPoisoningExistingQueue() throws {
        let fixture = makeAgentStateFixture()
        defer { fixture.remove() }
        let spool = AgentSpool(paths: fixture.paths)

        for sequence in UInt64(1)...UInt64(4) {
            _ = try spool.enqueue(makeEncryptedEnvelope(sequence: sequence))
        }

        XCTAssertThrowsError(try spool.enqueue(makeEncryptedEnvelope(sequence: 5))) { error in
            guard let spoolError = error as? AgentSpoolError,
                  case .tooManyPendingEnvelopes = spoolError else {
                return XCTFail("Expected tooManyPendingEnvelopes, got \(error)")
            }
        }
        XCTAssertNoThrow(try spool.enqueue(makeEncryptedEnvelope(sequence: 4, payload: "replacement")))

        let pending = try spool.pendingEnvelopes()
        XCTAssertEqual(pending.map(\.envelope.sequence), [1, 2, 3, 4])
        XCTAssertEqual(
            pending.last?.envelope.payload,
            Data("replacement".utf8).base64EncodedString())
    }

    func test_configurationRejectsRemotePlainHTTP() throws {
        let bundle = try AgentPairingBundle(
            hubURL: XCTUnwrap(URL(string: "http://hub.example.test")),
            deviceID: "device-1",
            deviceName: "ubuntu",
            uploadToken: SnapshotCipher.randomToken(),
            encryptionKey: SnapshotCipher.generateKey())

        XCTAssertThrowsError(try AgentConfiguration(bundle: bundle))
    }

    func test_v1ConfigurationDefaultsMissingRetentionAndSyncInterval() throws {
        let hubURL = try XCTUnwrap(URL(string: "https://hub.example.test"))
        let data = try TokiSyncCoding.makeEncoder().encode(LegacyAgentConfiguration(
            schemaVersion: TokiSyncProtocolVersion.current,
            hubURL: hubURL,
            deviceID: "device-1",
            deviceName: "ubuntu",
            uploadToken: SnapshotCipher.randomToken(),
            encryptionKey: SnapshotCipher.generateKey()))

        let configuration = try TokiSyncCoding.makeDecoder().decode(AgentConfiguration.self, from: data)

        XCTAssertEqual(configuration.hubURL, hubURL)
        XCTAssertEqual(configuration.retentionDays, TokiSyncLimits.defaultRetentionDays)
        XCTAssertEqual(configuration.syncIntervalSeconds, TokiSyncLimits.defaultSyncIntervalSeconds)
        XCTAssertNoThrow(try configuration.validate())
    }

    func test_relativeXDGPathsFallBackToAbsoluteHomeDirectories() {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("toki-agent-home-\(UUID().uuidString)")
        let paths = AgentPaths(environment: [
            "XDG_CONFIG_HOME": "relative-config",
            "XDG_STATE_HOME": "relative-state",
            "XDG_DATA_HOME": "relative-data",
        ], home: home)

        XCTAssertEqual(paths.configurationDirectory, home.appendingPathComponent(".config/toki-agent"))
        XCTAssertEqual(paths.stateDirectory, home.appendingPathComponent(".local/state/toki-agent"))
        XCTAssertEqual(paths.dataDirectory, home.appendingPathComponent(".local/share/toki-agent"))
    }
}

private func makeAgentStateFixture() -> AgentStateFixture {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("toki-agent-state-tests-\(UUID().uuidString)")
    let environment = [
        "XDG_CONFIG_HOME": root.appendingPathComponent("config").path,
        "XDG_STATE_HOME": root.appendingPathComponent("state").path,
        "XDG_DATA_HOME": root.appendingPathComponent("data").path,
    ]
    return AgentStateFixture(root: root, paths: AgentPaths(environment: environment, home: root))
}

private func filePermissions(at url: URL) throws -> Int? {
    let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
    return (attributes[.posixPermissions] as? NSNumber)?.intValue
}

private func makeEncryptedEnvelope(
    sequence: UInt64,
    payload: String = "ciphertext") -> EncryptedUsageEnvelope {
    EncryptedUsageEnvelope(
        deviceID: "device-1",
        sequence: sequence,
        generatedAt: Date(timeIntervalSince1970: 1_750_000_000),
        payload: Data(payload.utf8).base64EncodedString())
}

private struct AgentStateFixture {
    let root: URL
    let paths: AgentPaths

    func remove() {
        try? FileManager.default.removeItem(at: root)
    }
}

private struct LegacyAgentConfiguration: Encodable {
    let schemaVersion: Int
    let hubURL: URL
    let deviceID: String
    let deviceName: String
    let uploadToken: String
    let encryptionKey: String
}
