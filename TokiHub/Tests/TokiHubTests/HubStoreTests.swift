import Foundation
import TokiDurableStorage
import TokiSyncProtocol
import XCTest
@testable import TokiHubCore
#if os(Linux)
    import Glibc
#else
    import Darwin
#endif

final class HubStoreTests: XCTestCase {
    func test_configurationRejectsRelativeStoragePathAndMalformedPort() {
        let ownerToken = String(repeating: "o", count: 48)
        XCTAssertThrowsError(try HubConfiguration(environment: [
            "TOKI_HUB_OWNER_TOKEN": ownerToken,
            "TOKI_HUB_STORAGE_PATH": "relative/storage",
        ]))
        XCTAssertThrowsError(try HubConfiguration(environment: [
            "TOKI_HUB_OWNER_TOKEN": ownerToken,
            "TOKI_HUB_STORAGE_PATH": "/tmp/toki-hub",
            "PORT": "not-a-port",
        ]))
        XCTAssertThrowsError(try HubConfiguration(environment: [
            "TOKI_HUB_OWNER_TOKEN": ownerToken,
            "TOKI_HUB_STORAGE_PATH": "/",
        ]))
    }

    func test_configurationUsesUnixSocketAndRejectsMixedBindSettings() throws {
        let ownerToken = String(repeating: "o", count: 48)
        let socketPath = "/run/toki-hub/toki-hub.sock"
        let configuration = try HubConfiguration(environment: [
            "TOKI_HUB_OWNER_TOKEN": ownerToken,
            "TOKI_HUB_STORAGE_PATH": "/var/lib/toki-hub",
            "TOKI_HUB_SOCKET_PATH": socketPath,
        ])

        XCTAssertEqual(
            configuration.bindTarget,
            .unixSocket(URL(fileURLWithPath: socketPath).standardizedFileURL))
        XCTAssertThrowsError(try HubConfiguration(environment: [
            "TOKI_HUB_OWNER_TOKEN": ownerToken,
            "TOKI_HUB_STORAGE_PATH": "/var/lib/toki-hub",
            "TOKI_HUB_SOCKET_PATH": socketPath,
            "PORT": "8080",
        ]))
    }

    func test_socketPreparationRejectsExistingSocketAndPreservesUnexpectedFiles() throws {
        let fixture = HubTestFixture(root: URL(fileURLWithPath:
            "/tmp/toki-hub-socket-\(UUID().uuidString.prefix(8))"))
        defer { fixture.remove() }
        let socketURL = fixture.root.appendingPathComponent("run/toki-hub.sock")
        try createStaleUnixSocket(at: socketURL)

        XCTAssertThrowsError(try prepareSocketDirectory(for: socketURL))

        XCTAssertEqual(
            try FileManager.default.attributesOfItem(atPath: socketURL.path)[.type] as? FileAttributeType,
            .typeSocket)
        let unexpected = Data("keep".utf8)
        try FileManager.default.removeItem(at: socketURL)
        try unexpected.write(to: socketURL)
        XCTAssertThrowsError(try prepareSocketDirectory(for: socketURL))
        XCTAssertEqual(try Data(contentsOf: socketURL), unexpected)
    }

    func test_storeAuthenticatesAndEnforcesSequenceRules() async throws {
        let fixture = makeHubFixture()
        defer { fixture.remove() }
        let store = try HubStore(directory: fixture.root)
        let device = try await store.createDevice(name: "ubuntu")
        let first = makeHubEnvelope(deviceID: device.deviceID, sequence: 1, payload: "first")

        await XCTAssertThrowsErrorAsync {
            try await store.store(first, deviceID: device.deviceID, uploadToken: SnapshotCipher.randomToken())
        }
        try await store.store(first, deviceID: device.deviceID, uploadToken: device.uploadToken)
        try await store.store(first, deviceID: device.deviceID, uploadToken: device.uploadToken)

        let conflict = makeHubEnvelope(deviceID: device.deviceID, sequence: 1, payload: "different")
        await XCTAssertThrowsErrorAsync {
            try await store.store(conflict, deviceID: device.deviceID, uploadToken: device.uploadToken)
        }

        let second = makeHubEnvelope(deviceID: device.deviceID, sequence: 2, payload: "second")
        try await store.store(second, deviceID: device.deviceID, uploadToken: device.uploadToken)
        await XCTAssertThrowsErrorAsync {
            try await store.store(first, deviceID: device.deviceID, uploadToken: device.uploadToken)
        }
        let storedSnapshots = try await store.snapshots()
        XCTAssertEqual(storedSnapshots, [second])
    }

