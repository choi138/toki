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

        XCTAssertNil(snapshot.tokenEvents.first?.cost)
        XCTAssertEqual(snapshot.tokenEvents.first?.costIsKnown, false)
    }

    func test_snapshotDropsUnknownCostOnlyEvent() async throws {
        let fixture = try AgentSnapshotFixture()
        defer { fixture.remove() }
        let usage = RawTokenUsage(tokenEvents: [TokenUsageEvent(
            timestamp: fixture.latestEventDate,
            source: "Pi",
            model: "gpt-5",
            inputTokens: 0,
            outputTokens: 0,
            cacheReadTokens: 0,
            cacheWriteTokens: 0,
            reasoningTokens: 0,
            cost: 0.25,
            costIsKnown: false)])
        let builder = builder(fixture: fixture, usage: usage, name: "Pi")

        let snapshot = try await builder.build(
            configuration: fixture.configuration,
            now: fixture.now)

        XCTAssertTrue(snapshot.tokenEvents.isEmpty)
        XCTAssertTrue(snapshot.costEvents?.isEmpty ?? true)
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

    func test_snapshotBuildBoundsExaminedOutOfRangeTokenEvents() async throws {
        let fixture = try AgentSnapshotFixture()
        defer { fixture.remove() }
        let usage = RawTokenUsage(tokenEvents: (0..<2).map { offset in
            TokenUsageEvent(
                timestamp: Date(timeIntervalSince1970: TimeInterval(offset)),
                source: "Pi",
                model: "gpt-5",
                inputTokens: 1,
                outputTokens: 1,
                cacheReadTokens: 0,
                cacheWriteTokens: 0,
                reasoningTokens: 0,
                cost: 0)
        })
        let builder = limitedBuilder(
            fixture: fixture,
            usage: usage,
            maximumTokenEventCount: 10,
            maximumEncodedBytes: 10000,
            maximumExaminedTokenEventCount: 1)

        await assertSnapshotLimit(builder: builder, fixture: fixture)
    }

    func test_snapshotBuildBoundsExaminedOutOfRangeActivityEvents() async throws {
        let fixture = try AgentSnapshotFixture()
        defer { fixture.remove() }
        let usage = RawTokenUsage(activityEvents: (0..<2).map { offset in
            ActivityTimeEvent(
                streamID: "stream-\(offset)",
                timestamp: Date(timeIntervalSince1970: TimeInterval(offset)),
                key: "gpt-5",
                agentKind: .main)
        })
        let builder = limitedBuilder(
            fixture: fixture,
            usage: usage,
            maximumTokenEventCount: 10,
            maximumEncodedBytes: 10000,
            maximumExaminedActivityEventCount: 1)

        await assertSnapshotLimit(builder: builder, fixture: fixture)
    }

    func test_snapshotBuildBoundsReplacementCoveragesBeforeMaterializingAll() async throws {
        let fixture = try AgentSnapshotFixture()
        defer { fixture.remove() }
        var usage = RawTokenUsage()
        usage.tokenReplacementCoverages = (0..<2).map { offset in
            TokenReplacementCoverage(
                coveredFrom: fixture.latestEventDate.addingTimeInterval(TimeInterval(offset)),
                coveredTo: fixture.latestEventDate.addingTimeInterval(TimeInterval(offset + 1)),
                sources: ["Pi"])
        }
        let builder = limitedBuilder(
            fixture: fixture,
            usage: usage,
            maximumTokenEventCount: 10,
            maximumEncodedBytes: 10000,
            maximumReplacementCoverageCount: 1)

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
        maximumEncodedBytes: Int,
        maximumExaminedTokenEventCount: Int? = nil,
        maximumExaminedActivityEventCount: Int? = nil,
        maximumReplacementCoverageCount: Int? = nil) -> AgentSnapshotBuilder {
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
                maximumEncodedBytes: maximumEncodedBytes,
                maximumExaminedTokenEventCount: maximumExaminedTokenEventCount,
                maximumExaminedActivityEventCount: maximumExaminedActivityEventCount,
                maximumReplacementCoverageCount: maximumReplacementCoverageCount))
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
