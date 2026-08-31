import TokiUsageCore
import XCTest
@testable import TokiAgentCore
@testable import TokiUsageReaders

final class AgentSnapshotLimitTests: XCTestCase {
    func test_snapshotPreservesAuthoritativeZeroCost() async throws {
        let fixture = try AgentSnapshotFixture()
        defer { fixture.remove() }
        var usage = RawTokenUsage()
        usage.recordTokenEvent(
            timestamp: fixture.latestEventDate,
            source: "Kimchi",
            model: "free-model",
            inputTokens: 4,
            outputTokens: 3,
            cost: 0,
            costIsKnown: true)
        let builder = builder(fixture: fixture, usage: usage, name: "Kimchi")

        let snapshot = try await builder.build(
            configuration: fixture.configuration,
            now: fixture.now)

        XCTAssertEqual(snapshot.tokenEvents.first?.cost, 0)
        XCTAssertEqual(snapshot.tokenEvents.first?.costIsKnown, true)
    }

    func test_snapshotPreservesUnknownCostState() async throws {
        let fixture = try AgentSnapshotFixture()
        defer { fixture.remove() }
        var usage = RawTokenUsage()
        usage.recordTokenEvent(
            timestamp: fixture.latestEventDate,
            source: "Pi",
            model: "gpt-5",
            inputTokens: 4,
            outputTokens: 3,
            cost: 0,
            costIsKnown: false)
        let builder = builder(fixture: fixture, usage: usage, name: "Pi")

        let snapshot = try await builder.build(
            configuration: fixture.configuration,
            now: fixture.now)

        XCTAssertEqual(snapshot.tokenEvents.first?.cost, 0)
        XCTAssertEqual(snapshot.tokenEvents.first?.costIsKnown, false)
    }

    func test_snapshotBuildRejectsGlobalEventCountBeforeAppendingAllEvents() async throws {
        let fixture = try AgentSnapshotFixture()
        defer { fixture.remove() }
        var usage = RawTokenUsage()
        for offset in 0..<2 {
            usage.recordTokenEvent(
                timestamp: fixture.latestEventDate.addingTimeInterval(TimeInterval(offset)),
                source: "Pi",
                model: "gpt-5",
                inputTokens: 1,
                outputTokens: 1)
        }
        let builder = limitedBuilder(
            fixture: fixture,
            usage: usage,
            maximumTokenEventCount: 1,
            maximumEncodedBytes: 10000)

        await assertSnapshotLimit(builder: builder, fixture: fixture)
    }

    func test_snapshotBuildRejectsEncodedBudgetDuringAssembly() async throws {
        let fixture = try AgentSnapshotFixture()
        defer { fixture.remove() }
        var usage = RawTokenUsage()
        usage.recordTokenEvent(
            timestamp: fixture.latestEventDate,
            source: "Pi",
            model: "gpt-5",
            inputTokens: 10,
            outputTokens: 5)
        let builder = limitedBuilder(
            fixture: fixture,
            usage: usage,
            maximumTokenEventCount: 10,
            maximumEncodedBytes: 1)

        await assertSnapshotLimit(builder: builder, fixture: fixture)
    }
}

private extension AgentSnapshotLimitTests {
    func builder(
        fixture: AgentSnapshotFixture,
        usage: RawTokenUsage,
        name: String) -> AgentSnapshotBuilder {
        AgentSnapshotBuilder(
            home: fixture.root,
            readerDescriptors: [
                LocalUsageReaderDescriptor(
                    reader: FixedTokenReader(name: name, usage: usage),
                    sourceLocations: []),
            ])
    }

    func limitedBuilder(
        fixture: AgentSnapshotFixture,
        usage: RawTokenUsage,
        maximumTokenEventCount: Int,
        maximumEncodedBytes: Int) -> AgentSnapshotBuilder {
        AgentSnapshotBuilder(
            home: fixture.root,
            readerDescriptors: [
                LocalUsageReaderDescriptor(
                    reader: FixedTokenReader(name: "Pi", usage: usage),
                    sourceLocations: []),
            ],
            snapshotLimits: AgentSnapshotBuildLimits(
                maximumTokenEventCount: maximumTokenEventCount,
                maximumCostEventCount: 10,
                maximumActivityEventCount: 10,
                maximumEncodedBytes: maximumEncodedBytes))
    }

    func assertSnapshotLimit(
        builder: AgentSnapshotBuilder,
        fixture: AgentSnapshotFixture) async {
        do {
            _ = try await builder.build(configuration: fixture.configuration, now: fixture.now)
            XCTFail("Expected the snapshot budget to reject the snapshot")
        } catch AgentSnapshotBuilderError.snapshotLimitExceeded {
            // Expected.
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }
}