    func test_heartbeatUpdatesFreshnessWithoutChangingSnapshotVersion() async throws {
        let fixture = makeHubFixture()
        defer { fixture.remove() }
        let store = try HubStore(directory: fixture.root)
        let uploadTime = Date(timeIntervalSince1970: 1_760_000_000)
        let heartbeatTime = uploadTime.addingTimeInterval(60)
        let device = try await store.createDevice(
            name: "ubuntu",
            syncIntervalSeconds: TokiSyncLimits.minimumSyncIntervalSeconds,
            now: uploadTime)
        let snapshot = makeHubEnvelope(deviceID: device.deviceID, sequence: 1, payload: "ciphertext")
        try await store.store(
            snapshot,
            deviceID: device.deviceID,
            uploadToken: device.uploadToken,
            now: uploadTime)
        let snapshotVersion = await store.snapshotVersionTag()
        let manifestVersion = await store.manifestVersionTag()

        try await store.heartbeat(
            deviceID: device.deviceID,
            uploadToken: device.uploadToken,
            latestSequence: 1,
            now: heartbeatTime)

        let summaries = await store.devices()
        let summary = try XCTUnwrap(summaries.first)
        let currentSnapshotVersion = await store.snapshotVersionTag()
        let currentManifestVersion = await store.manifestVersionTag()
        XCTAssertEqual(summary.lastSeenAt, heartbeatTime)
        XCTAssertEqual(summary.syncIntervalSeconds, TokiSyncLimits.minimumSyncIntervalSeconds)
        XCTAssertEqual(currentSnapshotVersion, snapshotVersion)
        XCTAssertNotEqual(currentManifestVersion, manifestVersion)
        await XCTAssertThrowsErrorAsync {
            try await store.heartbeat(
                deviceID: device.deviceID,
                uploadToken: device.uploadToken,
                latestSequence: 2,
                now: heartbeatTime)
        }
        await XCTAssertThrowsErrorAsync {
            try await store.heartbeat(
                deviceID: device.deviceID,
                uploadToken: SnapshotCipher.randomToken(),
                latestSequence: 1,
                now: heartbeatTime)
        }
    }

    func test_revokePersistsBeforeCredentialBecomesInvalid() async throws {
        let fixture = makeHubFixture()
        defer { fixture.remove() }
        let (device, snapshot) = try await withTemporaryHubStore(at: fixture.root) { store in
            let device = try await store.createDevice(name: "build-server")
            let snapshot = makeHubEnvelope(deviceID: device.deviceID, sequence: 1, payload: "ciphertext")
            try await store.store(snapshot, deviceID: device.deviceID, uploadToken: device.uploadToken)
            try await store.revokeDevice(device.deviceID)
            try await store.revokeDevice(device.deviceID)
            return (device, snapshot)
        }

        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.root
                .appendingPathComponent("snapshots")
                .appendingPathComponent("\(device.deviceID).json").path))

        try await withTemporaryHubStore(at: fixture.root) { store in
            await XCTAssertThrowsErrorAsync {
                try await store.store(snapshot, deviceID: device.deviceID, uploadToken: device.uploadToken)
            }
            let devices = await store.devices()
            let snapshots = try await store.snapshots()
            XCTAssertTrue(devices.isEmpty)
            XCTAssertTrue(snapshots.isEmpty)
        }
    }

    func test_snapshotReportsCorruptionWhenRegisteredEnvelopeIsMissing() async throws {
        let fixture = makeHubFixture()
        defer { fixture.remove() }
        let store = try HubStore(directory: fixture.root)
        let device = try await store.createDevice(name: "ubuntu")
        let snapshot = makeHubEnvelope(deviceID: device.deviceID, sequence: 1, payload: "ciphertext")
        try await store.store(snapshot, deviceID: device.deviceID, uploadToken: device.uploadToken)
        try FileManager.default.removeItem(at: fixture.root
            .appendingPathComponent("snapshots")
            .appendingPathComponent("\(device.deviceID).json"))

        do {
            _ = try await store.snapshot(deviceID: device.deviceID)
            XCTFail("Expected snapshot lookup to report corrupted storage")
        } catch {
            guard let storeError = error as? HubStoreError,
                  case .corruptedStorage = storeError else {
                return XCTFail("Expected corruptedStorage, got \(error)")
            }
        }
    }
}

