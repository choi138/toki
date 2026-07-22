import Foundation
import TokiSyncProtocol
import XCTest
@testable import Toki

final class RemoteHubURLProtocolStub: URLProtocol {
    typealias Handler = (URLRequest) throws -> (HTTPURLResponse, Data)

    private static let lock = NSLock()
    private static var handler: Handler?

    static func install(handler: @escaping Handler) {
        lock.withLock { self.handler = handler }
    }

    static func reset() {
        lock.withLock { handler = nil }
    }

    override static func canInit(with _: URLRequest) -> Bool {
        true
    }

    override static func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        guard let handler = Self.lock.withLock({ Self.handler }) else {
            client?.urlProtocol(self, didFailWithError: TestError.unexpectedCall)
            return
        }

        do {
            let (response, data) = try handler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            if !data.isEmpty {
                client?.urlProtocol(self, didLoad: data)
            }
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}

struct StubRemoteConfigurationProvider: RemoteSyncConfigurationProviding {
    let configuration: RemoteHubConfiguration?
    let encryptionKeys: [String: String]

    func load() throws -> RemoteHubConfiguration? {
        configuration
    }

    func encryptionKey(for deviceID: String) throws -> String? {
        encryptionKeys[deviceID]
    }
}

final class FlakyRemoteConfigurationProvider: RemoteSyncConfigurationProviding {
    private let configuration: RemoteHubConfiguration
    private let storedEncryptionKey: String
    private var failuresRemaining: Int

    init(configuration: RemoteHubConfiguration, encryptionKey: String, failuresRemaining: Int) {
        self.configuration = configuration
        storedEncryptionKey = encryptionKey
        self.failuresRemaining = failuresRemaining
    }

    func load() throws -> RemoteHubConfiguration? {
        configuration
    }

    func encryptionKey(for _: String) throws -> String? {
        if failuresRemaining > 0 {
            failuresRemaining -= 1
            throw TestError.temporaryCredentialFailure
        }
        return storedEncryptionKey
    }
}

final class StubRemoteHubClient: RemoteHubClientProtocol {
    private let lock = NSLock()
    private let manifestResult: Result<RemoteConditionalResult<[RemoteDeviceSummary]>, Error>
    private let snapshotResult: Result<[EncryptedUsageEnvelope], Error>
    private var devicesResults: [Result<[RemoteDeviceSummary], Error>]
    private let delayNanoseconds: UInt64
    private var manifestCallCount = 0
    private var snapshotCallCount = 0
    private var manifestEntityTag: String?
    private var requestedSnapshotDeviceIDs: [String] = []
    private var revokedIDs: [String] = []

    init(
        manifestResult: Result<RemoteConditionalResult<[RemoteDeviceSummary]>, Error> =
            .failure(TestError.unexpectedCall),
        snapshotResult: Result<[EncryptedUsageEnvelope], Error> =
            .failure(TestError.unexpectedCall),
        devicesResult: Result<[RemoteDeviceSummary], Error> = .success([]),
        devicesResults: [Result<[RemoteDeviceSummary], Error>]? = nil,
        delayNanoseconds: UInt64 = 0) {
        self.manifestResult = manifestResult
        self.snapshotResult = snapshotResult
        if let devicesResults, !devicesResults.isEmpty {
            self.devicesResults = devicesResults
        } else {
            self.devicesResults = [devicesResult]
        }
        self.delayNanoseconds = delayNanoseconds
    }

    var fetchManifestCallCount: Int {
        lock.withLock { manifestCallCount }
    }

    var fetchSnapshotCallCount: Int {
        lock.withLock { snapshotCallCount }
    }

    var lastManifestEntityTag: String? {
        lock.withLock { manifestEntityTag }
    }

    var fetchedSnapshotDeviceIDs: [String] {
        lock.withLock { requestedSnapshotDeviceIDs }
    }

    var revokedDeviceIDs: [String] {
        lock.withLock { revokedIDs }
    }

