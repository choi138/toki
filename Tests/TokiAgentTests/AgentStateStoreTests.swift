import Foundation
import TokiSyncProtocol
import XCTest
@testable import TokiAgentCore
@testable import TokiDurableStorage
@testable import TokiUsageReaders

final class AgentStateStoreTests: XCTestCase {
    func test_stateStoreFailsClosedForCorruptedState() throws {
        let fixture = try makeFixture()
        defer { fixture.remove() }
        try fixture.paths.prepare()
        try Data("not-json".utf8).write(to: fixture.paths.runtimeStateURL)

        XCTAssertThrowsError(try AgentStateStore(paths: fixture.paths).load()) { error in
            XCTAssertTrue(error is AgentStateStoreError)
        }
    }

    func test_stateAndConfigurationUsePrivatePermissions() throws {
        let fixture = try makeFixture()
        defer { fixture.remove() }
        let stateStore = AgentStateStore(paths: fixture.paths)
        try stateStore.save(AgentRuntimeState(latestSequence: 7))

        XCTAssertEqual(try stateStore.load().latestSequence, 7)
        let attributes = try FileManager.default.attributesOfItem(atPath: fixture.paths.runtimeStateURL.path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
    }

    func test_stateStoreRejectsUploadedDigestWithoutSequence() throws {
        let fixture = try makeFixture()
        defer { fixture.remove() }
        let state = AgentRuntimeState(
            latestSequence: 0,
            lastUploadedContentDigest: String(repeating: "a", count: 64))

        XCTAssertThrowsError(try AgentStateStore(paths: fixture.paths).save(state)) { error in
            XCTAssertTrue(error is AgentStateStoreError)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.paths.runtimeStateURL.path))
    }

    func test_stateStoreRejectsSourceSignatureWithoutUploadedDigest() throws {
        let fixture = try makeFixture()
        defer { fixture.remove() }
        let state = AgentRuntimeState(
            latestSequence: 1,
            lastSourceSignature: String(repeating: "b", count: 64))

        XCTAssertThrowsError(try AgentStateStore(paths: fixture.paths).save(state)) { error in
            XCTAssertTrue(error is AgentStateStoreError)
        }
    }

    func test_codexRolloutCacheUsesPrivatePermissions() throws {
        let fixture = try makeFixture()
        defer { fixture.remove() }
        let cacheURL = fixture.root.appendingPathComponent("cache/codex-rollout-cache.json")

        try writeCodexRolloutUsageCache(Data("{}".utf8), to: cacheURL)

        let fileAttributes = try FileManager.default.attributesOfItem(atPath: cacheURL.path)
        let directoryAttributes = try FileManager.default.attributesOfItem(
            atPath: cacheURL.deletingLastPathComponent().path)
        XCTAssertEqual((fileAttributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        XCTAssertEqual((directoryAttributes[.posixPermissions] as? NSNumber)?.intValue, 0o700)
    }

    func test_durableFileReplacementAndRemovalLeaveNoTemporaryFiles() throws {
        let fixture = try makeFixture()
        defer { fixture.remove() }
        let url = fixture.root.appendingPathComponent("durable/value.json")

        try DurableFileIO.writePrivate(Data("first".utf8), to: url)
        try DurableFileIO.writePrivate(Data("second".utf8), to: url)

        XCTAssertEqual(try Data(contentsOf: url), Data("second".utf8))
        let directoryEntries = try FileManager.default.contentsOfDirectory(
            at: url.deletingLastPathComponent(),
            includingPropertiesForKeys: nil)
        XCTAssertEqual(directoryEntries.map(\.lastPathComponent), ["value.json"])

        try DurableFileIO.removeIfPresent(url)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
        XCTAssertNoThrow(try DurableFileIO.removeIfPresent(url))
    }

    func test_durableFileRemovalRefusesToRecursivelyDeleteDirectory() throws {
        let fixture = try makeFixture()
        defer { fixture.remove() }
        let directory = fixture.root.appendingPathComponent("durable/value.json")
        let childURL = directory.appendingPathComponent("keep.txt")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data("keep".utf8).write(to: childURL)

        XCTAssertThrowsError(try DurableFileIO.removeIfPresent(directory))
        XCTAssertEqual(try Data(contentsOf: childURL), Data("keep".utf8))
    }

    func test_durableFileWriteDoesNotChangeExistingDirectoryPermissions() throws {
        let fixture = try makeFixture()
        defer { fixture.remove() }
        let directory = fixture.root.appendingPathComponent("shared")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: 0o755)],
            ofItemAtPath: directory.path)

