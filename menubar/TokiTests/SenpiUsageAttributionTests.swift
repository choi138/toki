import TokiUsageCore
import XCTest
@testable import Toki
@testable import TokiUsageReaders

final class SenpiUsageAttributionTests: XCTestCase {
    func test_reportAndExportKeepSenpiSourceModelProjectAndSession() throws {
        let start = tokiTestISODate("2026-08-20T00:00:00Z")
        let end = tokiTestISODate("2026-08-21T00:00:00Z")
        let usage = SenpiReader.usage(
            fromJSONLLines: [
                #"{"type":"session","id":"senpi-session","cwd":"/Users/example/Toki"}"#,
                """
                {"type":"message","id":"senpi-message","timestamp":"2026-08-20T12:00:00Z","message":{
                  "role":"assistant","model":"gpt-5.6-sol","provider":"openai",
                  "usage":{"input":10,"output":5,"cacheRead":2,"cacheWrite":1,"reasoning":2,"cost":{"total":0.25}}
                }}
                """,
            ],
            streamID: "/tmp/senpi.jsonl",
            from: start,
            to: end)

        let report = UsageReportBuilder.report(
            from: usage,
            date: start,
            endDate: end,
            sourceStats: [
                SourceStat(
                    source: "Senpi",
                    inputTokens: usage.inputTokens,
                    outputTokens: usage.outputTokens,
                    cacheReadTokens: usage.cacheReadTokens,
                    cacheWriteTokens: usage.cacheWriteTokens,
                    reasoningTokens: usage.reasoningTokens,
                    cost: usage.cost,
                    activeSeconds: usage.activeSeconds),
            ])
        let export = UsageExport.jsonString(for: report)
        let data = try XCTUnwrap(export.data(using: .utf8))
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let sources = try XCTUnwrap(object["sources"] as? [[String: Any]])
        let models = try XCTUnwrap(object["models"] as? [[String: Any]])
        let projects = try XCTUnwrap(object["projects"] as? [[String: Any]])
        let sessions = try XCTUnwrap(object["sessions"] as? [[String: Any]])

        XCTAssertEqual(report.totalTokens, 18)
        XCTAssertEqual(sources.first?["source"] as? String, "Senpi")
        XCTAssertEqual(models.first?["model"] as? String, "gpt-5.6-sol")
        XCTAssertEqual(models.first?["sources"] as? [String], ["Senpi"])
        XCTAssertEqual(projects.first?["path"] as? String, "/Users/example/Toki")
        XCTAssertEqual(projects.first?["sources"] as? [String], ["Senpi"])
        XCTAssertEqual(sessions.first?["source"] as? String, "Senpi")
        XCTAssertEqual(sessions.first?["sessionID"] as? String, "senpi-session")
    }
}