final class HubStorePersistenceTests: XCTestCase {
    func test_snapshotStorageContainsCiphertextButNotPlaintextUsage() async throws {
        let fixture = makeHubFixture()
        defer { fixture.remove() }
        let store = try HubStore(directory: fixture.root)
        let device = try await store.createDevice(name: "ubuntu")
        let key = SnapshotCipher.generateKey()
        let generatedAt = Date(timeIntervalSince1970: 1_750_000_000)
        let snapshot = RemoteUsageSnapshot(
            device: RemoteDeviceDescriptor(id: device.deviceID, name: "ubuntu", platform: "linux"),
            generatedAt: generatedAt,
            coveredFrom: generatedAt.addingTimeInterval(-60),
            coveredTo: generatedAt.addingTimeInterval(1),
            tokenEvents: [
                RemoteTokenEvent(
                    timestamp: generatedAt.addingTimeInterval(-1),
                    source: "Codex",
                    model: "private-model-name",
                    inputTokens: 1,
                    outputTokens: 2,
                    cacheReadTokens: 0,
                    cacheWriteTokens: 0,
                    reasoningTokens: 0),
            ],
            activityEvents: [])
        let envelope = try SnapshotCipher.seal(snapshot, sequence: 1, key: key)
        try await store.store(envelope, deviceID: device.deviceID, uploadToken: device.uploadToken)

        let storedData = try Data(contentsOf: fixture.root
            .appendingPathComponent("snapshots")
            .appendingPathComponent("\(device.deviceID).json"))
        let storedText = try XCTUnwrap(String(data: storedData, encoding: .utf8))
        XCTAssertFalse(storedText.contains("private-model-name"))
        XCTAssertFalse(storedText.contains("Codex"))
    }

    func test_restartRecoversSnapshotWrittenBeforeRegistryUpdate() async throws {
        let fixture = makeHubFixture()
        defer { fixture.remove() }
        let device = try await withTemporaryHubStore(at: fixture.root) { store in
            let device = try await store.createDevice(name: "ubuntu")
            let first = makeHubEnvelope(deviceID: device.deviceID, sequence: 1, payload: "first")
            try await store.store(first, deviceID: device.deviceID, uploadToken: device.uploadToken)
            return device
        }

        let second = makeHubEnvelope(deviceID: device.deviceID, sequence: 2, payload: "second")
        let snapshotURL = fixture.root
            .appendingPathComponent("snapshots")
            .appendingPathComponent("\(device.deviceID).json")
        try TokiSyncCoding.makeEncoder().encode(second).write(to: snapshotURL, options: .atomic)

        try await withTemporaryHubStore(at: fixture.root) { store in
            let recoveredSnapshots = try await store.snapshots()
            XCTAssertEqual(recoveredSnapshots, [second])
            let recoveredDevices = await store.devices()
            XCTAssertEqual(recoveredDevices.first?.latestSequence, 2)
        }
    }

    func test_restartRemovesOrphanedSnapshot() throws {
        let fixture = makeHubFixture()
        defer { fixture.remove() }
        let snapshotsDirectory = fixture.root.appendingPathComponent("snapshots")
        try FileManager.default.createDirectory(at: snapshotsDirectory, withIntermediateDirectories: true)
        try Data(#"{"devices":{}}"#.utf8).write(
            to: fixture.root.appendingPathComponent("devices.json"))
        let orphanURL = snapshotsDirectory.appendingPathComponent("orphan-device.json")
        try Data("orphaned ciphertext".utf8).write(to: orphanURL)

        _ = try HubStore(directory: fixture.root)

        XCTAssertFalse(FileManager.default.fileExists(atPath: orphanURL.path))
    }

