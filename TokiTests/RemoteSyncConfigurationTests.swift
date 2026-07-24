import Foundation
import TokiSyncProtocol
import XCTest
@testable import Toki

extension RemoteUsageReaderTests {
    func test_equivalentHubURLsShareSnapshotCacheIdentifier() throws {
        let ownerToken = String(repeating: "o", count: 32)
        let spellings = [
            "https://hub.example.test",
            "https://HUB.EXAMPLE.TEST/",
            "https://hub.example.test:443/",
        ]
        let identifiers = try spellings.map { spelling in
            try RemoteHubConfiguration(
                hubURL: XCTUnwrap(URL(string: spelling)),
                ownerToken: ownerToken).snapshotCacheIdentifier
        }

        XCTAssertEqual(Set(identifiers).count, 1)
    }

    func test_localAgentIdentityProviderMatchesCanonicalHubOrigin() throws {
        let root = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let configurationURL = root.appendingPathComponent("config.json")
        let data = try JSONSerialization.data(withJSONObject: [
            "schemaVersion": TokiSyncProtocolVersion.current,
            "hubURL": "https://HUB.EXAMPLE.TEST:443/",
            "deviceID": "local-device",
        ])
        try data.write(to: configurationURL)
        let provider = LocalAgentIdentityProvider(configurationURL: configurationURL)

        XCTAssertEqual(
            try provider.deviceID(matching: XCTUnwrap(URL(string: "https://hub.example.test"))),
            "local-device")
        XCTAssertNil(try provider.deviceID(matching: XCTUnwrap(URL(string: "https://other.example.test"))))
    }

    func test_hubURLAndOwnerTokenRemainBoundInOneKeychainRecord() throws {
        let suiteName = "RemoteUsageReaderTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let keychain = InMemoryKeychainCredentialStore()
        let store = RemoteSyncConfigurationStore(defaults: defaults, keychain: keychain)
        let configuration = try RemoteHubConfiguration(
            hubURL: XCTUnwrap(URL(string: "https://trusted.example.test")),
            ownerToken: String(repeating: "o", count: 32))
        try store.save(configuration)

        defaults.set("https://attacker.example.test", forKey: "remoteSync.hubURL")

        XCTAssertEqual(try store.load(), configuration)
        XCTAssertEqual(keychain.savedAccounts, ["hub-configuration-v2"])
    }

    func test_legacySplitHubCredentialsFailClosed() throws {
        let suiteName = "RemoteUsageReaderTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set("https://legacy.example.test", forKey: "remoteSync.hubURL")
        let keychain = InMemoryKeychainCredentialStore()
        try keychain.save(String(repeating: "o", count: 32), account: "owner-token")
        let store = RemoteSyncConfigurationStore(defaults: defaults, keychain: keychain)

        XCTAssertThrowsError(try store.load()) { error in
            guard let configurationError = error as? RemoteSyncConfigurationError,
                  case .incompleteCredentials = configurationError else {
                return XCTFail("Expected incompleteCredentials, got \(error)")
            }
        }
    }

    func test_oversizedHubCredentialRecordFailsClosed() throws {
        let suiteName = "RemoteUsageReaderTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let keychain = InMemoryKeychainCredentialStore()
        try keychain.save(
            String(repeating: "A", count: TokiSyncLimits.maximumConfigurationFileBytes + 1),
            account: "hub-configuration-v2")
        let store = RemoteSyncConfigurationStore(defaults: defaults, keychain: keychain)

        XCTAssertThrowsError(try store.load()) { error in
            guard let configurationError = error as? RemoteSyncConfigurationError,
                  case .invalidStoredConfiguration = configurationError else {
                return XCTFail("Expected invalidStoredConfiguration, got \(error)")
            }
        }
    }

    func test_configurationClearRemovesDeviceKeyMissingFromDefaultsIndex() throws {
        let suiteName = "RemoteUsageReaderTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let keychain = InMemoryKeychainCredentialStore()
        try keychain.save(SnapshotCipher.generateKey(), account: "device-key:orphan-device")
        let store = RemoteSyncConfigurationStore(defaults: defaults, keychain: keychain)

        try store.clear()

        XCTAssertTrue(keychain.savedAccounts.isEmpty)
    }

    func test_configurationRejectsOversizedStoredDeviceKey() throws {
        let suiteName = "RemoteUsageReaderTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let keychain = InMemoryKeychainCredentialStore()
        try keychain.save(String(repeating: "A", count: 129), account: "device-key:device-1")
        let store = RemoteSyncConfigurationStore(defaults: defaults, keychain: keychain)

        XCTAssertThrowsError(try store.encryptionKey(for: "device-1")) { error in
            guard let configurationError = error as? RemoteSyncConfigurationError,
                  case .invalidStoredEncryptionKey = configurationError else {
                return XCTFail("Expected invalidStoredEncryptionKey, got \(error)")
            }
        }
    }

