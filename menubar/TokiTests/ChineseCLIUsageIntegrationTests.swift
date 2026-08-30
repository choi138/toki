import Foundation
import TokiUsageCore
import TokiUsageReaders
import XCTest
@testable import Toki

final class ChineseCLIUsageIntegrationTests: XCTestCase {
    func test_kimiAndQwenReadersPreserveSourceModelExportDiagnosticsAndDateBoundary() async throws {
        let fixture = try ChineseCLIUsageFixture()
        defer { fixture.remove() }
        let readers: [any TokenReader] = [
            KimiCLIReader(sessionRoots: [fixture.kimiCLIRoot]),
            KimiCodeReader(sessionRoots: [fixture.kimiCodeRoot]),
            QwenCLIReader(projectRoots: [fixture.qwenRoot]),
        ]
        let request = UsageAggregationRequest(
            start: fixture.startDate,
            end: fixture.endDate,
            enabledReaderNames: [:],
            includesEmptySourceRows: false)

        let result = await UsageAggregator(readers: readers).aggregateUsage(for: request)

        XCTAssertEqual(
            result.readerStatuses.map(\.name),
            ["Kimi CLI", "Kimi Code", "Qwen CLI"])
        XCTAssertEqual(result.readerStatuses.map(\.state), [.loaded, .loaded, .loaded])
        XCTAssertEqual(
            Set(result.usageData.sourceStats.map(\.source)),
            ["Kimi CLI", "Kimi Code", "Qwen CLI"])
        XCTAssertEqual(
            Set(result.usageData.perModel.map(\.modelID)),
            ["kimi-for-coding", "moonshot/kimi-k2.6", "qwen3.5-plus"])
        XCTAssertEqual(result.usageData.totalTokens, 96)
        XCTAssertEqual(
            Set(result.usageData.sessionStats.map(\.source)),
            ["Kimi CLI", "Kimi Code", "Qwen CLI"])

        let data = try XCTUnwrap(UsageExport.jsonString(for: result.usageData).data(using: .utf8))
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let sources = try XCTUnwrap(object["sources"] as? [[String: Any]])
        let models = try XCTUnwrap(object["models"] as? [[String: Any]])
        let sessions = try XCTUnwrap(object["sessions"] as? [[String: Any]])

        XCTAssertEqual(
            Set(sources.compactMap { $0["source"] as? String }),
            ["Kimi CLI", "Kimi Code", "Qwen CLI"])
        XCTAssertEqual(
            Set(models.compactMap { $0["model"] as? String }),
            ["kimi-for-coding", "moonshot/kimi-k2.6", "qwen3.5-plus"])
        XCTAssertEqual(
            Set(sessions.compactMap { $0["source"] as? String }),
            ["Kimi CLI", "Kimi Code", "Qwen CLI"])
    }

    func test_kimiSameNamedSessionsRemainSeparateInReportAndExport() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("toki-kimi-sessions-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let sessionsRoot = root.appendingPathComponent(".kimi/sessions")
        for (workspace, tokens) in [("workspace-a", 10), ("workspace-b", 20)] {
            let file = sessionsRoot.appendingPathComponent(
                "\(workspace)/session/wire.jsonl")
            try FileManager.default.createDirectory(
                at: file.deletingLastPathComponent(),
                withIntermediateDirectories: true)
            let line =
                #"{"timestamp":1771855200.0,"message":{"type":"StatusUpdate","payload":{"# +
                #""token_usage":{"input_other":"# + String(tokens) +
                #","output":0},"message_id":"same-message"}}}"#
            try Data((line + "\n").utf8).write(to: file)
        }
        let request = try UsageAggregationRequest(
            start: Self.date("2026-02-23T00:00:00Z"),
            end: Self.date("2026-02-24T00:00:00Z"),
            enabledReaderNames: [:],
            includesEmptySourceRows: false)

        let result = await UsageAggregator(
            readers: [KimiCLIReader(sessionRoots: [sessionsRoot])])
            .aggregateUsage(for: request)

        XCTAssertEqual(result.usageData.sessionStats.count, 2)
        XCTAssertEqual(
            Set(result.usageData.sessionStats.map(\.projectName)),
            ["workspace-a", "workspace-b"])
        XCTAssertEqual(Set(result.usageData.sessionStats.map(\.sessionLabel)), ["session"])

        let data = try XCTUnwrap(
            UsageExport.jsonString(for: result.usageData).data(using: .utf8))
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let sessions = try XCTUnwrap(object["sessions"] as? [[String: Any]])
        XCTAssertEqual(sessions.count, 2)
        XCTAssertEqual(
            Set(sessions.compactMap { $0["projectName"] as? String }),
            ["workspace-a", "workspace-b"])
    }

    private static func date(_ value: String) throws -> Date {
        try XCTUnwrap(ISO8601DateFormatter().date(from: value))
    }
}

private struct ChineseCLIUsageFixture {
    let root: URL
    let kimiCLIRoot: URL
    let kimiCodeRoot: URL
    let qwenRoot: URL
    let startDate: Date
    let endDate: Date

    init() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("toki-chinese-cli-\(UUID().uuidString)")
        kimiCLIRoot = root.appendingPathComponent(".kimi/sessions")
        kimiCodeRoot = root.appendingPathComponent(".kimi-code/sessions")
        qwenRoot = root.appendingPathComponent(".qwen/projects")
        startDate = try Self.date("2026-02-23T00:00:00Z")
        endDate = try Self.date("2026-02-24T00:00:00Z")

        try Self.write(
            [
                #"{"timestamp":1771855200.0,"message":{"type":"StatusUpdate","payload":{"# +
                    #""token_usage":{"input_other":20,"output":5,"input_cache_read":2,"# +
                    #""input_cache_creation":1},"message_id":"cli-1"}}}"#,
                #"{"timestamp":1771891200.0,"message":{"type":"StatusUpdate","payload":{"# +
                    #""token_usage":{"input_other":999,"output":999},"message_id":"cli-end"}}}"#,
            ],
            to: kimiCLIRoot.appendingPathComponent("workspace-cli/session-cli/wire.jsonl"))
        try Self.write(
            [
                #"{"type":"usage.record","model":"moonshot/kimi-k2.6","usage":{"inputOther":30,"# +
                    #""output":8,"inputCacheRead":3,"inputCacheCreation":2},"usageScope":"turn","# +
                    #""time":1771858800000}"#,
            ],
            to: kimiCodeRoot.appendingPathComponent(
                "workspace-code/session-code/agents/main/wire.jsonl"))
        try Self.write(
            [
                #"{"type":"assistant","model":"qwen3.5-plus","timestamp":"2026-02-23T16:00:00Z","# +
                    #""sessionId":"session-qwen","usageMetadata":{"promptTokenCount":20,"# +
                    #""candidatesTokenCount":4,"thoughtsTokenCount":1,"cachedContentTokenCount":1}}"#,
            ],
            to: qwenRoot.appendingPathComponent("workspace-qwen/chats/session-qwen.jsonl"))
    }

    func remove() {
        try? FileManager.default.removeItem(at: root)
    }

    private static func write(_ lines: [String], to url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true)
        try Data((lines.joined(separator: "\n") + "\n").utf8).write(to: url)
    }

    private static func date(_ value: String) throws -> Date {
        try XCTUnwrap(ISO8601DateFormatter().date(from: value))
    }
}
