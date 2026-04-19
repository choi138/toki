import XCTest
@testable import Toki

final class TokiTests: XCTestCase {
    // MARK: - formattedTokens

    func test_formattedTokens_belowThousand() {
        XCTAssertEqual(0.formattedTokens(), "0")
        XCTAssertEqual(1.formattedTokens(), "1")
        XCTAssertEqual(999.formattedTokens(), "999")
    }

    func test_formattedTokens_thousands() {
        XCTAssertEqual(1_000.formattedTokens(), "1.0K")
        XCTAssertEqual(1_500.formattedTokens(), "1.5K")
        XCTAssertEqual(10_000.formattedTokens(), "10.0K")
        XCTAssertEqual(999_999.formattedTokens(), "1000.0K")
    }

    func test_formattedTokens_millions() {
        XCTAssertEqual(1_000_000.formattedTokens(), "1.0M")
        XCTAssertEqual(1_230_000.formattedTokens(), "1.23M")
        XCTAssertEqual(11_000_000.formattedTokens(), "11.0M")
        XCTAssertEqual(112_600_000.formattedTokens(), "112.6M")
    }

    func test_formattedTokens_billions() {
        XCTAssertEqual(1_000_000_000.formattedTokens(), "1.0B")
        XCTAssertEqual(3_560_000_000.formattedTokens(), "3.56B")
        XCTAssertEqual(10_000_000_000.formattedTokens(), "10.0B")
    }

    // MARK: - formattedCost

    func test_formattedCost_small() {
        XCTAssertEqual(0.0.formattedCost(), "$0.00")
        XCTAssertEqual(1.5.formattedCost(), "$1.50")
        XCTAssertEqual(9.99.formattedCost(), "$9.99")
    }

    func test_formattedCost_medium() {
        XCTAssertEqual(10.0.formattedCost(), "$10.0")
        XCTAssertEqual(99.9.formattedCost(), "$99.9")
        XCTAssertEqual(100.0.formattedCost(), "$100")
        XCTAssertEqual(289.0.formattedCost(), "$289")
    }

    func test_formattedCost_large() {
        XCTAssertEqual(1_000.0.formattedCost(), "$1.0K")
        XCTAssertEqual(1_234.5.formattedCost(), "$1.2K")
    }

    // MARK: - cacheEfficiency

    func test_cacheEfficiency_zero() {
        let usage = UsageData(
            date: Date(),
            inputTokens: 1_000,
            outputTokens: 500,
            cacheReadTokens: 0,
            cacheWriteTokens: 0,
            reasoningTokens: 0,
            cost: 0,
            activeSeconds: 0,
            perModel: []
        )
        XCTAssertEqual(usage.cacheEfficiency, 0)
    }

    func test_cacheEfficiency_full() {
        let usage = UsageData(
            date: Date(),
            inputTokens: 0,
            outputTokens: 500,
            cacheReadTokens: 1_000,
            cacheWriteTokens: 0,
            reasoningTokens: 0,
            cost: 0,
            activeSeconds: 0,
            perModel: []
        )
        XCTAssertEqual(usage.cacheEfficiency, 100, accuracy: 0.001)
    }

    func test_cacheEfficiency_half() {
        let usage = UsageData(
            date: Date(),
            inputTokens: 500,
            outputTokens: 200,
            cacheReadTokens: 500,
            cacheWriteTokens: 0,
            reasoningTokens: 0,
            cost: 0,
            activeSeconds: 0,
            perModel: []
        )
        XCTAssertEqual(usage.cacheEfficiency, 50, accuracy: 0.001)
    }

    func test_cacheEfficiency_allZero() {
        let usage = UsageData(
            date: Date(),
            inputTokens: 0,
            outputTokens: 0,
            cacheReadTokens: 0,
            cacheWriteTokens: 0,
            reasoningTokens: 0,
            cost: 0,
            activeSeconds: 0,
            perModel: []
        )
        XCTAssertEqual(usage.cacheEfficiency, 0)
    }

    // MARK: - totalTokens

    func test_totalTokens_sumsAllFields() {
        let usage = UsageData(
            date: Date(),
            inputTokens: 1_000,
            outputTokens: 2_000,
            cacheReadTokens: 3_000,
            cacheWriteTokens: 4_000,
            reasoningTokens: 5_000,
            cost: 0,
            activeSeconds: 0,
            perModel: []
        )
        XCTAssertEqual(usage.totalTokens, 15_000)
    }

    func test_totalTokens_zero() {
        let usage = UsageData(
            date: Date(),
            inputTokens: 0,
            outputTokens: 0,
            cacheReadTokens: 0,
            cacheWriteTokens: 0,
            reasoningTokens: 0,
            cost: 0,
            activeSeconds: 0,
            perModel: []
        )
        XCTAssertEqual(usage.totalTokens, 0)
    }

    // MARK: - formattedWorkDuration

    func test_formattedWorkDuration_seconds() {
        XCTAssertEqual(TimeInterval(30).formattedWorkDuration(), "30s")
    }

    func test_formattedWorkDuration_minutes() {
        XCTAssertEqual(TimeInterval(15 * 60).formattedWorkDuration(), "15m")
    }

