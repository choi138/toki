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

        let reader = OpenCodeReader(dataRoots: [fixture.root])
        let descriptor = LocalUsageReaderDescriptor(reader: reader, sourceLocations: [])
        let now = OpenCodeFixture.date.addingTimeInterval(120)
        let snapshot = try await AgentSnapshotBuilder(
            home: fixture.root,
            environment: [:],
            readerDescriptors: [descriptor])
            .build(configuration: configuration(), now: now)

        XCTAssertEqual(snapshot.tokenEvents.count, cases.count)
        XCTAssertNoThrow(try RemoteUsageSnapshotValidator.validate(snapshot, now: now))
        let events = Dictionary(uniqueKeysWithValues: snapshot.tokenEvents.compactMap { event in
            event.model.map { ($0, event) }
        })
        XCTAssertEqual(
            Set(events.keys),
            Set(cases.map { "fixture/unknown-\($0.id)" }))
        for item in cases {
            let event = try XCTUnwrap(events["fixture/unknown-\(item.id)"])
            XCTAssertEqual(event.costIsKnown, item.known)
            XCTAssertEqual(
                event.cost,
                item.expectedCost ?? RemoteUsageSnapshotValidator.maximumCostPerEvent)
            XCTAssertEqual(event.totalTokens, 158)
        }
    }

    func test_nonfiniteCostNumbersPreserveTokensAndUnknownCost() throws {
        let fixture = try OpenCodeFixture()
        defer { fixture.remove() }
        // JSON cannot portably represent nonfinite numbers. Exercise that boundary
        // directly rather than requiring Foundation to accept an overflow literal.
        for cost in [Double.infinity, -Double.infinity, Double.nan] {
            let message = try XCTUnwrap(OpenCodeMessage.parse(
                fixture.payload(model: "fixture/unknown-nonfinite", cost: cost),
                context: .init(namespace: "synthetic", originID: "nonfinite")))
            var usage = RawTokenUsage()
            try message.accumulate(into: &usage)
            let event = try XCTUnwrap(usage.tokenEvents.first)
            XCTAssertEqual(event.cost, 0)
            XCTAssertEqual(event.costIsKnown, false)
            XCTAssertEqual(event.totalTokens, 158)
        }
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
}
