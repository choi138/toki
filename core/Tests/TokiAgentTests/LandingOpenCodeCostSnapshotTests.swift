import Foundation
import TokiSyncProtocol
import TokiUsageCore
import XCTest
@testable import TokiAgentCore
@testable import TokiUsageReaders

final class LandingOpenCodeCostSnapshotTests: XCTestCase {
    private struct CostCase {
        let id: String
        let cost: Double
        let expectedCost: Double?
        let known: Bool
    }

    func test_reportedCostVariantsSurviveReaderSnapshotAssemblyAndValidation() async throws {
        let fixture = try OpenCodeFixture()
        defer { fixture.remove() }
        let cases: [CostCase] = [
            .init(
                id: "excessive",
                cost: RemoteUsageSnapshotValidator.maximumCostPerEvent * 2,
                expectedCost: nil,
                known: true),
            .init(id: "negative", cost: -1, expectedCost: 0, known: false),
            .init(id: "zero", cost: 0, expectedCost: 0, known: false),
            .init(id: "normal", cost: 1.25, expectedCost: 1.25, known: true),
        ]
        for item in cases {
            try fixture.writeJSON(
                fixture.payload(
                    id: item.id,
                    sessionID: "session-\(item.id)",
                    model: "fixture/unknown-\(item.id)",
                    cost: item.cost),
                session: "session-\(item.id)",
                filename: "\(item.id).json")
        }
        try writeNegativeNonfiniteRecord(root: fixture.root)

        let reader = OpenCodeReader(dataRoots: [fixture.root])
        let descriptor = LocalUsageReaderDescriptor(reader: reader, sourceLocations: [])
        let now = OpenCodeFixture.date.addingTimeInterval(120)
        let snapshot = try await AgentSnapshotBuilder(
            home: fixture.root,
            environment: [:],
            readerDescriptors: [descriptor])
            .build(configuration: configuration(), now: now)

        XCTAssertEqual(snapshot.tokenEvents.count, 5)
        XCTAssertNoThrow(try RemoteUsageSnapshotValidator.validate(snapshot, now: now))
        let events = Dictionary(uniqueKeysWithValues: snapshot.tokenEvents.compactMap { event in
            event.model.map { ($0, event) }
        })
        XCTAssertEqual(
            Set(events.keys),
            Set(cases.map { "fixture/unknown-\($0.id)" })
                .union(["fixture/unknown-nonfinite"]))
        for item in cases {
            let event = try XCTUnwrap(events["fixture/unknown-\(item.id)"])
            XCTAssertEqual(event.costIsKnown, item.known)
            XCTAssertEqual(
                event.cost,
                item.expectedCost ?? RemoteUsageSnapshotValidator.maximumCostPerEvent)
            XCTAssertEqual(event.totalTokens, 158)
        }
        let nonfinite = try XCTUnwrap(events["fixture/unknown-nonfinite"])
        XCTAssertEqual(nonfinite.cost, 0)
        XCTAssertEqual(nonfinite.costIsKnown, false)
        XCTAssertEqual(nonfinite.totalTokens, 158)
    }

    private func configuration() throws -> AgentConfiguration {
        try AgentConfiguration(bundle: AgentPairingBundle(
            hubURL: XCTUnwrap(URL(string: "https://opencode-landing.example.test")),
            deviceID: "opencode-landing",
            deviceName: "synthetic",
            uploadToken: SnapshotCipher.randomToken(),
            encryptionKey: SnapshotCipher.generateKey(),
            retentionDays: 2,
            syncIntervalSeconds: 900))
    }

    private func writeNegativeNonfiniteRecord(root: URL) throws {
        let directory = root.appendingPathComponent("storage/message/session-nonfinite")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let milliseconds = Int64(OpenCodeFixture.date.timeIntervalSince1970 * 1000)
        let payload = """
        {"role":"assistant","id":"nonfinite","sessionID":"session-nonfinite",\
        "time":{"created":\(milliseconds)},"tokens":{"input":100,"output":20,"reasoning":23,\
        "cache":{"read":10,"write":5}},"modelID":"fixture/unknown-nonfinite",\
        "providerID":"openrouter","cost":-1e400,"path":{"root":"/synthetic/project"}}
        """
        try Data(payload.utf8).write(to: directory.appendingPathComponent("nonfinite.json"))
    }
}