    func test_startupPreservesSnapshotsWhenRegistryIsMissing() throws {
        let fixture = makeHubFixture()
        defer { fixture.remove() }
        let snapshotsDirectory = fixture.root.appendingPathComponent("snapshots")
        try FileManager.default.createDirectory(at: snapshotsDirectory, withIntermediateDirectories: true)
        let snapshotURL = snapshotsDirectory.appendingPathComponent("preserved-device.json")
        let expectedData = Data("preserved ciphertext".utf8)
        try expectedData.write(to: snapshotURL)

        XCTAssertThrowsError(try HubStore(directory: fixture.root)) { error in
            guard let storeError = error as? HubStoreError,
                  case .corruptedStorage = storeError else {
                return XCTFail("Expected corruptedStorage, got \(error)")
            }
        }
        XCTAssertEqual(try Data(contentsOf: snapshotURL), expectedData)
    }

    func test_restartRefusesSpecialOrphanWithoutRecursiveDeletion() throws {
        let fixture = makeHubFixture()
        defer { fixture.remove() }
        let specialURL = fixture.root
            .appendingPathComponent("snapshots")
            .appendingPathComponent("orphan-device.json")
        let childURL = specialURL.appendingPathComponent("keep.txt")
        try FileManager.default.createDirectory(at: specialURL, withIntermediateDirectories: true)
        try Data(#"{"devices":{}}"#.utf8).write(
            to: fixture.root.appendingPathComponent("devices.json"))
        try Data("keep".utf8).write(to: childURL)

        XCTAssertThrowsError(try HubStore(directory: fixture.root)) { error in
            guard let storeError = error as? HubStoreError,
                  case .corruptedStorage = storeError else {
                return XCTFail("Expected corruptedStorage, got \(error)")
            }
        }
        XCTAssertEqual(try Data(contentsOf: childURL), Data("keep".utf8))
    }

    func test_startupRejectsSymbolicLinkRegistryBeforeOrphanCleanup() throws {
        let fixture = makeHubFixture()
        defer { fixture.remove() }
        let snapshotsDirectory = fixture.root.appendingPathComponent("snapshots")
        try FileManager.default.createDirectory(at: snapshotsDirectory, withIntermediateDirectories: true)
        let orphanURL = snapshotsDirectory.appendingPathComponent("orphan-device.json")
        try Data("orphaned ciphertext".utf8).write(to: orphanURL)
        let targetURL = fixture.root.appendingPathComponent("unexpected-registry.json")
        try Data("{}".utf8).write(to: targetURL)
        try FileManager.default.createSymbolicLink(
            at: fixture.root.appendingPathComponent("devices.json"),
            withDestinationURL: targetURL)

        XCTAssertThrowsError(try HubStore(directory: fixture.root))
        XCTAssertTrue(FileManager.default.fileExists(atPath: orphanURL.path))
        XCTAssertEqual(try Data(contentsOf: targetURL), Data("{}".utf8))
    }
}

final class HubStoreDurabilityTests: XCTestCase {
    func test_createDeviceReturnsTokenAfterCommittedRegistrySyncFailure() async throws {
        let fixture = makeHubFixture()
        defer { fixture.remove() }
        let store = try HubStore(directory: fixture.root) { data, url in
            try DurableFileIO.writePrivate(data, to: url)
            throw DurableFileIOError.replacementCommittedDirectorySyncFailed
        }

        let device = try await store.createDevice(name: "ubuntu")

        try await store.authorizeDevice(device.deviceID, uploadToken: device.uploadToken)
        let devices = await store.devices()
        XCTAssertEqual(devices.map(\.id), [device.deviceID])
        let registryText = try String(
            contentsOf: fixture.root.appendingPathComponent("devices.json"),
            encoding: .utf8)
        XCTAssertFalse(registryText.contains(device.uploadToken))
    }

