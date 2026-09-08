import Foundation
import TokiSyncProtocol
import XCTest
@testable import TokiAgentCore
@testable import TokiUsageReaders

final class OpenCodeSnapshotTests: XCTestCase {
    func test_publicReaderFlowsThroughSnapshotWithKnownCostAndIndependentActivity() async throws {
        let fixture = try OpenCodeFixture()
        defer { fixture.remove() }
        let roots = [fixture.root.appendingPathComponent("one"), fixture.root.appendingPathComponent("two")]
        let first = try OpenCodeTestDatabase(at: roots[0].appendingPathComponent("opencode.db"))
        let second = try OpenCodeTestDatabase(at: roots[1].appendingPathComponent("opencode.db"))
        var payload = fixture.payload(cost: 0.5)
        payload["providerID"] = "openrouter"
        for database in [first, second] {
            try database.insert(payload)
            try fixture.writeJSON(payload, root: database.url.deletingLastPathComponent())
        }
        let reader = OpenCodeReader(dataRoots: roots)
        let locations = try reader.sourceLocations()
        let descriptor = LocalUsageReaderDescriptor(
            reader: reader,
            sourceLocations: locations.databaseURLs.map { .file($0, includesSQLiteSidecars: true) }
                + locations.legacyMessageDirectories.map { .directory($0, extensions: ["json"]) },
            sourceSignatureStrategy: .boundedAllFiles(
                maximumFileCount: OpenCodeReadLimits.default.maximumFileCount,
                maximumEntryCount: OpenCodeReadLimits.default.maximumEntryCount))
        let configuration = try AgentConfiguration(bundle: AgentPairingBundle(
            hubURL: XCTUnwrap(URL(string: "https://hub.example.test")),
            deviceID: "opencode-fixture", deviceName: "synthetic",
            uploadToken: SnapshotCipher.randomToken(), encryptionKey: SnapshotCipher.generateKey(),
            retentionDays: 2, syncIntervalSeconds: 900))
        let builder = AgentSnapshotBuilder(home: fixture.root, environment: [:], readerDescriptors: [descriptor])
        let now = OpenCodeFixture.date.addingTimeInterval(120)

        let snapshot = try await builder.build(configuration: configuration, now: now)
        let data = try TokiSyncCoding.makeEncoder().encode(snapshot)
        let decoded = try TokiSyncCoding.makeDecoder().decode(RemoteUsageSnapshot.self, from: data)

        XCTAssertEqual(decoded.tokenEvents.count, 2)
        XCTAssertEqual(decoded.tokenEvents.reduce(0) { $0 + $1.totalTokens }, 316)
        XCTAssertEqual(decoded.tokenEvents.reduce(0) { $0 + ($1.cost ?? 0) }, 1)
        XCTAssertTrue(decoded.tokenEvents.allSatisfy { $0.costIsKnown == true && $0.provider == "openrouter" })
        XCTAssertEqual(Set(decoded.activityEvents.map(\.streamID)).count, 2)
        XCTAssertNoThrow(try RemoteUsageSnapshotValidator.validate(decoded, now: now))
        let encoded = try XCTUnwrap(String(data: data, encoding: .utf8))
        XCTAssertFalse(encoded.contains(fixture.root.path))
        XCTAssertFalse(encoded.contains("/synthetic/project"))
    }

    func test_unknownCostAndModelSurviveSnapshotSerialization() async throws {
        let fixture = try OpenCodeFixture()
        defer { fixture.remove() }
        var payload = fixture.payload(cost: 0)
        payload["providerID"] = "openrouter"
        try fixture.writeJSON(payload)
        let reader = OpenCodeReader(dataRoots: [fixture.root])
        let descriptor = LocalUsageReaderDescriptor(reader: reader, sourceLocations: [])
        let configuration = try AgentConfiguration(bundle: AgentPairingBundle(
            hubURL: XCTUnwrap(URL(string: "https://hub.example.test")),
            deviceID: "opencode-fixture", deviceName: "synthetic",
            uploadToken: SnapshotCipher.randomToken(), encryptionKey: SnapshotCipher.generateKey(),
            retentionDays: 2, syncIntervalSeconds: 900))
        let now = OpenCodeFixture.date.addingTimeInterval(120)
        let snapshot = try await AgentSnapshotBuilder(
            home: fixture.root,
            environment: [:],
            readerDescriptors: [descriptor])
            .build(configuration: configuration, now: now)
        let encoded = try TokiSyncCoding.makeEncoder().encode(snapshot)
        let decoded = try TokiSyncCoding.makeDecoder().decode(RemoteUsageSnapshot.self, from: encoded)
        let event = try XCTUnwrap(decoded.tokenEvents.first)

        XCTAssertEqual(event.model, "fixture/unknown-model")
        XCTAssertEqual(event.provider, "openrouter")
        XCTAssertEqual(event.costIsKnown, false)
        XCTAssertEqual(event.cost, 0)
        XCTAssertEqual(event.totalTokens, 158)
        XCTAssertNoThrow(try RemoteUsageSnapshotValidator.validate(decoded, now: now))
    }
}