    func fetchSnapshotManifest(
        configuration _: RemoteHubConfiguration,
        ifNoneMatch: String?) async throws -> RemoteConditionalResult<[RemoteDeviceSummary]> {
        lock.withLock {
            manifestCallCount += 1
            manifestEntityTag = ifNoneMatch
        }
        if delayNanoseconds > 0 {
            try await Task.sleep(nanoseconds: delayNanoseconds)
        }
        return try manifestResult.get()
    }

    func fetchSnapshot(
        configuration _: RemoteHubConfiguration,
        deviceID: String) async throws -> EncryptedUsageEnvelope {
        lock.withLock {
            snapshotCallCount += 1
            requestedSnapshotDeviceIDs.append(deviceID)
        }
        guard let envelope = try snapshotResult.get().first(where: { $0.deviceID == deviceID }) else {
            throw TestError.unexpectedCall
        }
        return envelope
    }

    func createDevice(
        name _: String,
        syncIntervalSeconds _: Int,
        configuration _: RemoteHubConfiguration) async throws -> CreateRemoteDeviceResponse {
        throw TestError.unexpectedCall
    }

    func fetchDevices(configuration _: RemoteHubConfiguration) async throws -> [RemoteDeviceSummary] {
        let result = lock.withLock {
            guard devicesResults.count > 1 else { return devicesResults[0] }
            return devicesResults.removeFirst()
        }
        return try result.get()
    }

    func revokeDevice(id: String, configuration _: RemoteHubConfiguration) async throws {
        lock.withLock { revokedIDs.append(id) }
    }
}

final class InMemoryRemoteSnapshotCache: RemoteSnapshotCaching {
    private var entry: RemoteSnapshotCacheEntry?
    private let clearError: Error?
    private(set) var saveCallCount = 0
    private(set) var loadCallCount = 0
    private(set) var clearCallCount = 0
    private(set) var savedChangedDeviceIDs: [Set<String>] = []

    init(entry: RemoteSnapshotCacheEntry? = nil, clearError: Error? = nil) {
        self.entry = entry
        self.clearError = clearError
    }

    func load() throws -> RemoteSnapshotCacheEntry? {
        loadCallCount += 1
        return entry
    }

    func save(_ entry: RemoteSnapshotCacheEntry, changedDeviceIDs: Set<String>) throws {
        saveCallCount += 1
        savedChangedDeviceIDs.append(changedDeviceIDs)
        self.entry = entry
    }

    func remove(deviceID: String) throws {
        guard let entry else { return }
        let envelopes = entry.envelopes.filter { $0.deviceID != deviceID }
        let manifest = entry.manifest.filter { $0.id != deviceID }
        self.entry = envelopes.isEmpty && manifest.isEmpty
            ? nil
            : RemoteSnapshotCacheEntry(
                envelopes: envelopes,
                manifest: manifest,
                fetchedAt: entry.fetchedAt,
                snapshotCacheIdentifier: entry.snapshotCacheIdentifier)
    }

    func clear() throws {
        clearCallCount += 1
        if let clearError { throw clearError }
        entry = nil
    }
}

final class InMemoryRemoteSnapshotAnchorStore: RemoteSnapshotAnchorStoring {
    private var anchorsByOrigin: [String: [String: RemoteSnapshotAnchor]] = [:]
    private(set) var removedDeviceIDs: [String] = []
    private(set) var clearCallCount = 0

    init(
        envelopes: [EncryptedUsageEnvelope] = [],
        originIdentifier: String? = nil) {
        guard let originIdentifier, !envelopes.isEmpty else { return }
        anchorsByOrigin[originIdentifier] = (try? RemoteSnapshotProgress.anchors(for: envelopes)) ?? [:]
    }

    func validateAndSave(
        _ envelopes: [EncryptedUsageEnvelope],
        originIdentifier: String) throws {
        var anchors = anchorsByOrigin[originIdentifier] ?? [:]
        let candidates = try RemoteSnapshotProgress.anchors(for: envelopes)
        try RemoteSnapshotProgress.validate(candidateAnchors: candidates, against: anchors)
        anchors.merge(candidates) { _, candidate in candidate }
        anchorsByOrigin[originIdentifier] = anchors
    }

