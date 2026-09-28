import TokiUsageCore
import XCTest
@testable import TokiUsageReaders

final class Opus55PricingTests: XCTestCase {
    private let date = Date(timeIntervalSince1970: 1_790_553_600) // 2026-09-28T00:00:00Z
    private lazy var interval = DateInterval(start: date, duration: 86400)

    override func setUp() {
        super.setUp()
        ModelPricingSupplement.install([:])
    }

    override func tearDown() {
        ModelPricingSupplement.install([:])
        super.tearDown()
    }

    func test_opus55UsesStandardRatesAndExactMatching() throws {
        let lookup = modelPriceLookup(for: "claude-opus-5-5", at: date)
        let price = try XCTUnwrap(lookup.price)

        XCTAssertEqual(lookup.match, .exact(modelId: "claude-opus-5-5"))
        XCTAssertEqual(price.inputPerMillion, 4.0)
        XCTAssertEqual(price.outputPerMillion, 20.0)
        XCTAssertEqual(price.cacheReadPerMillion, 0.20)
        XCTAssertEqual(price.cacheWritePerMillion, 5.0)
        XCTAssertEqual(price.cacheWriteOneHourPerMillion, 8.0)
        XCTAssertTrue(modelPriceIsKnown(for: "claude-opus-5-5", throughout: interval))
    }

    func test_opus55UnknownDerivativesStayMissing() {
        let ids = ["-mini", "-preview", "-fast", "-20260922", "-50", "0"].map { "claude-opus-5-5\($0)" }
            + ["kr/claude-opus-5-5"]
        for modelID in ids {
            XCTAssertNil(modelPrice(for: modelID, at: date), "\(modelID) must stay unpriced")
            XCTAssertFalse(modelPriceIsKnown(for: modelID, throughout: interval), "\(modelID) must be unknown")
        }
    }

    func test_opus55SupplementPricesExplicitDerivativeWithoutOverridingCuratedRate() throws {
        let supplement = ModelPrice(
            inputPerMillion: 99,
            outputPerMillion: 99,
            cacheReadPerMillion: 99,
            cacheWritePerMillion: 99)
        ModelPricingSupplement.install(["claude-opus-5-5-mini": supplement, "claude-opus-5-5": supplement])

        XCTAssertEqual(
            modelPriceLookup(for: "claude-opus-5-5-mini", at: date).match,
            .supplement(modelId: "claude-opus-5-5-mini"))
        XCTAssertEqual(try XCTUnwrap(modelPrice(for: "claude-opus-5-5-mini", at: date)).inputPerMillion, 99)
        XCTAssertTrue(modelPriceIsKnown(for: "claude-opus-5-5-mini", throughout: interval))
        XCTAssertEqual(try XCTUnwrap(modelPrice(for: "claude-opus-5-5", at: date)).inputPerMillion, 4.0)
        XCTAssertEqual(modelPriceLookup(for: "claude-opus-5-5", at: date).match, .exact(modelId: "claude-opus-5-5"))
    }

    func test_opus55LeavesOpus5AndDatesUnchanged() throws {
        let opus5 = try XCTUnwrap(modelPrice(for: "claude-opus-5", at: date))
        XCTAssertEqual(opus5.inputPerMillion, 5.0)
        XCTAssertEqual(opus5.outputPerMillion, 25.0)
        XCTAssertEqual(opus5.cacheReadPerMillion, 0.50)
        XCTAssertEqual(opus5.cacheWritePerMillion, 6.25)
        XCTAssertEqual(opus5.cacheWriteOneHourPerMillion, 10.0)

        let before = try XCTUnwrap(modelPrice(for: "claude-opus-5-5", at: Date(timeIntervalSince1970: 1_788_220_799)))
        let after = try XCTUnwrap(modelPrice(for: "claude-opus-5-5", at: date))
        XCTAssertEqual(before.inputPerMillion, after.inputPerMillion)
        XCTAssertEqual(before.outputPerMillion, after.outputPerMillion)
        XCTAssertEqual(before.cacheReadPerMillion, after.cacheReadPerMillion)
        XCTAssertEqual(before.cacheWritePerMillion, after.cacheWritePerMillion)
        XCTAssertEqual(before.cacheWriteOneHourPerMillion, after.cacheWriteOneHourPerMillion)
    }

    func test_opus55JSONLReaderCalculatesStandardCacheCosts() throws {
        let usage = read(opus55JSONL(
            input: 1_000_000, output: 1_000_000, cacheRead: 1_000_000,
            cacheCreation: 2_000_000,
            ttl: "\"ephemeral_5m_input_tokens\":1000000,\"ephemeral_1h_input_tokens\":1000000"))

        XCTAssertEqual(usage.inputTokens, 1_000_000)
        XCTAssertEqual(usage.outputTokens, 1_000_000)
        XCTAssertEqual(usage.cacheReadTokens, 1_000_000)
        XCTAssertEqual(usage.cacheWriteTokens, 2_000_000)
        XCTAssertEqual(usage.cost, 37.20, accuracy: 0.0001)
        XCTAssertEqual(try XCTUnwrap(usage.perModel["claude-opus-5-5"]?.cost), 37.20, accuracy: 0.0001)
    }

    func test_opus55JSONLReaderUsesOneHourCacheRate() {
        let usage = read(opus55JSONL(
            cacheCreation: 1_000_000,
            ttl: "\"ephemeral_5m_input_tokens\":0,\"ephemeral_1h_input_tokens\":1000000"))
        XCTAssertEqual(usage.cacheWriteTokens, 1_000_000)
        XCTAssertEqual(usage.cost, 8.0, accuracy: 0.0001)
    }

    func test_opus55JSONLReaderUsesLegacyAggregateCacheRate() {
        let usage = read(opus55JSONL(cacheCreation: 1_000_000))
        XCTAssertEqual(usage.cacheWriteTokens, 1_000_000)
        XCTAssertEqual(usage.cost, 5.0, accuracy: 0.0001)
    }

    private func read(_ line: String) -> RawTokenUsage {
        ClaudeCodeReader.usage(
            fromJSONLLines: [line], streamID: "opus-5-5-test",
            from: date, to: date.addingTimeInterval(3600))
    }

    private func opus55JSONL(
        input: Int = 0, output: Int = 0, cacheRead: Int = 0,
        cacheCreation: Int, ttl: String? = nil) -> String {
        let ttlField = ttl.map { ",\"cache_creation\":{\($0)}" } ?? ""
        return """
        {"type":"assistant","timestamp":"2026-09-28T00:00:00Z","requestId":"req-opus55",\
        "message":{"id":"msg-opus55","model":"claude-opus-5-5","usage":{\
        "input_tokens":\(input),"output_tokens":\(output),"cache_read_input_tokens":\(cacheRead),\
        "cache_creation_input_tokens":\(cacheCreation)\(ttlField)}}}
        """
    }
}