    func test_hubClassifiesAlreadyCommittedFileMutationsAsUnconfirmed() throws {
        let fixture = makeHubFixture()
        defer { fixture.remove() }
        let url = fixture.root.appendingPathComponent("committed.json")
        try FileManager.default.createDirectory(at: fixture.root, withIntermediateDirectories: true)

        let writeOutcome = try HubStore.writePrivate(Data("new".utf8), to: url) { data, destination in
            try data.write(to: destination)
            throw DurableFileIOError.replacementCommittedDirectorySyncFailed
        }
        XCTAssertEqual(writeOutcome, .committedButUnconfirmed)
        XCTAssertEqual(try Data(contentsOf: url), Data("new".utf8))
        XCTAssertThrowsError(try HubStore.requireSynchronized(writeOutcome)) { error in
            guard let storeError = error as? HubStoreError,
                  case .storageDurabilityUnconfirmed = storeError else {
                return XCTFail("Expected storageDurabilityUnconfirmed, got \(error)")
            }
        }

        let removeOutcome = try HubStore.removePrivateFileIfPresent(url) { destination in
            try FileManager.default.removeItem(at: destination)
            throw DurableFileIOError.removalCommittedDirectorySyncFailed
        }
        XCTAssertEqual(removeOutcome, .committedButUnconfirmed)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
        XCTAssertNoThrow(try HubStore.requireSynchronized(.synchronized))
    }

    func test_hubConfirmsCommittedSnapshotDirectoryBeforeRegistryCanAdvance() throws {
        let fixture = makeHubFixture()
        defer { fixture.remove() }
        var synchronizedDirectories: [URL] = []

        try HubStore.confirmCommittedMutation(
            .committedButUnconfirmed,
            in: fixture.root) { directory in
                synchronizedDirectories.append(directory)
            }
        XCTAssertEqual(synchronizedDirectories, [fixture.root])

        XCTAssertThrowsError(try HubStore.confirmCommittedMutation(
            .committedButUnconfirmed,
            in: fixture.root,
            synchronizer: { _ in throw HubDurabilityTestError.expected })) { error in
                guard let storeError = error as? HubStoreError,
                      case .storageDurabilityUnconfirmed = storeError else {
                    return XCTFail("Expected storageDurabilityUnconfirmed, got \(error)")
                }
            }
    }

    func test_storageLockRejectsConcurrentHubStores() throws {
        let fixture = makeHubFixture()
        defer { fixture.remove() }
        let store = try HubStore(directory: fixture.root)

        XCTAssertThrowsError(try HubStore(directory: fixture.root)) { error in
            XCTAssertTrue(error is HubStorageLockError)
        }
        withExtendedLifetime(store) {}
    }

    func test_storageLockRefusesSymbolicLink() throws {
        let fixture = makeHubFixture()
        defer { fixture.remove() }
        try FileManager.default.createDirectory(at: fixture.root, withIntermediateDirectories: true)
        let targetURL = fixture.root.appendingPathComponent("lock-target")
        let expectedData = Data("unchanged".utf8)
        try expectedData.write(to: targetURL)
        try FileManager.default.createSymbolicLink(
            at: fixture.root.appendingPathComponent(".hub.lock"),
            withDestinationURL: targetURL)

        XCTAssertThrowsError(try HubStore(directory: fixture.root)) { error in
            XCTAssertTrue(error is HubStorageLockError)
        }
        XCTAssertEqual(try Data(contentsOf: targetURL), expectedData)
    }

    func test_startupRemovesRecognizedCrashTemporaryFiles() throws {
        let fixture = makeHubFixture()
        defer { fixture.remove() }
        let snapshotsDirectory = fixture.root.appendingPathComponent("snapshots")
        try FileManager.default.createDirectory(at: snapshotsDirectory, withIntermediateDirectories: true)
        let identifier = UUID().uuidString
        let temporaryURLs = [
            fixture.root.appendingPathComponent(".devices.json.\(identifier).tmp"),
            snapshotsDirectory.appendingPathComponent(".device-1.json.\(identifier).tmp"),
        ]
        for url in temporaryURLs {
            try Data("stale durable data".utf8).write(to: url)
        }
        let unrelatedURL = fixture.root.appendingPathComponent(".unrelated.\(identifier).tmp")
        try Data("keep".utf8).write(to: unrelatedURL)

        let store = try HubStore(directory: fixture.root)

        XCTAssertTrue(temporaryURLs.allSatisfy { !FileManager.default.fileExists(atPath: $0.path) })
        XCTAssertTrue(FileManager.default.fileExists(atPath: unrelatedURL.path))
        withExtendedLifetime(store) {}
    }

