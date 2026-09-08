import Foundation
import XCTest
@testable import TokiUsageReaders

final class OpenClawNullAliasRegressionTests: XCTestCase {
    func test_legacyNullPrimariesFallBackToPromptAndCompletionTokens() async throws {
        let fixture = try OpenClawFixture()
        defer { fixture.remove() }
        try fixture.jsonl([event(
            nested: false,
            usage:
            #"{"input_tokens":null,"output_tokens":null,"prompt_tokens":7,"completion_tokens":3}"#)])
        let usage = try await fixture.read()
        XCTAssertEqual(usage.inputTokens, 7)
        XCTAssertEqual(usage.outputTokens, 3)
        XCTAssertEqual(usage.totalTokens, 10)
        XCTAssertEqual(usage.tokenEvents.count, 1)
    }

    func test_nestedNullPrimariesFallBackToPromptAndCompletionTokens() async throws {
        let fixture = try OpenClawFixture()
        defer { fixture.remove() }
        try fixture.jsonl([event(
            nested: true,
            usage:
            #"{"input":null,"output":null,"prompt_tokens":7,"completion_tokens":3}"#)])
        let usage = try await fixture.read()
        XCTAssertEqual(usage.inputTokens, 7)
        XCTAssertEqual(usage.outputTokens, 3)
        XCTAssertEqual(usage.totalTokens, 10)
        XCTAssertEqual(usage.tokenEvents.count, 1)
    }

    func test_nestedMissingPrimariesUseTheSameAliasesAsNullPrimaries() async throws {
        let fixture = try OpenClawFixture()
        defer { fixture.remove() }
        try fixture.jsonl([event(nested: true, usage: #"{"prompt_tokens":7,"completion_tokens":3}"#)])
        let usage = try await fixture.read()
        XCTAssertEqual(usage.totalTokens, 10)
        XCTAssertEqual(usage.tokenEvents.count, 1)
    }

    func test_presentPrimariesIncludingZeroRetainPrecedenceInBothEnvelopes() async throws {
        for nested in [false, true] {
            let fixture = try OpenClawFixture()
            defer { fixture.remove() }
            let input = nested ? "input" : "input_tokens"
            let output = nested ? "output" : "output_tokens"
            let cacheRead = nested ? "cacheRead" : "cache_read_input_tokens"
            try fixture.jsonl([
                event(
                    nested: nested,
                    usage:
                    #"{"\#(input)":2,"\#(output)":4,"prompt_tokens":70,"completion_tokens":30}"#),
                event(
                    nested: nested,
                    usage:
                    #"{"\#(input)":0,"\#(output)":0,"prompt_tokens":70,"completion_tokens":30,"\#(cacheRead)":1}"#),
            ])
            let usage = try await fixture.read()
            XCTAssertEqual(usage.inputTokens, 2)
            XCTAssertEqual(usage.outputTokens, 4)
            XCTAssertEqual(usage.cacheReadTokens, 1)
            XCTAssertEqual(usage.totalTokens, 7)
            XCTAssertEqual(usage.tokenEvents.count, 2)
        }
    }

    func test_malformedPresentPrimariesDoNotFallBackInEitherEnvelope() async throws {
        for nested in [false, true] {
            let fixture = try OpenClawFixture()
            defer { fixture.remove() }
            let input = nested ? "input" : "input_tokens"
            let output = nested ? "output" : "output_tokens"
            var lines = [event(nested: nested, usage: #"{"\#(input)":7,"\#(output)":3}"#)]
            for invalid in [#""invalid""#, "true", "-1", "1.5", "1000000001"] {
                lines.append(event(
                    nested: nested,
                    usage:
                    #"{"\#(input)":\#(invalid),"\#(output)":3,"prompt_tokens":7}"#))
                lines.append(event(
                    nested: nested,
                    usage:
                    #"{"\#(input)":7,"\#(output)":\#(invalid),"completion_tokens":3}"#))
            }
            try fixture.jsonl(lines)
            let usage = try await fixture.read()
            XCTAssertEqual(usage.totalTokens, 10)
            XCTAssertEqual(usage.tokenEvents.count, 1)
        }
    }

    func test_nullAliasesWithoutValuesRemainZeroInBothEnvelopes() async throws {
        for nested in [false, true] {
            let fixture = try OpenClawFixture()
            defer { fixture.remove() }
            let input = nested ? "input" : "input_tokens"
            let output = nested ? "output" : "output_tokens"
            let cacheRead = nested ? "cacheRead" : "cache_read_input_tokens"
            let tokens = #"{"\#(input)":null,"\#(output)":null,"#
                + #""prompt_tokens":null,"completion_tokens":null,"\#(cacheRead)":1}"#
            try fixture.jsonl([event(nested: nested, usage: tokens)])
            let usage = try await fixture.read()
            XCTAssertEqual(usage.inputTokens, 0)
            XCTAssertEqual(usage.outputTokens, 0)
            XCTAssertEqual(usage.totalTokens, 1)
            XCTAssertEqual(usage.tokenEvents.count, 1)
        }
    }

    func test_nullModelProviderAndTimestampValuesPreserveContextFallbacks() async throws {
        let fixture = try OpenClawFixture()
        defer { fixture.remove() }
        try fixture.jsonl([
            #"{"type":"model_change","modelId":"claude-sonnet-4-6","provider":"anthropic"}"#,
            #"{"type":"model_change","modelId":null,"provider":null}"#,
            #"{"type":"custom","customType":"model-snapshot","data":{"modelId":null,"provider":null}}"#,
            #"{"role":"assistant","model":null,"provider":null,"timestamp":null,"#
                + #""created_at":"2026-08-30T10:00:01Z","usage":{"input_tokens":7,"output_tokens":3}}"#,
            #"{"type":"message","timestamp":"2026-08-30T10:00:02Z","message":{"role":"assistant","#
                + #""model":null,"provider":null,"timestamp":null,"created_at":null,"usage":{"input":7,"output":3}}}"#,
        ])
        let usage = try await fixture.read()
        XCTAssertEqual(usage.totalTokens, 20)
        XCTAssertEqual(usage.tokenEvents.count, 2)
        XCTAssertEqual(usage.tokenEvents.map(\.model), ["claude-sonnet-4-6", "claude-sonnet-4-6"])
        XCTAssertEqual(usage.tokenEvents.map(\.provider), ["anthropic", "anthropic"])
        XCTAssertEqual(usage.tokenEvents.map(\.timestamp.timeIntervalSince1970), [1_788_084_001, 1_788_084_002])
    }

    func test_nullMessageModelAndProviderFallBackToSessionMetadata() throws {
        var parser = OpenClawMessageParser(sessionID: "fixture")
        let row = #"{"type":"message","message":{"role":"assistant","model":null,"provider":null,"#
            + #""timestamp":null,"usage":{"input":7,"output":3}}}"#
        let event = try XCTUnwrap(parser.parse(
            Data(row.utf8), fallbackDate: OpenClawFixture.start,
            sessionModel: "gpt-5.2", sessionProvider: "openai"))
        XCTAssertEqual(event.model, "gpt-5.2")
        XCTAssertEqual(event.provider, "openai")
        XCTAssertEqual(event.date, OpenClawFixture.start)
        XCTAssertNil(event.ownDate)
    }

    private func event(nested: Bool, usage: String) -> String {
        let message = #"{"role":"assistant","timestamp":"2026-08-30T10:00:01Z","usage":\#(usage)}"#
        return nested ? #"{"type":"message","message":\#(message)}"# : message
    }
}