    func test_formattedWorkDuration_hours() {
        XCTAssertEqual(TimeInterval((2 * 60 + 5) * 60).formattedWorkDuration(), "2h 5m")
    }

    // MARK: - modelPrice

    func test_modelPrice_matches_currentCodexSlugs() {
        let codex = modelPrice(for: "gpt-5.3-codex")
        XCTAssertNotNil(codex)
        XCTAssertEqual(codex!.inputPerMillion, 1.75, accuracy: 0.0001)
        XCTAssertEqual(codex!.outputPerMillion, 14.0, accuracy: 0.0001)
        XCTAssertEqual(codex!.cacheReadPerMillion, 0.175, accuracy: 0.0001)

        let codexPrevious = modelPrice(for: "gpt-5.2-codex")
        XCTAssertNotNil(codexPrevious)
        XCTAssertEqual(codexPrevious!.inputPerMillion, 1.75, accuracy: 0.0001)
        XCTAssertEqual(codexPrevious!.outputPerMillion, 14.0, accuracy: 0.0001)
        XCTAssertEqual(codexPrevious!.cacheReadPerMillion, 0.175, accuracy: 0.0001)

        let codexBase = modelPrice(for: "gpt-5-codex")
        XCTAssertNotNil(codexBase)
        XCTAssertEqual(codexBase!.inputPerMillion, 1.25, accuracy: 0.0001)
        XCTAssertEqual(codexBase!.outputPerMillion, 10.0, accuracy: 0.0001)
        XCTAssertEqual(codexBase!.cacheReadPerMillion, 0.125, accuracy: 0.0001)

        let codexMini = modelPrice(for: "gpt-5.1-codex-mini")
        XCTAssertNotNil(codexMini)
        XCTAssertEqual(codexMini!.inputPerMillion, 0.25, accuracy: 0.0001)
        XCTAssertEqual(codexMini!.outputPerMillion, 2.0, accuracy: 0.0001)
        XCTAssertEqual(codexMini!.cacheReadPerMillion, 0.025, accuracy: 0.0001)

        let legacyMini = modelPrice(for: "codex-mini-latest")
        XCTAssertNotNil(legacyMini)
        XCTAssertEqual(legacyMini!.inputPerMillion, 1.50, accuracy: 0.0001)
        XCTAssertEqual(legacyMini!.outputPerMillion, 6.0, accuracy: 0.0001)
        XCTAssertEqual(legacyMini!.cacheReadPerMillion, 0.375, accuracy: 0.0001)
    }

    func test_modelPrice_prefers_specificCodexMiniOverGenericGpt5() {
        let specific = modelPrice(for: "gpt-5.1-codex-mini-2025-11-03")
        XCTAssertNotNil(specific)
        XCTAssertEqual(specific!.inputPerMillion, 0.25, accuracy: 0.0001)
        XCTAssertEqual(specific!.outputPerMillion, 2.0, accuracy: 0.0001)
        XCTAssertEqual(specific!.cacheReadPerMillion, 0.025, accuracy: 0.0001)
    }

    func test_claudeCodeReader_keepsAllStreamedTimestampsForActiveTime() {
        let usage = ClaudeCodeReader.usage(
            fromJSONLLines: [
                claudeAssistantLine(
                    timestamp: "2026-04-10T00:00:00Z",
                    requestId: "req-1",
                    messageID: "msg-1",
                    model: "claude-sonnet-4-6",
                    input: 10,
                    output: 2
                ),
                claudeAssistantLine(
                    timestamp: "2026-04-10T00:04:00Z",
                    requestId: "req-1",
                    messageID: "msg-1",
                    model: "claude-sonnet-4-6",
                    input: 10,
                    output: 7
                ),
            ],
            streamID: "claude-session",
            from: tokiTestISODate("2026-04-10T00:00:00Z"),
            to: tokiTestISODate("2026-04-11T00:00:00Z")
        )

        XCTAssertEqual(usage.totalTokens, 17)
        XCTAssertEqual(usage.activeSeconds, 270, accuracy: 0.001)
        XCTAssertEqual(usage.perModel["claude-sonnet-4-6"]?.totalTokens, 17)
        XCTAssertEqual(usage.perModel["claude-sonnet-4-6"]?.activeSeconds ?? 0, 270, accuracy: 0.001)
    }

}

private func claudeAssistantLine(
    timestamp: String,
    requestId: String,
    messageID: String,
    model: String,
    input: Int,
    output: Int,
    cacheRead: Int = 0,
    cacheWrite: Int = 0
) -> String {
    """
    {"type":"assistant","timestamp":"\(timestamp)","requestId":"\(requestId)",\
    "message":{"id":"\(messageID)","model":"\(model)","usage":{\
    "input_tokens":\(input),"output_tokens":\(output),"cache_read_input_tokens":\(cacheRead),\
    "cache_creation_input_tokens":\(cacheWrite)}}}
    """
}

private func tokiTestISODate(_ value: String) -> Date {
    guard let date = DateParser.parse(value) else {
        XCTFail("Failed to parse ISO date: \(value)")
        return Date.distantPast
    }
    return date
}
