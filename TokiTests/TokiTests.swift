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
            inputTokens: 1_000, outputTokens: 500,
            cacheReadTokens: 0, cacheWriteTokens: 0,
            reasoningTokens: 0, cost: 0, perModel: []
        )
        XCTAssertEqual(usage.cacheEfficiency, 0)
    }

    func test_cacheEfficiency_full() {
        let usage = UsageData(
            date: Date(),
            inputTokens: 0, outputTokens: 500,
            cacheReadTokens: 1_000, cacheWriteTokens: 0,
            reasoningTokens: 0, cost: 0, perModel: []
        )
        XCTAssertEqual(usage.cacheEfficiency, 100, accuracy: 0.001)
    }

    func test_cacheEfficiency_half() {
        let usage = UsageData(
            date: Date(),
            inputTokens: 500, outputTokens: 200,
            cacheReadTokens: 500, cacheWriteTokens: 0,
            reasoningTokens: 0, cost: 0, perModel: []
        )
        XCTAssertEqual(usage.cacheEfficiency, 50, accuracy: 0.001)
    }

    func test_cacheEfficiency_allZero() {
        let usage = UsageData(
            date: Date(),
            inputTokens: 0, outputTokens: 0,
            cacheReadTokens: 0, cacheWriteTokens: 0,
            reasoningTokens: 0, cost: 0, perModel: []
        )
        XCTAssertEqual(usage.cacheEfficiency, 0)
    }

    // MARK: - totalTokens

    func test_totalTokens_sumsAllFields() {
        let usage = UsageData(
            date: Date(),
            inputTokens: 1_000, outputTokens: 2_000,
            cacheReadTokens: 3_000, cacheWriteTokens: 4_000,
            reasoningTokens: 5_000, cost: 0, perModel: []
        )
        XCTAssertEqual(usage.totalTokens, 15_000)
    }

    func test_totalTokens_zero() {
        let usage = UsageData(
            date: Date(),
            inputTokens: 0, outputTokens: 0,
            cacheReadTokens: 0, cacheWriteTokens: 0,
            reasoningTokens: 0, cost: 0, perModel: []
        )
        XCTAssertEqual(usage.totalTokens, 0)
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

    // MARK: - CodexReader

    func test_codexReader_usesBaselineBeforeRangeAndDeduplicatesSnapshots() {
        let lines = [
            tokenCountLine(ts: "2026-04-09T14:59:00Z",
                           input: 100, cachedInput: 20, output: 40, reasoning: 10, total: 140),
            tokenCountLine(ts: "2026-04-10T00:01:00Z",
                           input: 140, cachedInput: 30, output: 55, reasoning: 15, total: 195),
            tokenCountLine(ts: "2026-04-10T00:02:00Z",
                           input: 140, cachedInput: 30, output: 55, reasoning: 15, total: 195),
            tokenCountLine(ts: "2026-04-10T00:03:00Z",
                           input: 200, cachedInput: 50, output: 80, reasoning: 20, total: 280)
        ]

        let usage = CodexReader.usage(
            fromRolloutLines: lines,
            model: "gpt-5.4",
            from: isoDate("2026-04-10T00:00:00Z"),
            to: isoDate("2026-04-11T00:00:00Z")
        )

        XCTAssertEqual(usage.inputTokens, 70)
        XCTAssertEqual(usage.cacheReadTokens, 30)
        XCTAssertEqual(usage.outputTokens, 30)
        XCTAssertEqual(usage.reasoningTokens, 10)
        XCTAssertEqual(usage.totalTokens, 140)
        XCTAssertEqual(usage.perModel["gpt-5.4"]?.totalTokens, 140)
        XCTAssertEqual(usage.cost, 0.0007825, accuracy: 0.000001)
    }

    func test_codexReader_countsInitialSnapshotWhenSessionStartsInsideRange() {
        let lines = [
            tokenCountLine(ts: "2026-04-10T09:00:00Z",
                           input: 120, cachedInput: 20, output: 30, reasoning: 5, total: 150)
        ]

        let usage = CodexReader.usage(
            fromRolloutLines: lines,
            model: "gpt-5.4-mini",
            from: isoDate("2026-04-10T00:00:00Z"),
            to: isoDate("2026-04-11T00:00:00Z")
        )

        XCTAssertEqual(usage.inputTokens, 100)
        XCTAssertEqual(usage.cacheReadTokens, 20)
        XCTAssertEqual(usage.outputTokens, 25)
        XCTAssertEqual(usage.reasoningTokens, 5)
        XCTAssertEqual(usage.totalTokens, 150)
        XCTAssertEqual(usage.perModel["gpt-5.4-mini"]?.totalTokens, 150)
        XCTAssertEqual(usage.cost, 0.0002115, accuracy: 0.000001)
    }

    private func tokenCountLine(
        ts: String,
        input: Int, cachedInput: Int, output: Int, reasoning: Int, total: Int
    ) -> String {
        let usage = [
            "\"input_tokens\":\(input)",
            "\"cached_input_tokens\":\(cachedInput)",
            "\"output_tokens\":\(output)",
            "\"reasoning_output_tokens\":\(reasoning)",
            "\"total_tokens\":\(total)"
        ].joined(separator: ",")
        return """
        {"timestamp":"\(ts)","type":"event_msg",\
        "payload":{"type":"token_count","info":{"total_token_usage":{\(usage)}}}}
        """
    }

    private func isoDate(_ value: String) -> Date {
        guard let date = DateParser.parse(value) else {
            XCTFail("Failed to parse ISO date: \(value)")
            return Date.distantPast
        }
        return date
    }

}
