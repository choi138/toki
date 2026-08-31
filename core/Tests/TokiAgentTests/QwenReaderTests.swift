import Foundation
import TokiUsageCore
import XCTest
@testable import TokiUsageReaders

final class QwenReaderTests: XCTestCase {
    private let startDate = Date(timeIntervalSince1970: 1_770_000_000)
    private let endDate = Date(timeIntervalSince1970: 1_780_000_000)

    func test_qwenMapsAssistantUsageMetadataWithoutInventingCost() {
        let lines = [
            #"{"type":"assistant","model":"qwen3.5-plus","timestamp":"2026-02-23T14:24:56.857Z","# +
                #""sessionId":"session-qwen","usageMetadata":{"promptTokenCount":120,"# +
                #""candidatesTokenCount":30,"thoughtsTokenCount":7,"cachedContentTokenCount":11}}"#,
            #"{"type":"session","model":"qwen3.5-plus","timestamp":"2026-02-23T14:25:00.000Z","# +
                #""sessionId":"session-qwen","usageMetadata":{"promptTokenCount":999,"# +
                #""candidatesTokenCount":999,"thoughtsTokenCount":999,"cachedContentTokenCount":999}}"#,
        ]

        let usage = QwenCLIReader.usage(
            fromJSONLLines: lines,
            streamID: "/tmp/.qwen/projects/workspace-qwen/chats/session.jsonl",
            from: startDate,
            to: endDate)

        XCTAssertEqual(usage.inputTokens, 109)
        XCTAssertEqual(usage.outputTokens, 30)
        XCTAssertEqual(usage.cacheReadTokens, 11)
        XCTAssertEqual(usage.cacheWriteTokens, 0)
        XCTAssertEqual(usage.reasoningTokens, 7)
        XCTAssertEqual(usage.totalTokens, 157)
        XCTAssertEqual(usage.cost, 0)
        XCTAssertEqual(usage.tokenEvents.map(\.source), ["Qwen CLI"])
        XCTAssertEqual(usage.tokenEvents.first?.model, "qwen3.5-plus")
        XCTAssertEqual(usage.tokenEvents.first?.provider, "qwen")
        XCTAssertEqual(usage.tokenEvents.first?.costIsKnown, false)
        XCTAssertEqual(usage.tokenEvents.first?.attribution?.sessionID, "session-qwen")
        XCTAssertEqual(usage.tokenEvents.first?.attribution?.projectName, "workspace-qwen")
        XCTAssertEqual(usage.activityEvents.count, 1)
    }

    func test_qwenDeduplicatesReplicatedSessionRecordsByStablePosition() {
        let lines = [
            #"{"type":"assistant","model":"qwen3-coder","timestamp":"2026-02-23T14:24:56.857Z","# +
                #""sessionId":"replicated","usageMetadata":{"promptTokenCount":20,"# +
                #""candidatesTokenCount":5}}"#,
        ]

        let usage = QwenCLIReader.usage(
            fromJSONLSessions: [
                (
                    streamID: "/tmp/default/projects/workspace/chats/one.jsonl",
                    lines: lines),
                (
                    streamID: "/tmp/override/projects/workspace/chats/copy.jsonl",
                    lines: lines),
            ],
            from: startDate,
            to: endDate)

        XCTAssertEqual(usage.totalTokens, 25)
        XCTAssertEqual(usage.tokenEvents.count, 1)
    }

    func test_qwenPartialReplicaDoesNotShiftEventIdentity() {
        let first = [
            #"{"type":"assistant","model":"qwen3-coder","timestamp":"2026-02-23T14:24:56.857Z","#,
            #""sessionId":"partial","usageMetadata":{"promptTokenCount":10}}"#,
        ].joined()
        let second = [
            #"{"type":"assistant","model":"qwen3-coder","timestamp":"2026-02-23T14:25:56.857Z","#,
            #""sessionId":"partial","usageMetadata":{"promptTokenCount":20}}"#,
        ].joined()

        let usage = QwenCLIReader.usage(
            fromJSONLSessions: [
                (
                    streamID: "/tmp/default/projects/workspace/chats/one.jsonl",
                    lines: [first, second]),
                (
                    streamID: "/tmp/override/projects/workspace/chats/copy.jsonl",
                    lines: [second]),
            ],
            from: startDate,
            to: endDate)

        XCTAssertEqual(usage.inputTokens, 30)
        XCTAssertEqual(usage.tokenEvents.count, 2)
    }

    func test_qwenSameExplicitSessionAcrossProjectsRemainsIndependent() {
        let event = [
            #"{"type":"assistant","model":"qwen3-coder","timestamp":"2026-02-23T14:24:56.857Z","#,
            #""sessionId":"shared-session","usageMetadata":{"promptTokenCount":10}}"#,
        ].joined()

        let usage = QwenCLIReader.usage(
            fromJSONLSessions: [
                (
                    streamID: "/tmp/.qwen/projects/project-a/chats/one.jsonl",
                    lines: [event]),
                (
                    streamID: "/tmp/.qwen/projects/project-b/chats/two.jsonl",
                    lines: [event]),
            ],
            from: startDate,
            to: endDate)

        XCTAssertEqual(usage.inputTokens, 20)
        XCTAssertEqual(usage.tokenEvents.count, 2)
        XCTAssertEqual(
            Set(usage.tokenEvents.compactMap(\.attribution?.projectName)),
            ["project-a", "project-b"])
    }

    func test_qwenSkipsMalformedAndTruncatedRecords() {
        let usage = QwenCLIReader.usage(
            fromJSONLLines: [
                #"{"type":"assistant","model":"qwen3","timestamp":"2026-02-23T14:24:56.857Z","# +
                    #""usageMetadata":{"promptTokenCount":10,"candidatesTokenCount":2}}"#,
                "not-json",
                #"{"type":"assistant","usageMetadata":"#,
            ],
            streamID: "/tmp/.qwen/projects/workspace/chats/fallback-session.jsonl",
            from: startDate,
            to: endDate)

        XCTAssertEqual(usage.totalTokens, 12)
        XCTAssertEqual(usage.tokenEvents.first?.attribution?.sessionID, "workspace-fallback-session")
    }

    func test_qwenDiscoveryUsesBothOfficialAbsoluteRuntimeOverrides() {
        let paths = LocalUsageReaderPaths(
            homeDirectory: URL(fileURLWithPath: "/tmp/toki-home"),
            environment: [
                "QWEN_HOME": "/tmp/qwen-home",
                "QWEN_RUNTIME_DIR": "/tmp/qwen-runtime",
            ])

        XCTAssertEqual(
            paths.qwenProjects.map(\.path),
            [
                "/tmp/toki-home/.qwen/projects",
                "/tmp/qwen-home/projects",
                "/tmp/qwen-runtime/projects",
            ])
    }
}