        try DurableFileIO.writePrivate(Data("private".utf8), to: directory.appendingPathComponent("value"))

        let directoryAttributes = try FileManager.default.attributesOfItem(atPath: directory.path)
        let fileAttributes = try FileManager.default.attributesOfItem(
            atPath: directory.appendingPathComponent("value").path)
        XCTAssertEqual((directoryAttributes[.posixPermissions] as? NSNumber)?.intValue, 0o755)
        XCTAssertEqual((fileAttributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
    }

    func test_durablePrivateReadReturnsPrivateFileAndMissingFileSafely() throws {
        let fixture = try makeFixture()
        defer { fixture.remove() }
        let url = fixture.root.appendingPathComponent("durable/value.json")
        let expected = Data("private".utf8)
        try DurableFileIO.writePrivate(expected, to: url)

        XCTAssertEqual(
            try DurableFileIO.readPrivate(from: url, maximumByteCount: expected.count),
            expected)
        XCTAssertNil(try DurableFileIO.readPrivate(
            from: fixture.root.appendingPathComponent("missing.json"),
            maximumByteCount: 100))
    }

    func test_durablePrivateReadRejectsSymbolicLinkPermissionsAndOversizedFile() throws {
        let fixture = try makeFixture()
        defer { fixture.remove() }
        let targetURL = fixture.root.appendingPathComponent("target.json")
        try DurableFileIO.writePrivate(Data("target".utf8), to: targetURL)
        let symbolicLinkURL = fixture.root.appendingPathComponent("link.json")
        try FileManager.default.createSymbolicLink(at: symbolicLinkURL, withDestinationURL: targetURL)
        XCTAssertThrowsError(try DurableFileIO.readPrivate(from: symbolicLinkURL, maximumByteCount: 100))

        let publicURL = fixture.root.appendingPathComponent("public.json")
        try Data("public".utf8).write(to: publicURL)
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: publicURL.path)
        XCTAssertThrowsError(try DurableFileIO.readPrivate(from: publicURL, maximumByteCount: 100))

        XCTAssertThrowsError(try DurableFileIO.readPrivate(from: targetURL, maximumByteCount: 1)) { error in
            guard let storageError = error as? DurableFileIOError,
                  case .privateFileTooLarge = storageError else {
                return XCTFail("Expected privateFileTooLarge, got \(error)")
            }
        }
    }

    func test_durableFileErrorsDistinguishAlreadyCommittedMutations() throws {
        let fixture = try makeFixture()
        defer { fixture.remove() }
        let url = fixture.root.appendingPathComponent("durable/value.json")

        XCTAssertThrowsError(try DurableFileIO.writePrivate(
            Data("replacement".utf8),
            to: url,
            directorySynchronizer: { _ in throw DurableTestError.expected })) { error in
                guard let storageError = error as? DurableFileIOError,
                      case .replacementCommittedDirectorySyncFailed = storageError else {
                    return XCTFail("Expected committed replacement error, got \(error)")
                }
            }
        XCTAssertEqual(try Data(contentsOf: url), Data("replacement".utf8))

        XCTAssertThrowsError(try DurableFileIO.removeIfPresent(
            url,
            directorySynchronizer: { _ in throw DurableTestError.expected })) { error in
                guard let storageError = error as? DurableFileIOError,
                      case .removalCommittedDirectorySyncFailed = storageError else {
                    return XCTFail("Expected committed removal error, got \(error)")
                }
            }
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }
}

final class AgentProcessAndSpoolTests: XCTestCase {
    func test_spoolAcceptsRemovalThatAlreadyCommittedBeforeDirectorySyncFailed() throws {
        let fixture = try makeFixture()
        defer { fixture.remove() }
        try fixture.paths.prepare()
        let url = fixture.paths.spoolDirectory.appendingPathComponent("00000000000000000001.json")
        try Data("ciphertext".utf8).write(to: url)

        XCTAssertNoThrow(try AgentSpool(paths: fixture.paths).remove(url) { destination in
            try FileManager.default.removeItem(at: destination)
            throw DurableFileIOError.removalCommittedDirectorySyncFailed
        })
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }

