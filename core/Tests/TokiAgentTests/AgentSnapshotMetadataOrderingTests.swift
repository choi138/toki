import Foundation
import TokiUsageCore
import XCTest
@testable import TokiAgentCore
@testable import TokiUsageReaders

final class AgentSnapshotMetadataOrderingTests: XCTestCase {
    func test_providerAndCostKnowledgeProduceStableSnapshotOrdering() async throws {
        let fixture = try AgentSnapshotFixture()
        defer { fixture.remove() }
        let usages = [
            usage(provider: "openrouter", costIsKnown: false, timestamp: fixture.latestEventDate),
            usage(provider: "openrouter", costIsKnown: true, timestamp: fixture.latestEventDate),
            usage(provider: "qwen", costIsKnown: false, timestamp: fixture.latestEventDate),
        ]
        let forward = AgentSnapshotBuilder(
            home: fixture.root,
            readerDescriptors: descriptors(usages))
        let reversed = AgentSnapshotBuilder(
            home: fixture.root,
            readerDescriptors: descriptors(usages.reversed()))

        let forwardSnapshot = try await forward.build(
            configuration: fixture.configuration,
            now: fixture.now)
        let reversedSnapshot = try await reversed.build(
            configuration: fixture.configuration,
            now: fixture.now)

        XCTAssertEqual(forwardSnapshot.tokenEvents, reversedSnapshot.tokenEvents)
        XCTAssertEqual(
            try forward.contentDigest(forwardSnapshot),
            try reversed.contentDigest(reversedSnapshot))
    }

    func test_unknownCostOnlyEventIsNotExported() async throws {
        let fixture = try AgentSnapshotFixture()
        defer { fixture.remove() }
        var usage = RawTokenUsage()
        usage.recordTokenEvent(
            timestamp: fixture.latestEventDate,
            source: "shared",
            model: "shared-model",
            inputTokens: 0,
            outputTokens: 0,
            cost: 42,
            costIsKnown: false)
        let builder = AgentSnapshotBuilder(
            home: fixture.root,
            readerDescriptors: descriptors([usage]))

        let snapshot = try await builder.build(
            configuration: fixture.configuration,
            now: fixture.now)

        XCTAssertTrue(snapshot.tokenEvents.isEmpty)
        XCTAssertNil(snapshot.costEvents)
    }

    private func descriptors(
        _ usages: some Sequence<RawTokenUsage>) -> [LocalUsageReaderDescriptor] {
        usages.enumerated().map { index, usage in
            LocalUsageReaderDescriptor(
                reader: FixedTokenReader(name: "reader-\(index)", usage: usage),
                sourceLocations: [])
        }
    }

    private func usage(
        provider: String,
        costIsKnown: Bool,
        timestamp: Date) -> RawTokenUsage {
        var usage = RawTokenUsage()
        usage.recordTokenEvent(
            timestamp: timestamp,
            source: "shared",
            model: "shared-model",
            provider: provider,
            inputTokens: 1,
            outputTokens: 0,
            costIsKnown: costIsKnown)
        return usage
    }
}
