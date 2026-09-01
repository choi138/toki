import TokiUsageCore
import XCTest
@testable import Toki
@testable import TokiUsageReaders

final class GJCReaderTests: XCTestCase {
    func test_gjcReaderOnlyParsesAppendedBytesAfterInitialRead() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("toki-gjc-incremental-cache-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let sessionURL = directory.appendingPathComponent("session.jsonl")
        let initialLines = [
            gjcSessionLine(),
            gjcAssistantLine(
                timestamp: "2026-04-10T10:00:00Z",
                input: 100,
                output: 20),
        ]
        try Data((initialLines.joined(separator: "\n") + "\n").utf8).write(to: sessionURL)

        let cache = PiCompatibleUsageFileCache()
        let reader = GJCReader(
            sessionsURLOverride: directory,
            usageFileCache: cache)
        let start = tokiTestISODate("2026-04-10T00:00:00Z")
        let end = tokiTestISODate("2026-04-11T00:00:00Z")

        let initialUsage = try await reader.readUsage(from: start, to: end)
        let initialBytesRead = cache.bytesRead
        XCTAssertEqual(initialUsage.totalTokens, 120)
        XCTAssertEqual(initialBytesRead, try Data(contentsOf: sessionURL).count)

        let appendedLine = gjcAssistantLine(
            timestamp: "2026-04-10T10:05:00Z",
            input: 50,
            output: 10)
        let appendedData = Data((appendedLine + "\n").utf8)
        let handle = try FileHandle(forWritingTo: sessionURL)
        try handle.seekToEnd()
        try handle.write(contentsOf: appendedData)
        try handle.close()

        let updatedUsage = try await reader.readUsage(from: start, to: end)
        let finalBytesRead = cache.bytesRead

        XCTAssertEqual(updatedUsage.totalTokens, 180)
        XCTAssertEqual(finalBytesRead, initialBytesRead + appendedData.count)
    }

    func test_gjcReader_countsAssistantAndTaskUsageInsideRange() {
        let usage = GJCReader.usage(
            fromJSONLLines: [
                gjcSessionLine(id: "session-123", cwd: "/Users/example/Desktop/gajae-code"),
                gjcAssistantLine(
                    timestamp: "2026-04-10T12:00:00Z",
                    model: "gpt-5.4",
                    input: 100,
                    output: 30,
                    cacheRead: 8,
                    cacheWrite: 2,
                    reasoning: 7,
                    cost: 0.005),
                gjcTaskToolResultLine(
                    timestamp: "2026-04-10T12:05:00Z",
                    input: 50,
                    output: 12,
                    cacheRead: 4,
                    cacheWrite: 1,
                    cost: 0.002),
            ],
            streamID: "/tmp/session-123.jsonl",
            from: tokiTestISODate("2026-04-10T00:00:00Z"),
            to: tokiTestISODate("2026-04-11T00:00:00Z"))

        XCTAssertEqual(usage.inputTokens, 150)
        XCTAssertEqual(usage.outputTokens, 35)
        XCTAssertEqual(usage.cacheReadTokens, 12)
        XCTAssertEqual(usage.cacheWriteTokens, 3)
        XCTAssertEqual(usage.reasoningTokens, 7)
        XCTAssertEqual(usage.totalTokens, 207)
        XCTAssertEqual(usage.cost, 0.007, accuracy: 0.000001)
        XCTAssertEqual(usage.perModel["gpt-5.4"]?.totalTokens, 140)
        XCTAssertEqual(usage.perModel["gpt-5.4"]?.cost ?? 0, 0.005, accuracy: 0.000001)
        XCTAssertEqual(usage.perModel["gpt-5.4"]?.sources, ["GJC"])
        XCTAssertEqual(usage.tokenEvents.map(\.source), ["GJC", "GJC"])
        XCTAssertEqual(usage.tokenEvents.map(\.totalTokens), [140, 67])
        XCTAssertEqual(usage.tokenEvents.map(\.model), ["gpt-5.4", nil])
        // The unnamed-model event must also leave a per-model row, otherwise the report drops it
        // once another source reports the shared mixed/unattributed key.
        let mixedKey = UsageModelGrouping.mixedOrUnattributedKey
        XCTAssertEqual(usage.perModel[mixedKey]?.totalTokens, 67)
        XCTAssertEqual(usage.perModel[mixedKey]?.sources, ["GJC"])
    }