    func test_processLockRejectsConcurrentAgentOperation() throws {
        let fixture = try makeFixture()
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

    func test_processLockRefusesSymbolicLink() throws {
        let fixture = try makeFixture()
        defer { fixture.remove() }
        try fixture.paths.prepare()
        let targetURL = fixture.root.appendingPathComponent("lock-target")
        let expectedData = Data("unchanged".utf8)
        try expectedData.write(to: targetURL)
        try FileManager.default.createSymbolicLink(
            at: fixture.paths.lockURL,
            withDestinationURL: targetURL)

        XCTAssertThrowsError(try AgentProcessLock.acquire(paths: fixture.paths)) { error in
            XCTAssertTrue(error is AgentProcessLockError)
        }
        XCTAssertEqual(try Data(contentsOf: targetURL), expectedData)
    }

    func test_agentRejectsSymbolicLinkConfigurationAndStateFiles() throws {
        let fixture = try makeFixture()
        defer { fixture.remove() }
        try fixture.paths.prepare()
        let targetURL = fixture.root.appendingPathComponent("unexpected.json")
        try Data("{}".utf8).write(to: targetURL)
        try FileManager.default.createSymbolicLink(
            at: fixture.paths.configurationURL,
            withDestinationURL: targetURL)
        try FileManager.default.createSymbolicLink(
            at: fixture.paths.runtimeStateURL,
            withDestinationURL: targetURL)

        XCTAssertThrowsError(try AgentConfigurationStore(paths: fixture.paths).load()) { error in
            XCTAssertTrue(error is AgentConfigurationError)
        }
        XCTAssertThrowsError(try AgentStateStore(paths: fixture.paths).load()) { error in
            XCTAssertTrue(error is AgentStateStoreError)
        }
    }

    func test_agentRejectsSymbolicLinkOwnedDirectory() throws {
        let fixture = try makeFixture()
        defer { fixture.remove() }
        let targetDirectory = fixture.root.appendingPathComponent("unexpected-directory")
        try FileManager.default.createDirectory(at: targetDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: fixture.paths.configurationDirectory.deletingLastPathComponent(),
            withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(
            at: fixture.paths.configurationDirectory,
            withDestinationURL: targetDirectory)

        XCTAssertThrowsError(try fixture.paths.prepare())
    }

    func test_processLockRemovesOnlyRecognizedStaleDurableTemporaryFiles() throws {
        let fixture = try makeFixture()
        defer { fixture.remove() }
        try fixture.paths.prepare()
        let identifier = UUID().uuidString
        let temporaryURLs = [
            fixture.paths.configurationDirectory.appendingPathComponent(".config.json.\(identifier).tmp"),
            fixture.paths.stateDirectory.appendingPathComponent(".state.json.\(identifier).tmp"),
            fixture.paths.spoolDirectory.appendingPathComponent(
                ".00000000000000000001.json.\(identifier).tmp"),
        ]
        for url in temporaryURLs {
            try Data("stale private data".utf8).write(to: url)
        }
        let unrelatedURL = fixture.paths.configurationDirectory.appendingPathComponent(".unrelated.\(identifier).tmp")
        try Data("keep".utf8).write(to: unrelatedURL)

        let processLock = try AgentProcessLock.acquire(paths: fixture.paths)

        XCTAssertTrue(temporaryURLs.allSatisfy { !FileManager.default.fileExists(atPath: $0.path) })
        XCTAssertTrue(FileManager.default.fileExists(atPath: unrelatedURL.path))
        withExtendedLifetime(processLock) {}
    }

    func test_spoolRejectsEnvelopeWhoseSequenceDoesNotMatchFilename() throws {
        let fixture = try makeFixture()
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

    func test_publicErrorDescriptionDoesNotExposeLocalPath() {
        let sensitivePath = "/private/sensitive/codex-state"
        let error = NSError(
            domain: NSCocoaErrorDomain,
            code: CocoaError.fileReadNoSuchFile.rawValue,
            userInfo: [NSFilePathErrorKey: sensitivePath])

        let description = AgentSyncService.publicErrorDescription(error)

        XCTAssertFalse(description.contains(sensitivePath))
    }
}

final class AgentConfigurationAndDiagnosticsTests: XCTestCase {
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

    func test_pairingInputReadsToEndAndRejectsOversizedData() throws {
        let fixture = try makeFixture()
        defer { fixture.remove() }
        try FileManager.default.createDirectory(at: fixture.root, withIntermediateDirectories: true)
        let validData = Data(repeating: 0x61, count: 12000)
        let validURL = fixture.root.appendingPathComponent("valid-input")
        try validData.write(to: validURL)
        let validHandle = try FileHandle(forReadingFrom: validURL)
        defer { try? validHandle.close() }

        XCTAssertEqual(try TokiAgentCommand.readPairingBundle(from: validHandle), validData)

        let oversizedURL = fixture.root.appendingPathComponent("oversized-input")
        try Data(
            repeating: 0x61,
            count: TokiSyncLimits.maximumPairingBundleBytes + 1).write(to: oversizedURL)
        let oversizedHandle = try FileHandle(forReadingFrom: oversizedURL)
        defer { try? oversizedHandle.close() }

        XCTAssertThrowsError(try TokiAgentCommand.readPairingBundle(from: oversizedHandle)) { error in
            guard let commandError = error as? AgentCommandError,
                  case .pairingBundleTooLarge = commandError else {
                return XCTFail("Expected pairingBundleTooLarge, got \(error)")
            }
        }
    }

    func test_doctorReportsCorruptedConfigurationInsteadOfNotConfigured() throws {
        let fixture = try makeFixture()
        defer { fixture.remove() }
        try fixture.paths.prepare()
        try Data("not-json".utf8).write(to: fixture.paths.configurationURL)

        XCTAssertThrowsError(try TokiAgentCommand.doctor(paths: fixture.paths))
    }

    func test_statusReportsCorruptedSpoolInsteadOfZeroPendingUploads() async throws {
        let fixture = try makeFixture()
        defer { fixture.remove() }
        let configuration = try AgentConfiguration(bundle: AgentPairingBundle(
            hubURL: XCTUnwrap(URL(string: "https://hub.example.test")),
            deviceID: "device-1",
            deviceName: "ubuntu",
            uploadToken: SnapshotCipher.randomToken(),
            encryptionKey: SnapshotCipher.generateKey()))
        try AgentConfigurationStore(paths: fixture.paths).save(configuration)
        try fixture.paths.prepare()
        try Data("not-json".utf8).write(
            to: fixture.paths.spoolDirectory.appendingPathComponent("00000000000000000001.json"))

        do {
            try await TokiAgentCommand.status(paths: fixture.paths)
            XCTFail("Expected corrupted spool to fail status")
        } catch {}
    }
}

extension AgentConfigurationAndDiagnosticsTests {
    func test_sourceDiagnosticsReportEveryReaderWithoutExposingPaths() throws {
        let fixture = try makeFixture()
        defer { fixture.remove() }
        let hermesURL = fixture.root.appendingPathComponent(".hermes/state.db")
        try FileManager.default.createDirectory(
            at: hermesURL.deletingLastPathComponent(),
            withIntermediateDirectories: true)
        try Data().write(to: hermesURL)

        let diagnostics = TokiAgentCommand.sourceDiagnostics(
            home: fixture.root,
            environment: [:])

        XCTAssertEqual(
            diagnostics.map(\.name),
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
        XCTAssertEqual(diagnostics.first(where: { $0.name == "Hermes" })?.status, .readable)
        XCTAssertTrue(diagnostics.filter { $0.name != "Hermes" }.allSatisfy { $0.status == .notFound })
        let output = diagnostics.map { "\($0.name): \($0.status.rawValue)" }.joined(separator: "\n")
        XCTAssertFalse(output.contains(fixture.root.path))
    }

    func test_doctorRequiresAtLeastOneReadableUsageSource() throws {
        let fixture = try makeFixture()
        defer { fixture.remove() }

        XCTAssertThrowsError(try TokiAgentCommand.doctor(
            paths: fixture.paths,
            home: fixture.root,
            environment: [:])) { error in
                guard let commandError = error as? AgentCommandError,
                      case .localUsageDataUnavailable = commandError else {
                    return XCTFail("Expected localUsageDataUnavailable, got \(error)")
                }
            }

        let hermesURL = fixture.root.appendingPathComponent(".hermes/state.db")
        try FileManager.default.createDirectory(
            at: hermesURL.deletingLastPathComponent(),
            withIntermediateDirectories: true)
        try Data().write(to: hermesURL)

        XCTAssertNoThrow(try TokiAgentCommand.doctor(
            paths: fixture.paths,
            home: fixture.root,
            environment: [:]))
    }
}

private func makeFixture() throws -> AgentTestFixture {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("toki-agent-tests-\(UUID().uuidString)")
    let environment = [
        "XDG_CONFIG_HOME": root.appendingPathComponent("config").path,
        "XDG_STATE_HOME": root.appendingPathComponent("state").path,
        "XDG_DATA_HOME": root.appendingPathComponent("data").path,
    ]
    return AgentTestFixture(root: root, paths: AgentPaths(environment: environment, home: root))
}

private struct AgentTestFixture {
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

private enum DurableTestError: Error {
    case expected
}