    func test_configurationClearDoesNotIgnoreLegacySecretDeletionFailure() throws {
        let suiteName = "RemoteUsageReaderTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let keychain = InMemoryKeychainCredentialStore()
        let store = RemoteSyncConfigurationStore(defaults: defaults, keychain: keychain)
        let configuration = try RemoteHubConfiguration(
            hubURL: XCTUnwrap(URL(string: "https://trusted.example.test")),
            ownerToken: String(repeating: "o", count: 32))
        try store.save(configuration)
        try keychain.save(String(repeating: "l", count: 32), account: "owner-token")
        keychain.failingDeleteAccounts = ["owner-token"]

        XCTAssertThrowsError(try store.clear())
        XCTAssertEqual(try store.load(), configuration)
        XCTAssertTrue(keychain.savedAccounts.contains("owner-token"))
        XCTAssertTrue(keychain.savedAccounts.contains("hub-configuration-v2"))
    }

    func test_manifestRejectsFreshnessWithoutSnapshotSequence() {
        let device = RemoteDeviceSummary(
            id: "device-1",
            name: "ubuntu",
            createdAt: Date(),
            lastSeenAt: Date(),
            latestSequence: nil)

        XCTAssertThrowsError(try RemoteHubClient.validateDeviceList([device]))
    }

    func test_remoteHubClientRejectsInvalidProvisioningResponse() {
        let response = CreateRemoteDeviceResponse(
            deviceID: "../unexpected-path",
            deviceName: "ubuntu",
            uploadToken: String(repeating: "u", count: 32))

        XCTAssertThrowsError(try RemoteHubClient.validateCreatedDevice(response))
    }

    func test_remoteHubClientRejectsDuplicateDeviceListEntries() {
        let device = RemoteDeviceSummary(
            id: "device-1",
            name: "ubuntu",
            createdAt: Date(),
            lastSeenAt: nil,
            latestSequence: nil)

        XCTAssertThrowsError(try RemoteHubClient.validateDeviceList([device, device]))
    }

    func test_remoteHubClientFetchesInitialManifestWithoutConditionalStatus() async throws {
        let configuration = try RemoteHubConfiguration(
            hubURL: XCTUnwrap(URL(string: "https://hub.example.test")),
            ownerToken: String(repeating: "o", count: 32))
        let sessionConfiguration = URLSessionConfiguration.ephemeral
        sessionConfiguration.protocolClasses = [RemoteHubURLProtocolStub.self]
        let expectedEntityTag = entityTag("a")
        RemoteHubURLProtocolStub.install { request in
            XCTAssertNil(request.value(forHTTPHeaderField: "If-None-Match"))
            let response = try XCTUnwrap(HTTPURLResponse(
                url: XCTUnwrap(request.url),
                statusCode: 200,
                httpVersion: nil,
                headerFields: ["ETag": expectedEntityTag]))
            return (response, Data(#"{"devices":[]}"#.utf8))
        }
        defer { RemoteHubURLProtocolStub.reset() }

        let result = try await RemoteHubClient(sessionConfiguration: sessionConfiguration)
            .fetchSnapshotManifest(configuration: configuration, ifNoneMatch: nil)

        switch result {
        case let .modified(devices, entityTag):
            XCTAssertTrue(devices.isEmpty)
            XCTAssertEqual(entityTag, expectedEntityTag)
        case .notModified:
            XCTFail("Expected an initial manifest response")
        }
    }

    func test_remoteResponseAccumulatorRejectsUnexpectedSuccessfulStatus() throws {
        let url = try XCTUnwrap(URL(string: "https://hub.example.test/v1/devices"))
        let response = try XCTUnwrap(HTTPURLResponse(
            url: url,
            statusCode: 200,
            httpVersion: nil,
            headerFields: nil))
        var accumulator = RemoteResponseAccumulator(
            expectedURL: url,
            maximumBytes: 64,
            allowedStatusCodes: [201])

        XCTAssertThrowsError(try accumulator.receive(response)) { error in
            guard let clientError = error as? RemoteHubClientError,
                  case .httpStatus(200) = clientError else {
                return XCTFail("Expected httpStatus(200), got \(error)")
            }
        }
    }

    func test_remoteResponseAccumulatorRejectsBodyForNoContentStatus() throws {
        let url = try XCTUnwrap(URL(string: "https://hub.example.test/v1/devices/device-1"))
        let response = try XCTUnwrap(HTTPURLResponse(
            url: url,
            statusCode: 204,
            httpVersion: nil,
            headerFields: nil))
        var accumulator = RemoteResponseAccumulator(
            expectedURL: url,
            maximumBytes: 64,
            allowedStatusCodes: [204],
            emptyBodyStatusCodes: [204])
        try accumulator.receive(response)

        XCTAssertThrowsError(try accumulator.receive(Data("unexpected".utf8))) { error in
            guard let clientError = error as? RemoteHubClientError,
                  case .invalidResponse = clientError else {
                return XCTFail("Expected invalidResponse, got \(error)")
            }
        }
    }
}
