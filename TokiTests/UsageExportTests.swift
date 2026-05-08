import XCTest
@testable import Toki

final class UsageExportTests: XCTestCase {
    func test_csvExportIncludesTotalsSourcesAndModels() {
        let usage = UsageData(
            date: tokiTestISODate("2026-04-10T00:00:00Z"),
            inputTokens: 10,
            outputTokens: 5,
            cacheReadTokens: 2,
            cacheWriteTokens: 1,
            reasoningTokens: 3,
            cost: 0.25,
            activeSeconds: 120,
            perModel: [
                ModelStat(
                    id: "gpt-5.4",
                    totalTokens: 21,
                    cost: 0.25,
                    activeSeconds: 120,
                    sources: ["Codex"],
                    isPriceKnown: true),
            ],
            sourceStats: [
                SourceStat(
                    source: "Codex",
                    inputTokens: 10,
                    outputTokens: 5,
                    cacheReadTokens: 2,
                    cacheWriteTokens: 1,
                    reasoningTokens: 3,
                    cost: 0.25,
                    activeSeconds: 120),
            ])

        let csv = UsageExport.csvString(for: usage)

        XCTAssertTrue(csv.contains("section,name,input_tokens"))
        XCTAssertTrue(csv.contains("total,All,10,5,2,1,3,21,0.250000,120.000"))
        XCTAssertTrue(csv.contains("source,Codex,10,5,2,1,3,21,0.250000,120.000"))
        XCTAssertTrue(csv.contains("model,gpt-5.4,,,,,,21,0.250000,120.000"))
    }

    func test_jsonExportIncludesPriceKnownFlag() throws {
        let usage = UsageData(
            date: tokiTestISODate("2026-04-10T00:00:00Z"),
            inputTokens: 1,
            outputTokens: 0,
            cacheReadTokens: 0,
            cacheWriteTokens: 0,
            reasoningTokens: 0,
            cost: 0,
            activeSeconds: 0,
            perModel: [
                ModelStat(
                    id: "unknown-model",
                    totalTokens: 1,
                    cost: 0,
                    activeSeconds: 0,
                    sources: ["Mock"],
                    isPriceKnown: false),
            ])

        let data = try XCTUnwrap(UsageExport.jsonString(for: usage).data(using: .utf8))
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any])
        let models = try XCTUnwrap(object["models"] as? [[String: Any]])

        XCTAssertEqual(models.first?["model"] as? String, "unknown-model")
        XCTAssertEqual(models.first?["isPriceKnown"] as? Bool, false)
    }
}