    func test_stoppedStoreBackupCanBeRestored() async throws {
        let fixture = makeHubFixture()
        let backup = fixture.root.deletingLastPathComponent()
            .appendingPathComponent("toki-hub-backup-tests-\(UUID().uuidString)")
        defer {
            fixture.remove()
            try? FileManager.default.removeItem(at: backup)
        }
        let expected = try await withTemporaryHubStore(at: fixture.root) { store in
            let device = try await store.createDevice(name: "ubuntu")
            let snapshot = makeHubEnvelope(deviceID: device.deviceID, sequence: 1, payload: "ciphertext")
            try await store.store(snapshot, deviceID: device.deviceID, uploadToken: device.uploadToken)
            return (device, snapshot)
        }

        try FileManager.default.copyItem(at: fixture.root, to: backup)
        try FileManager.default.removeItem(at: fixture.root)
        try FileManager.default.copyItem(at: backup, to: fixture.root)

        try await withTemporaryHubStore(at: fixture.root) { store in
            let snapshots = try await store.snapshots()
            XCTAssertEqual(snapshots, [expected.1])
            let devices = await store.devices()
            let restoredDevice = try XCTUnwrap(devices.first)
            XCTAssertEqual(restoredDevice.id, expected.0.deviceID)
            XCTAssertEqual(restoredDevice.latestSequence, expected.1.sequence)
        }
    }
}

private enum HubDurabilityTestError: Error {
    case expected
}

private enum HubSocketTestError: Error {
    case couldNotCreateSocket
    case socketPathTooLong
    case couldNotBindSocket
}

private struct HubTestFixture {
    let root: URL

    func remove() {
        try? FileManager.default.removeItem(at: root)
    }
}

private func makeHubEnvelope(deviceID: String, sequence: UInt64, payload: String) -> EncryptedUsageEnvelope {
    EncryptedUsageEnvelope(
        deviceID: deviceID,
        sequence: sequence,
        generatedAt: Date(timeIntervalSince1970: 1_750_000_000.123_456),
        payload: Data(payload.utf8).base64EncodedString())
}

private func createStaleUnixSocket(at url: URL) throws {
    try FileManager.default.createDirectory(
        at: url.deletingLastPathComponent(),
        withIntermediateDirectories: true)
    #if os(Linux)
        let descriptor = Glibc.socket(AF_UNIX, Int32(SOCK_STREAM.rawValue), 0)
    #else
        let descriptor = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
    #endif
    guard descriptor >= 0 else { throw HubSocketTestError.couldNotCreateSocket }
    defer {
        #if os(Linux)
            _ = Glibc.close(descriptor)
        #else
            _ = Darwin.close(descriptor)
        #endif
    }

    var address = sockaddr_un()
    address.sun_family = sa_family_t(AF_UNIX)
    let pathData = Data(url.path.utf8) + Data([0])
    let copied = withUnsafeMutableBytes(of: &address.sun_path) { buffer -> Bool in
        guard pathData.count <= buffer.count else { return false }
        pathData.copyBytes(to: buffer)
        return true
    }
    guard copied else { throw HubSocketTestError.socketPathTooLong }
    let result = withUnsafePointer(to: &address) { pointer in
        pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { socketAddress in
            #if os(Linux)
                Glibc.bind(descriptor, socketAddress, socklen_t(MemoryLayout<sockaddr_un>.size))
            #else
                Darwin.bind(descriptor, socketAddress, socklen_t(MemoryLayout<sockaddr_un>.size))
            #endif
        }
    }
    guard result == 0 else { throw HubSocketTestError.couldNotBindSocket }
}

private func makeHubFixture() -> HubTestFixture {
    HubTestFixture(root: FileManager.default.temporaryDirectory
        .appendingPathComponent("toki-hub-tests-\(UUID().uuidString)"))
}

private func withTemporaryHubStore<Value>(
    at directory: URL,
    _ operation: (HubStore) async throws -> Value) async throws -> Value {
    let store = try HubStore(directory: directory)
    return try await operation(store)
}

private func XCTAssertThrowsErrorAsync(
    _ expression: () async throws -> Void,
    file: StaticString = #filePath,
    line: UInt = #line) async {
    do {
        try await expression()
        XCTFail("Expected expression to throw", file: file, line: line)
    } catch {}
}
