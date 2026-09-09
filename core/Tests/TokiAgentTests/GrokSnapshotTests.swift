import Foundation
import TokiSyncProtocol
import XCTest
@testable import TokiAgentCore
@testable import TokiUsageReaders

final class GrokSnapshotTests: XCTestCase {
    func test_readerFlowsThroughSnapshotWithKnownCostAndPerSessionActivity() async throws {
        let fixture = try GrokFixture()
        defer { fixture.remove() }
        for index in 0..<2 {
            try fixture.writeSession(
                id: "session-\(index)",
                cwd: "/synthetic/project-\(index)",
                turns: [fixture.turn(endedAt: GrokFixture.date.addingTimeInterval(Double(index) * 60))],
                summaryCWD: "/synthetic/project-\(index)")
        }
        let reader = GrokReader(sessionRootsOverride: [fixture.sessionsRoot])
        let descriptor = LocalUsageReaderDescriptor(
            reader: reader,
            sourceLocations: [.directoryPresence(fixture.sessionsRoot)],
            sourceSignatureStrategy: .allFiles,
            collectorRevision: 1,
            sourceLocationsResolver: reader.selectedSourceLocations)
        let now = GrokFixture.date.addingTimeInterval(300)

        let snapshot = try await AgentSnapshotBuilder(
            home: fixture.home,
            environment: [:],
            readerDescriptors: [descriptor])
            .build(configuration: Self.configuration(), now: now)
        let data = try TokiSyncCoding.makeEncoder().encode(snapshot)
        let decoded = try TokiSyncCoding.makeDecoder().decode(RemoteUsageSnapshot.self, from: data)

        XCTAssertEqual(decoded.tokenEvents.count, 2)
        XCTAssertEqual(decoded.tokenEvents.reduce(0) { $0 + $1.totalTokens }, 2400)
        XCTAssertEqual(decoded.tokenEvents.reduce(0) { $0 + ($1.cost ?? 0) }, 5, accuracy: 0.000001)
        XCTAssertTrue(decoded.tokenEvents.allSatisfy {
            $0.costIsKnown == true && $0.provider == "xai" && $0.model == "grok-4.6-build"
        })
        XCTAssertEqual(Set(decoded.activityEvents.map(\.streamID)).count, 2)
        XCTAssertNoThrow(try RemoteUsageSnapshotValidator.validate(decoded, now: now))
        let encoded = try XCTUnwrap(String(data: data, encoding: .utf8))
        XCTAssertFalse(encoded.contains(fixture.home.path))
        XCTAssertFalse(encoded.contains("session-0"))
        XCTAssertFalse(encoded.contains("/synthetic/project-0"))
    }

    func test_unknownCostSurvivesSnapshotSerialization() async throws {
        let fixture = try GrokFixture()
        defer { fixture.remove() }
        try fixture.writeSession(turns: [fixture.turn(
            endedAt: GrokFixture.date,
            fixture.counts(ticks: nil, model: "grok-experimental"))])
        let reader = GrokReader(sessionRootsOverride: [fixture.sessionsRoot])
        let now = GrokFixture.date.addingTimeInterval(300)

        let snapshot = try await AgentSnapshotBuilder(
            home: fixture.home,
            environment: [:],
            readerDescriptors: [LocalUsageReaderDescriptor(reader: reader, sourceLocations: [])])
            .build(configuration: Self.configuration(), now: now)
        let encoded = try TokiSyncCoding.makeEncoder().encode(snapshot)
        let decoded = try TokiSyncCoding.makeDecoder().decode(RemoteUsageSnapshot.self, from: encoded)
        let event = try XCTUnwrap(decoded.tokenEvents.first)

        XCTAssertEqual(event.model, "grok-experimental")
        XCTAssertEqual(event.provider, "xai")
        XCTAssertEqual(event.costIsKnown, false)
        XCTAssertEqual(event.cost, 0)
        XCTAssertEqual(event.totalTokens, 1200)
        XCTAssertNoThrow(try RemoteUsageSnapshotValidator.validate(decoded, now: now))
    }

    private static func configuration() throws -> AgentConfiguration {
        try AgentConfiguration(bundle: AgentPairingBundle(
            hubURL: XCTUnwrap(URL(string: "https://hub.example.test")),
            deviceID: "grok-fixture",
            deviceName: "synthetic",
            uploadToken: SnapshotCipher.randomToken(),
            encryptionKey: SnapshotCipher.generateKey(),
            retentionDays: 2,
            syncIntervalSeconds: 900))
    }
}