    func test_gjcReader_ignoresOutOfRangeAndNonTaskToolUsage() {
        let usage = GJCReader.usage(
            fromJSONLLines: [
                gjcSessionLine(),
                gjcAssistantLine(
                    timestamp: "2026-04-09T23:59:59Z",
                    input: 100,
                    output: 20),
                gjcAssistantLine(
                    timestamp: "2026-04-10T10:00:00Z",
                    input: 200,
                    output: 30),
                gjcTaskToolResultLine(
                    timestamp: "2026-04-10T11:00:00Z",
                    toolName: "read",
                    input: 300,
                    output: 40),
                gjcAssistantLine(
                    timestamp: "2026-04-11T00:00:00Z",
                    input: 400,
                    output: 50),
            ],
            streamID: "/tmp/session-123.jsonl",
            from: tokiTestISODate("2026-04-10T00:00:00Z"),
            to: tokiTestISODate("2026-04-11T00:00:00Z"))

        XCTAssertEqual(usage.inputTokens, 200)
        XCTAssertEqual(usage.outputTokens, 30)
        XCTAssertEqual(usage.totalTokens, 230)
        XCTAssertEqual(usage.tokenEvents.count, 1)
        XCTAssertEqual(usage.tokenEvents.first?.timestamp, tokiTestISODate("2026-04-10T10:00:00Z"))
    }

    func test_gjcReader_attachesSessionAttributionFromHeader() {
        let usage = GJCReader.usage(
            fromJSONLLines: [
                gjcSessionLine(id: "gjc-session-a", cwd: "/Users/example/Toki"),
                gjcAssistantLine(
                    timestamp: "2026-04-10T09:00:00Z",
                    input: 120,
                    output: 40),
            ],
            streamID: "/tmp/fallback-session.jsonl",
            from: tokiTestISODate("2026-04-10T00:00:00Z"),
            to: tokiTestISODate("2026-04-11T00:00:00Z"))

        let attribution = usage.tokenEvents.first?.attribution
        XCTAssertEqual(attribution?.projectPath, "/Users/example/Toki")
        XCTAssertEqual(attribution?.projectName, "Toki")
        XCTAssertEqual(attribution?.sessionID, "gjc-session-a")
        XCTAssertEqual(attribution?.quality, .exact)
        XCTAssertEqual(usage.activityEvents.map(\.streamID), ["gjc-session-a"])
    }
}

private func gjcSessionLine(
    id: String = "session-123",
    cwd: String = "/Users/example/Toki",
    timestamp: String = "2026-04-10T08:00:00Z") -> String {
    """
    {"type":"session","id":"\(id)","timestamp":"\(timestamp)","cwd":"\(cwd)"}
    """
}

private func gjcAssistantLine(
    timestamp: String,
    model: String? = nil,
    input: Int,
    output: Int,
    cacheRead: Int = 0,
    cacheWrite: Int = 0,
    reasoning: Int? = nil,
    cost: Double? = nil) -> String {
    let usage = gjcUsageJSON(
        input: input,
        output: output,
        cacheRead: cacheRead,
        cacheWrite: cacheWrite,
        reasoning: reasoning,
        cost: cost)
    var messageFields = [
        "\"role\":\"assistant\"",
        "\"usage\":\(usage)",
    ]
    if let model {
        messageFields.append("\"model\":\"\(model)\"")
    }
    return """
    {"type":"message","timestamp":"\(timestamp)","message":{\(messageFields.joined(separator: ","))}}
    """
}

private func gjcTaskToolResultLine(
    timestamp: String,
    toolName: String = "task",
    input: Int,
    output: Int,
    cacheRead: Int = 0,
    cacheWrite: Int = 0,
    reasoning: Int? = nil,
    cost: Double? = nil) -> String {
    let usage = gjcUsageJSON(
        input: input,
        output: output,
        cacheRead: cacheRead,
        cacheWrite: cacheWrite,
        reasoning: reasoning,
        cost: cost)
    let messageFields = [
        "\"role\":\"toolResult\"",
        "\"toolName\":\"\(toolName)\"",
        "\"details\":{\"usage\":\(usage)}",
    ]
    return """
    {"type":"message","timestamp":"\(timestamp)","message":{\(messageFields.joined(separator: ","))}}
    """
}

private func gjcUsageJSON(
    input: Int,
    output: Int,
    cacheRead: Int = 0,
    cacheWrite: Int = 0,
    reasoning: Int? = nil,
    cost: Double? = nil) -> String {
    var fields = [
        "\"input\":\(input)",
        "\"output\":\(output)",
        "\"cacheRead\":\(cacheRead)",
        "\"cacheWrite\":\(cacheWrite)",
    ]
    if let reasoning {
        fields.append("\"reasoningTokens\":\(reasoning)")
    }
    if let cost {
        fields.append("\"cost\":{\"total\":\(cost)}")
    }
    return "{\(fields.joined(separator: ","))}"
}
