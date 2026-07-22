import Foundation
import TokiSyncProtocol
import XCTest
@testable import Toki

extension RemoteUsageReaderTests {
    func test_splitCacheRemovesRecognizedCrashTemporaryFiles() throws {
        let fixture = try makeFixture()
        let root = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let cache = RemoteSnapshotCache(url: root.appendingPathComponent("snapshots.json"))
        let entry = fixture.cacheEntry()
        try cache.save(entry)
        let identifier = UUID().uuidString
        let metadataTemporaryURL = root.appendingPathComponent(".snapshots.json.\(identifier).tmp")
        let envelopeTemporaryURL = cache.envelopeDirectoryURL.appendingPathComponent(
            ".\(fixture.envelope.deviceID).\(fixture.envelope.sequence).json.\(identifier).tmp")
        try Data("metadata".utf8).write(to: metadataTemporaryURL)
        try Data("ciphertext".utf8).write(to: envelopeTemporaryURL)

        let loaded = try XCTUnwrap(cache.load())
        XCTAssertEqual(loaded.envelopes, entry.envelopes)
        XCTAssertEqual(loaded.manifest.map(\.id), entry.manifest.map(\.id))
        XCTAssertEqual(loaded.manifest.map(\.latestSequence), entry.manifest.map(\.latestSequence))
        XCTAssertEqual(loaded.snapshotCacheIdentifier, entry.snapshotCacheIdentifier)
        XCTAssertFalse(FileManager.default.fileExists(atPath: metadataTemporaryURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: envelopeTemporaryURL.path))
    }

    func test_splitCacheRejectsUnknownEnvelopeFileBeforeReplacingMetadata() throws {
        let fixture = try makeFixture()
        let root = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let cache = RemoteSnapshotCache(url: root.appendingPathComponent("snapshots.json"))
        try cache.save(fixture.cacheEntry(manifestEntityTag: entityTag("a")))
        let originalMetadata = try Data(contentsOf: cache.url)
        let unknownURL = cache.envelopeDirectoryURL.appendingPathComponent("keep.txt")
        let unknownData = Data("do not remove".utf8)
        try unknownData.write(to: unknownURL)

        XCTAssertThrowsError(try cache.save(
            fixture.cacheEntry(fetchedAt: fixture.end, manifestEntityTag: entityTag("b")),
            changedDeviceIDs: [])) { error in
                XCTAssertTrue(error is RemoteSnapshotCacheError)
            }
        XCTAssertEqual(try Data(contentsOf: cache.url), originalMetadata)
        XCTAssertEqual(try Data(contentsOf: unknownURL), unknownData)
    }