    func remove(deviceID: String, originIdentifier: String) throws {
        removedDeviceIDs.append(deviceID)
        var anchors = anchorsByOrigin[originIdentifier] ?? [:]
        anchors.removeValue(forKey: deviceID)
        anchorsByOrigin[originIdentifier] = anchors.isEmpty ? nil : anchors
    }

    func clear() throws {
        clearCallCount += 1
        anchorsByOrigin = [:]
    }
}

final class InMemoryRemoteSyncConfigurationStore: RemoteSyncConfigurationStoring {
    private var configuration: RemoteHubConfiguration?
    private var encryptionKeys: [String: String] = [:]
    private var loadError: Error?
    private(set) var clearCallCount = 0
    private(set) var hasEncryptionKeyCallCount = 0

    init(configuration: RemoteHubConfiguration?, loadError: Error? = nil) {
        self.configuration = configuration
        self.loadError = loadError
    }

    func load() throws -> RemoteHubConfiguration? {
        if let loadError { throw loadError }
        return configuration
    }

    func save(_ configuration: RemoteHubConfiguration) throws {
        self.configuration = configuration
    }

    func encryptionKey(for deviceID: String) throws -> String? {
        encryptionKeys[deviceID]
    }

    func saveEncryptionKey(_ encryptionKey: String, for deviceID: String) throws {
        encryptionKeys[deviceID] = encryptionKey
    }

    func deleteEncryptionKey(for deviceID: String) throws {
        encryptionKeys.removeValue(forKey: deviceID)
    }

    func hasEncryptionKey(for deviceID: String) -> Bool {
        hasEncryptionKeyCallCount += 1
        return encryptionKeys[deviceID] != nil
    }

    func clear() throws {
        clearCallCount += 1
        configuration = nil
        encryptionKeys = [:]
        loadError = nil
    }
}

final class ClearFailingRemoteSyncConfigurationStore: RemoteSyncConfigurationStoring {
    private let configuration: RemoteHubConfiguration?
    private let encryptionKeys: [String: String]
    private(set) var clearCallCount = 0

    init(configuration: RemoteHubConfiguration?, encryptionKeys: [String: String]) {
        self.configuration = configuration
        self.encryptionKeys = encryptionKeys
    }

    func load() throws -> RemoteHubConfiguration? {
        configuration
    }

    func save(_: RemoteHubConfiguration) throws {
        throw TestError.unexpectedCall
    }

    func encryptionKey(for deviceID: String) throws -> String? {
        encryptionKeys[deviceID]
    }

    func saveEncryptionKey(_: String, for _: String) throws {
        throw TestError.unexpectedCall
    }

    func deleteEncryptionKey(for _: String) throws {
        throw TestError.unexpectedCall
    }

    func hasEncryptionKey(for deviceID: String) -> Bool {
        encryptionKeys[deviceID] != nil
    }

    func clear() throws {
        clearCallCount += 1
        throw TestError.temporaryCredentialFailure
    }
}

final class InMemoryKeychainCredentialStore: KeychainCredentialStoring {
    private var values: [String: String] = [:]
    var failingDeleteAccounts: Set<String> = []

    var savedAccounts: [String] {
        values.keys.sorted()
    }

    func save(_ value: String, account: String) throws {
        values[account] = value
    }

    func read(account: String) throws -> String? {
        values[account]
    }

    func delete(account: String) throws {
        if failingDeleteAccounts.contains(account) {
            throw TestError.temporaryCredentialFailure
        }
        values.removeValue(forKey: account)
    }

    func accounts(withPrefix prefix: String) throws -> [String] {
        values.keys.filter { $0.hasPrefix(prefix) }.sorted()
    }
}

private extension NSLock {
    func withLock<Value>(_ operation: () -> Value) -> Value {
        lock()
        defer { unlock() }
        return operation()
    }
}

enum TestError: Error {
    case temporaryCredentialFailure
    case temporaryCacheFailure
    case unexpectedCall
}

func entityTag(_ character: Character) -> String {
    "\"\(String(repeating: character, count: 64))\""
}

func XCTAssertThrowsErrorAsync(
    _ expression: () async throws -> Void,
    file: StaticString = #filePath,
    line: UInt = #line) async {
    do {
        try await expression()
        XCTFail("Expected expression to throw", file: file, line: line)
    } catch {}
}
