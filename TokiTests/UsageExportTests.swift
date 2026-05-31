import XCTest
@testable import Toki

final class UsageExportTests: XCTestCase {
    func test_csvExportIncludesTotalsSourcesAndModels() {
        let usage = UsageData(
            date: tokiTestISODate("2026-04-10T00:00:00Z"),
            endDate: tokiTestISODate("2026-04-11T00:00:00Z"),
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
            ],
            projectStats: [
                ProjectUsageStat(
                    id: "/Users/example/Toki",
                    name: "Toki",
                    path: "/Users/example/Toki",
                    quality: .exact,
                    sources: ["Codex"],
                    sessionCount: 1,
                    inputTokens: 10,
                    outputTokens: 5,
                    cacheReadTokens: 2,
                    cacheWriteTokens: 1,
                    reasoningTokens: 3,
                    cost: 0.25,
                    firstActivityAt: tokiTestISODate("2026-04-10T01:00:00Z"),
                    lastActivityAt: tokiTestISODate("2026-04-10T01:05:00Z")),
            ],
            sessionStats: [
                SessionUsageStat(
                    id: "Codex|session-a",
                    source: "Codex",
                    projectName: "Toki",
                    projectPath: "/Users/example/Toki",
                    sessionID: "session-a",
                    sessionLabel: "session-a",
                    quality: .exact,
                    models: ["gpt-5.4"],
                    inputTokens: 10,
                    outputTokens: 5,
                    cacheReadTokens: 2,
                    cacheWriteTokens: 1,
                    reasoningTokens: 3,
                    cost: 0.25,
                    firstActivityAt: tokiTestISODate("2026-04-10T01:00:00Z"),
                    lastActivityAt: tokiTestISODate("2026-04-10T01:05:00Z")),
            ])

        let csv = UsageExport.csvString(for: usage)

        XCTAssertTrue(csv.contains("section,name,source,model,input_tokens"))
        XCTAssertTrue(csv.contains("project_path,session_id,attribution_quality"))
        XCTAssertTrue(csv.contains("total,All,,,10,5,2,1,3,21,0.250000,120.000"))
        XCTAssertTrue(csv.contains("2026-04-10T00:00:00Z,2026-04-11T00:00:00Z"))
        XCTAssertTrue(csv.contains("source,Codex,Codex,,10,5,2,1,3,21,0.250000,120.000"))
        XCTAssertTrue(csv.contains("model,gpt-5.4,Codex,gpt-5.4,,,,,,21,0.250000,120.000"))
        XCTAssertTrue(csv.contains("project,Toki,Codex,,10,5,2,1,3,21,0.250000,"))
        XCTAssertTrue(csv.contains("session,Toki,Codex,gpt-5.4,10,5,2,1,3,21,0.250000,"))
        XCTAssertTrue(csv.contains("/Users/example/Toki,session-a,exact"))
    }

    func test_jsonExportIncludesRangeAndPriceKnownFlag() throws {
        let usage = UsageData(
            date: tokiTestISODate("2026-04-10T00:00:00Z"),
            endDate: tokiTestISODate("2026-04-12T00:00:00Z"),
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
        let projects = try XCTUnwrap(object["projects"] as? [[String: Any]])
        let sessions = try XCTUnwrap(object["sessions"] as? [[String: Any]])

        XCTAssertEqual(object["date"] as? String, "2026-04-10T00:00:00Z")
        XCTAssertEqual(object["startDate"] as? String, "2026-04-10T00:00:00Z")
        XCTAssertEqual(object["endDate"] as? String, "2026-04-12T00:00:00Z")
        XCTAssertEqual(models.first?["model"] as? String, "unknown-model")
        XCTAssertEqual(models.first?["isPriceKnown"] as? Bool, false)
        XCTAssertTrue(projects.isEmpty)
        XCTAssertTrue(sessions.isEmpty)
    }
}
