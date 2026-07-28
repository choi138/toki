import Foundation
import TokiUsageCore
import XCTest
@testable import TokiAgentCore
@testable import TokiUsageReaders

final class AgentSnapshotReplacementCoverageTests: XCTestCase {
    func test_replacementCoverageSuppressesOnlyCoveredSourceEvents() async throws {
        let fixture = try AgentSnapshotFixture()
        defer { fixture.remove() }
        let now = fixture.now
        let coveredDate = now.addingTimeInterval(-3600)
        let retainedDate = now.addingTimeInterval(-120)
        var hermesUsage = RawTokenUsage()
        hermesUsage.recordTokenEvent(
            timestamp: coveredDate,
            source: "Hermes",
            model: "gpt-5",
            inputTokens: 10,
            outputTokens: 5)
        hermesUsage.recordTokenEvent(
            timestamp: retainedDate,
            source: "Hermes",
            model: "gpt-5",
            inputTokens: 20,
            outputTokens: 10)
        var authoritativeUsage = RawTokenUsage()
        authoritativeUsage.recordTokenEvent(
            timestamp: coveredDate.addingTimeInterval(60),
            source: "authoritative",
            model: "gpt-5",
            inputTokens: 80,
            outputTokens: 20)
        authoritativeUsage.tokenReplacementCoverages = [TokenReplacementCoverage(
            coveredFrom: coveredDate.addingTimeInterval(-60),
            coveredTo: coveredDate.addingTimeInterval(120),
            sources: ["Hermes"])]
        let builder = AgentSnapshotBuilder(
            home: fixture.root,
            readerDescriptors: [
                LocalUsageReaderDescriptor(
                    reader: FixedTokenReader(name: "Hermes", usage: hermesUsage),
                    sourceLocations: []),
                LocalUsageReaderDescriptor(
                    reader: FixedTokenReader(name: "Authoritative", usage: authoritativeUsage),
                    sourceLocations: []),
            ])

        let snapshot = try await builder.build(configuration: fixture.configuration, now: now)

        XCTAssertEqual(snapshot.tokenEvents.map(\.source), ["authoritative", "Hermes"])
        XCTAssertEqual(snapshot.tokenEvents.map(\.totalTokens), [100, 30])
        XCTAssertEqual(snapshot.tokenEvents.map(\.timestamp), [
            coveredDate.addingTimeInterval(60),
            retainedDate,
        ])
    }
}
