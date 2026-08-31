import TokiUsageCore
import XCTest
@testable import TokiAgentCore
@testable import TokiUsageReaders

final class AgentSnapshotProviderTests: XCTestCase {
    func test_snapshotOmitsUnknownProviderMetadata() async throws {
        let fixture = try AgentSnapshotFixture()
        defer { fixture.remove() }
        var usage = RawTokenUsage()
        usage.recordTokenEvent(
            timestamp: fixture.latestEventDate,
            source: "Senpi",
            model: "private-model",
            provider: "https://token@example.test",
            inputTokens: 10,
            outputTokens: 5)
        let builder = AgentSnapshotBuilder(
            home: fixture.root,
            readerDescriptors: [
                LocalUsageReaderDescriptor(
                    reader: FixedTokenReader(name: "Senpi", usage: usage),
                    sourceLocations: []),
            ])

        let snapshot = try await builder.build(
            configuration: fixture.configuration,
            now: fixture.now)

        XCTAssertEqual(snapshot.tokenEvents.count, 1)
        XCTAssertNil(snapshot.tokenEvents.first?.provider)
    }
}
