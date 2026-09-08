import Foundation
import TokiUsageCore
import XCTest
@testable import TokiUsageReaders

final class OpenClawParsingTests: XCTestCase {
    func test_unknownPriceAndMissingModelRemainUnknownInsteadOfFree() async throws {
        let fixture = try OpenClawFixture()
        defer { fixture.remove() }
        try fixture.jsonl([
            OpenClawFixture.event(id: "unknown", model: "fixture-unpriced-model", usage: #"{"input":5,"output":3}"#),
        ])
        try fixture.jsonl([
            OpenClawFixture.event(id: "missing", model: nil, usage: #"{"input":7,"output":2}"#),
        ], filename: "unattributed.jsonl")
        let usage = try await fixture.read()
        XCTAssertEqual(usage.totalTokens, 17)
        XCTAssertEqual(usage.tokenEvents.map(\.costIsKnown), [false, false])
        XCTAssertEqual(usage.perModel["fixture-unpriced-model"]?.totalTokens, 8)
        XCTAssertEqual(usage.perModel[UsageModelGrouping.mixedOrUnattributedKey]?.totalTokens, 9)
        XCTAssertEqual(usage.tokenEvents.first { $0.inputTokens == 7 }?.model, nil)
        XCTAssertEqual(usage.cost, 0)
        XCTAssertGreaterThan(usage.perModel[UsageModelGrouping.mixedOrUnattributedKey]?.activeSeconds ?? 0, 0)
    }

    func test_knownPriceUsesAllBillableBucketsAndReportedZeroRemainsAuthoritative() async throws {
        let fixture = try OpenClawFixture()
        defer { fixture.remove() }
        let tokens = #"{"input":100,"output":50,"cacheRead":200,"cacheWrite":10,"reasoningTokens":20}"#
        try fixture.jsonl([
            OpenClawFixture.event(id: "estimated", usage: tokens),
            OpenClawFixture.event(
                id: "zero",
                timestamp: OpenClawFixture.timestamp + 1000,
                usage: #"{"input":100,"output":50,"cost":{"total":0}}"#),
        ])
        let usage = try await fixture.read()
        let price = try XCTUnwrap(modelPrice(for: "claude-opus-4-6", at: usage.tokenEvents[0].timestamp))
        let expected = price.cost(input: 100, output: 50, cacheRead: 200, cacheWrite: 10)
        XCTAssertEqual(usage.cost, expected, accuracy: 0.000001)
        XCTAssertEqual(usage.tokenEvents[0].costIsKnown, true)
        XCTAssertEqual(usage.tokenEvents[1].costIsKnown, true)
        XCTAssertEqual(usage.tokenEvents[1].cost, 0)
        XCTAssertEqual(usage.perModel["claude-opus-4-6"]?.cost ?? -1, expected, accuracy: 0.000001)
    }

    func test_sourceSpendSurvivesUnknownModelAndInvalidSpendDoesNotBecomeKnownZero() async throws {
        let fixture = try OpenClawFixture()
        defer { fixture.remove() }
        try fixture.jsonl([
            OpenClawFixture.event(
                id: "reported",
                model: "fixture-private-model",
                usage: #"{"input":10,"output":2,"cost":{"total":1.25}}"#),
            OpenClawFixture.event(
                id: "negative",
                model: "fixture-private-model",
                timestamp: OpenClawFixture.timestamp + 1000,
                usage: #"{"input":10,"output":2,"cost":{"total":-1}}"#),
        ])
        let usage = try await fixture.read()
        XCTAssertEqual(usage.cost, 1.25)
        XCTAssertEqual(usage.tokenEvents.map(\.costIsKnown), [true, false])
        XCTAssertEqual(usage.perModel["fixture-private-model"]?.cost, 1.25)
    }

    func test_reasoningIsClampedToOutputAndReportedTotalDoesNotOverrideBuckets() async throws {
        let fixture = try OpenClawFixture()
        defer { fixture.remove() }
        try fixture.jsonl([OpenClawFixture.event(
            usage: #"{"input":10,"output":5,"cacheRead":3,"cacheWrite":2,"reasoningTokens":9,"totalTokens":99999}"#)])
        let usage = try await fixture.read()
        XCTAssertEqual(usage.outputTokens, 0)
        XCTAssertEqual(usage.reasoningTokens, 5)
        XCTAssertEqual(usage.totalTokens, 20)
        XCTAssertEqual(usage.tokenEvents.first?.totalTokens, 20)
        XCTAssertEqual(usage.perModel.values.reduce(0) { $0 + $1.totalTokens }, 20)
    }

    func test_modelContextIsOrderedAndResetsBetweenFiles() async throws {
        let fixture = try OpenClawFixture()
        defer { fixture.remove() }
        try fixture.jsonl([
            #"{"type":"model_change","modelId":"claude-sonnet-4-6","provider":"anthropic"}"#,
            OpenClawFixture.event(id: "from-change", model: nil),
            #"{"type":"custom","customType":"model-snapshot","data":{"provider":"openai","modelId":"gpt-5.2"}}"#,
            OpenClawFixture.event(id: "from-snapshot", model: nil, timestamp: OpenClawFixture.timestamp + 1000)
                .replacingOccurrences(of: #""provider":"anthropic""#, with: #""provider":"" "#),
            OpenClawFixture.event(
                id: "explicit",
                model: "claude-opus-4-6",
                timestamp: OpenClawFixture.timestamp + 2000),
            OpenClawFixture.event(id: "inherited", model: nil, timestamp: OpenClawFixture.timestamp + 3000),
        ])
        try fixture.jsonl([OpenClawFixture.event(
            id: "other-file", model: nil, timestamp: OpenClawFixture.timestamp + 4000)], filename: "z.jsonl")
        let usage = try await fixture.read()
        XCTAssertEqual(usage.tokenEvents.map(\.model), [
            "claude-sonnet-4-6", "gpt-5.2", "claude-opus-4-6", "claude-opus-4-6", nil,
        ])
        XCTAssertEqual(usage.tokenEvents[1].provider, "openai")
    }

    func test_halfOpenRangeUsesEventDatesEvenWhenFileMtimeIsOlder() async throws {
        let fixture = try OpenClawFixture()
        defer { fixture.remove() }
        let start = OpenClawFixture.start.timeIntervalSince1970 * 1000
        let end = OpenClawFixture.end.timeIntervalSince1970 * 1000
        let url = try fixture.jsonl([
            OpenClawFixture.event(id: "before", timestamp: start - 1),
            OpenClawFixture.event(id: "start", timestamp: start),
            OpenClawFixture.event(id: "last", timestamp: end - 1),
            OpenClawFixture.event(id: "end", timestamp: end),
        ])
        try FileManager.default.setAttributes(
            [.modificationDate: OpenClawFixture.start.addingTimeInterval(-86400)], ofItemAtPath: url.path)
        let usage = try await fixture.read()
        XCTAssertEqual(usage.totalTokens, 720)
        XCTAssertEqual(usage.tokenEvents.first?.timestamp, OpenClawFixture.start)
        XCTAssertEqual(
            try XCTUnwrap(usage.tokenEvents.last).timestamp.timeIntervalSince1970,
            OpenClawFixture.end.timeIntervalSince1970 - 0.001, accuracy: 0.00001)
        XCTAssertLessThanOrEqual(usage.workTime.wallClockSeconds, 60.001)
    }

    func test_malformedRowsDoNotDiscardGoodRowsOrCreateNegativeAndOverflowUsage() async throws {
        let fixture = try OpenClawFixture()
        defer { fixture.remove() }
        try fixture.jsonl([
            "{broken",
            OpenClawFixture.event(id: "negative", usage: #"{"input":-10,"output":5}"#),
            OpenClawFixture.event(id: "boolean", usage: #"{"input":true,"output":5}"#),
            OpenClawFixture.event(id: "fraction", usage: #"{"input":0.5,"output":5}"#),
            OpenClawFixture.event(id: "overflow", usage: #"{"input":9223372036854775807,"output":5}"#),
            OpenClawFixture.event(),
            #"{"type":"message","message":{"role":"user","usage":{"input":999,"output":999}}}"#,
            #"{"type":"message","message":{"role":"assistant","api":"openclaw-transcript","usage":{"input":999}}}"#,
        ])
        let usage = try await fixture.read()
        XCTAssertEqual(usage.totalTokens, 360)
        XCTAssertEqual(usage.tokenEvents.count, 1)
        XCTAssertEqual(usage.activityEvents.count, 1)
    }

    func test_legacyTimestampAndPromptAliasesKeepExistingBehavior() async throws {
        let fixture = try OpenClawFixture()
        defer { fixture.remove() }
        try fixture.jsonl([#"{"role":"assistant","usage":{"input_tokens":999,"output_tokens":999}}"#])
        let undated = try await fixture.read()
        XCTAssertEqual(undated.totalTokens, 0)
        try fixture.jsonl([
            #"{"role":"assistant","usage":{"input_tokens":999,"output_tokens":999}}"#,
            #"{"role":"assistant","created_at":"2026-08-30T10:00:01Z","usage":{"prompt_tokens":7,"#
                + #""completion_tokens":3,"cache_read_input_tokens":4,"cache_creation_input_tokens":2}}"#,
        ])
        let usage = try await fixture.read()
        XCTAssertEqual(usage.totalTokens, 16)
        XCTAssertEqual(usage.perModel[UsageModelGrouping.mixedOrUnattributedKey]?.totalTokens, 16)
        XCTAssertEqual(usage.tokenEvents.first?.costIsKnown, false)
    }
}