    func test_splitCacheRejectsSymbolicLinkEnvelopeDirectoryBeforeWriting() throws {
        let fixture = try makeFixture()
        let root = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let cache = RemoteSnapshotCache(url: root.appendingPathComponent("snapshots.json"))
        let targetDirectory = root.appendingPathComponent("unexpected-directory")
        try FileManager.default.createDirectory(at: targetDirectory, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(
            at: cache.envelopeDirectoryURL,
            withDestinationURL: targetDirectory)

        XCTAssertThrowsError(try cache.save(fixture.cacheEntry()))
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: targetDirectory.path).isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: cache.url.path))
    }

    func test_splitCacheClearDoesNotRecursivelyDeleteMetadataDirectory() throws {
        let root = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let cache = RemoteSnapshotCache(url: root.appendingPathComponent("snapshots.json"))
        let childURL = cache.url.appendingPathComponent("keep.txt")
        try FileManager.default.createDirectory(at: cache.url, withIntermediateDirectories: true)
        let expectedData = Data("keep".utf8)
        try expectedData.write(to: childURL)

        XCTAssertThrowsError(try cache.clear())
        XCTAssertEqual(try Data(contentsOf: childURL), expectedData)
    }

    func test_replayAnchorRemovesRecognizedCrashTemporaryFile() throws {
        let fixture = try makeFixture()
        let root = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let anchorURL = root.appendingPathComponent("anchors.json")
        let anchorStore = RemoteSnapshotAnchorStore(
            url: anchorURL,
            legacyCacheURL: root.appendingPathComponent("missing-cache.json"))
        try anchorStore.validateAndSave(
            [fixture.envelope],
            originIdentifier: fixture.configuration.snapshotCacheIdentifier)
        let temporaryURL = root.appendingPathComponent(".anchors.json.\(UUID().uuidString).tmp")
        try Data("stale anchors".utf8).write(to: temporaryURL)

        try anchorStore.validateAndSave(
            [fixture.envelope],
            originIdentifier: fixture.configuration.snapshotCacheIdentifier)

        XCTAssertFalse(FileManager.default.fileExists(atPath: temporaryURL.path))
    }

    func test_splitCacheRefreshRewritesMetadataWithoutReplacingEnvelope() throws {
        let fixture = try makeFixture()
        let root = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let cache = RemoteSnapshotCache(url: root.appendingPathComponent("snapshots.json"))
        try cache.save(fixture.cacheEntry(manifestEntityTag: entityTag("a")))
        let envelopeURL = try XCTUnwrap(FileManager.default.contentsOfDirectory(
            at: cache.envelopeDirectoryURL,
            includingPropertiesForKeys: nil).first)
        let originalAttributes = try FileManager.default.attributesOfItem(atPath: envelopeURL.path)

        let refreshedAt = fixture.end
        let refreshedEntry = RemoteSnapshotCacheEntry(
            envelopes: [fixture.envelope],
            manifest: [fixture.device(lastSeenAt: refreshedAt)],
            manifestEntityTag: entityTag("b"),
            fetchedAt: refreshedAt,
            snapshotCacheIdentifier: fixture.configuration.snapshotCacheIdentifier)
        try cache.save(refreshedEntry, changedDeviceIDs: [])

        let refreshedAttributes = try FileManager.default.attributesOfItem(atPath: envelopeURL.path)
        XCTAssertEqual(
            originalAttributes[.systemFileNumber] as? NSNumber,
            refreshedAttributes[.systemFileNumber] as? NSNumber)
        XCTAssertEqual(try cache.load(), try RemoteSnapshotCacheValidation.validated(refreshedEntry))
    }

    func test_splitCacheDeviceRemovalKeepsUnchangedEnvelopeFile() throws {
        let fixture = try makeFixture()
        let sourceSnapshot = try SnapshotCipher.open(fixture.envelope, key: fixture.encryptionKey)
        let secondKey = SnapshotCipher.generateKey()
        let secondSnapshot = RemoteUsageSnapshot(
            device: RemoteDeviceDescriptor(id: "device-2", name: "worker-2", platform: "linux"),
            generatedAt: sourceSnapshot.generatedAt,
            coveredFrom: sourceSnapshot.coveredFrom,
            coveredTo: sourceSnapshot.coveredTo,
            tokenEvents: sourceSnapshot.tokenEvents,
            activityEvents: sourceSnapshot.activityEvents)
        let secondEnvelope = try SnapshotCipher.seal(secondSnapshot, sequence: 1, key: secondKey)
        let secondDevice = RemoteDeviceSummary(
            id: "device-2",
            name: "worker-2",
            createdAt: fixture.start,
            lastSeenAt: Date(),
            latestSequence: 1)
        let entry = RemoteSnapshotCacheEntry(
            envelopes: [fixture.envelope, secondEnvelope],
            manifest: [fixture.device(), secondDevice])
        let root = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let cache = RemoteSnapshotCache(url: root.appendingPathComponent("snapshots.json"))
        try cache.save(entry)
        let retainedURL = try XCTUnwrap(FileManager.default.contentsOfDirectory(
            at: cache.envelopeDirectoryURL,
            includingPropertiesForKeys: nil).first(where: { $0.lastPathComponent.hasPrefix("device-1.") }))
        let originalAttributes = try FileManager.default.attributesOfItem(atPath: retainedURL.path)

        try cache.remove(deviceID: "device-2")

        let remainingFiles = try FileManager.default.contentsOfDirectory(
            at: cache.envelopeDirectoryURL,
            includingPropertiesForKeys: nil)
        let retainedAttributes = try FileManager.default.attributesOfItem(atPath: retainedURL.path)
        XCTAssertEqual(remainingFiles.map(\.lastPathComponent), [retainedURL.lastPathComponent])
        XCTAssertEqual(
            originalAttributes[.systemFileNumber] as? NSNumber,
            retainedAttributes[.systemFileNumber] as? NSNumber)
        XCTAssertEqual(try cache.load()?.envelopes, [fixture.envelope])
    }
}
