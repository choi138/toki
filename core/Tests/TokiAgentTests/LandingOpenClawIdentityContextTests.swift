import Foundation
import XCTest
@testable import TokiUsageReaders

final class LandingOpenClawIdentityContextTests: XCTestCase {
    func test_idlessCopiesUsePerSourceMultiplicityAcrossDifferentLengthsAndOrder() async throws {
        let fixture = try OpenClawFixture()
        defer { fixture.remove() }
        let repeated = idlessEvent(id: "repeated")
        let additional = idlessEvent(
            id: "additional",
            timestamp: OpenClawFixture.timestamp + 1000,
            usage: #"{"input":7,"output":3}"#)
        try fixture.jsonl([repeated, repeated, additional], filename: "session.jsonl")
        try fixture.jsonl(
            [additional, repeated, repeated, additional],
            filename: "session.jsonl.deleted.1")

        let usage = try await fixture.read()

        XCTAssertEqual(usage.totalTokens, 740)
        XCTAssertEqual(usage.tokenEvents.count, 4)
        XCTAssertEqual(usage.tokenEvents.filter { $0.totalTokens == 360 }.count, 2)
        XCTAssertEqual(usage.tokenEvents.filter { $0.totalTokens == 10 }.count, 2)
    }

    func test_idlessCopiesReconcileWithinSessionContextsDespiteReordering() async throws {
        let fixture = try OpenClawFixture()
        defer { fixture.remove() }
        let event = idlessEvent(id: "context-copy")
        let alpha = #"{"type":"session","id":"alpha"}"#
        let beta = #"{"type":"session","id":"beta"}"#
        try fixture.jsonl([alpha, event, beta, event], filename: "bundle.jsonl")
        try fixture.jsonl([beta, event, alpha, event], filename: "bundle.jsonl.deleted.1")

        let usage = try await fixture.read()

        XCTAssertEqual(usage.totalTokens, 720)
        XCTAssertEqual(usage.tokenEvents.count, 2)
        XCTAssertEqual(Set(usage.tokenEvents.compactMap { $0.attribution?.sessionID }).count, 2)
    }

    func test_idlessFallbackNeverCollapsesUnrelatedSessionsOrAgentsAndIsRepeatable() async throws {
        let fixture = try OpenClawFixture()
        defer { fixture.remove() }
        let event = idlessEvent(id: "independent")
        try fixture.jsonl([event], filename: "one.jsonl")
        try fixture.jsonl([event], filename: "two.jsonl")
        try fixture.jsonl([event], agent: "work", filename: "one.jsonl")
        let reader = OpenClawReader(agentsURLOverride: fixture.agents)

        let first = try await reader.readUsage(from: OpenClawFixture.start, to: OpenClawFixture.end)
        let second = try await reader.readUsage(from: OpenClawFixture.start, to: OpenClawFixture.end)

        XCTAssertEqual(first.totalTokens, 1080)
        XCTAssertEqual(first.tokenEvents.count, 3)
        XCTAssertEqual(Set(first.tokenEvents.compactMap { $0.attribution?.sessionID }).count, 3)
        XCTAssertEqual(first.tokenEvents, second.tokenEvents)
        XCTAssertEqual(first.activityEvents.map(\.streamID), second.activityEvents.map(\.streamID))
        XCTAssertEqual(first.activityEvents.map(\.timestamp), second.activityEvents.map(\.timestamp))
        XCTAssertEqual(first.activityEvents.map(\.key), second.activityEvents.map(\.key))
        XCTAssertEqual(first.activityEvents.map(\.agentKind), second.activityEvents.map(\.agentKind))
    }

    func test_providedAndFallbackIdentitiesRemainSeparate() async throws {
        let fixture = try OpenClawFixture()
        defer { fixture.remove() }
        let identified = OpenClawFixture.event(id: "provided")
        let idless = idlessEvent(id: "provided")
        try fixture.jsonl([identified, idless], filename: "session.jsonl")
        try fixture.jsonl([identified, idless], filename: "session.jsonl.deleted.1")

        let usage = try await fixture.read()

        XCTAssertEqual(usage.totalTokens, 720)
        XCTAssertEqual(usage.tokenEvents.count, 2)
    }

    func test_rejectedAssistantRowsDoNotMutateLaterModelOrProviderContext() async throws {
        let fixture = try OpenClawFixture()
        defer { fixture.remove() }
        try fixture.jsonl([
            #"{"type":"message","id":"invalid-date","message":{"role":"assistant","model":"gpt-5.2","#
                + #""provider":"openai","timestamp":"invalid","usage":{"input":1,"output":1}}}"#,
            #"{"role":"assistant","model":"claude-opus-4-6","provider":"anthropic","#
                + #""usage":{"input_tokens":1,"output_tokens":1}}"#,
            #"{"type":"message","id":"valid","message":{"role":"assistant","timestamp":1788084001000,"#
                + #""usage":{"input":7,"output":3}}}"#,
        ])

        let usage = try await fixture.read()

        XCTAssertEqual(usage.totalTokens, 10)
        XCTAssertNil(usage.tokenEvents.first?.model)
        XCTAssertNil(usage.tokenEvents.first?.provider)
    }

    func test_validOutOfRangeAssistantRowsStillEstablishContext() async throws {
        let fixture = try OpenClawFixture()
        defer { fixture.remove() }
        let beforeRange = (OpenClawFixture.start.timeIntervalSince1970 - 1) * 1000
        try fixture.jsonl([
            #"{"type":"message","id":"before","message":{"role":"assistant","model":"gpt-5.2","provider":"openai","#
                + #""timestamp":\#(Int64(beforeRange)),"usage":{"input":1,"output":1}}}"#,
            #"{"type":"message","id":"inside","message":{"role":"assistant","timestamp":1788084001000,"#
                + #""usage":{"input":7,"output":3}}}"#,
        ])

        let usage = try await fixture.read()

        XCTAssertEqual(usage.totalTokens, 10)
        XCTAssertEqual(usage.tokenEvents.first?.model, "gpt-5.2")
        XCTAssertEqual(usage.tokenEvents.first?.provider, "openai")
    }

    func test_healthySourceDoesNotHideWhollyMalformedSelectedArchive() async throws {
        let fixture = try OpenClawFixture()
        defer { fixture.remove() }
        try fixture.jsonl([OpenClawFixture.event()], filename: "a.jsonl")
        try fixture.jsonl(["{malformed"], filename: "z.jsonl.deleted.1")

        do {
            _ = try await fixture.read()
            XCTFail("A complete snapshot must fail rather than omit a selected corrupt source")
        } catch {
            XCTAssertEqual(error as? OpenClawReadError, .unrecognizedTranscript)
        }
    }

    func test_emptyAndRecognizedNonUsageTranscriptsRemainValid() async throws {
        let fixture = try OpenClawFixture()
        defer { fixture.remove() }
        try fixture.jsonl([], filename: "empty.jsonl")
        try fixture.jsonl([
            #"{"type":"message","message":{"role":"user","content":"synthetic fixture"}}"#,
        ], filename: "non-usage.jsonl")

        let usage = try await fixture.read()

        XCTAssertEqual(usage.totalTokens, 0)
        XCTAssertTrue(usage.tokenEvents.isEmpty)
    }

    private func idlessEvent(
        id: String,
        timestamp: Double? = OpenClawFixture.timestamp,
        usage: String? = nil) -> String {
        OpenClawFixture.event(id: id, timestamp: timestamp, usage: usage)
            .replacingOccurrences(of: #""id":"\#(id)","#, with: "")
    }
}
