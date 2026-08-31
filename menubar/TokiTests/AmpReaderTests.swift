import Foundation
import TokiUsageCore
import XCTest
@testable import TokiUsageReaders

final class AmpReaderTests: XCTestCase {
    func test_currentThreadMapsAssistantUsageAndAttribution() async throws {
        let fixture = try AmpFixture()
        defer { fixture.remove() }
        try fixture.writeThread([
            "id": "T-current",
            "created": fixture.milliseconds("2026-08-20T10:00:00Z"),
            "environment": [
                "workspaceRoot": "/Users/example/Toki",
                "workingDirectory": "/Users/example/Toki/core",
            ],
            "messages": [
                [
                    "role": "assistant",
                    "messageId": 7,
                    "createdAt": "2026-08-20T10:05:00Z",
                    "usage": [
                        "model": "claude-sonnet-4-6",
                        "maxInputTokens": 200_000,
                        "inputTokens": 100,
                        "outputTokens": 25,
                        "cacheReadInputTokens": 30,
                        "cacheCreationInputTokens": 5,
                        "totalInputTokens": 135,
                        "thinkingBudget": 20000,
                    ],
                ],
            ],
        ])

        let usage = try await fixture.reader.readUsage(
            from: fixture.date("2026-08-20T00:00:00Z"),
            to: fixture.date("2026-08-21T00:00:00Z"))

        XCTAssertEqual(usage.inputTokens, 100)
        XCTAssertEqual(usage.outputTokens, 25)
        XCTAssertEqual(usage.cacheReadTokens, 30)
        XCTAssertEqual(usage.cacheWriteTokens, 5)
        XCTAssertEqual(usage.reasoningTokens, 0)
        XCTAssertEqual(usage.totalTokens, 160)
        XCTAssertEqual(usage.tokenEvents.count, 1)
        XCTAssertEqual(usage.tokenEvents.first?.source, "Amp")
        XCTAssertEqual(usage.tokenEvents.first?.model, "claude-sonnet-4-6")
        XCTAssertEqual(usage.tokenEvents.first?.provider, "anthropic")
        XCTAssertEqual(usage.tokenEvents.first?.costIsKnown, false)
        XCTAssertEqual(usage.tokenEvents.first?.attribution?.sessionID, "T-current")
        XCTAssertEqual(usage.tokenEvents.first?.attribution?.projectPath, "/Users/example/Toki")
        XCTAssertEqual(usage.tokenEvents.first?.attribution?.projectName, "Toki")
        XCTAssertEqual(usage.tokenEvents.first?.attribution?.quality, .exact)
        XCTAssertEqual(usage.activityEvents.count, 1)
    }

    func test_ledgerPreservesRecordedCreditsAndReconcilesMessageDetailByID() async throws {
        let fixture = try AmpFixture()
        defer { fixture.remove() }
        try fixture.writeThread([
            "id": "T-ledger",
            "created": fixture.milliseconds("2026-08-20T10:00:00Z"),
            "usageLedger": [
                "events": [
                    [
                        "timestamp": "2026-08-20T10:05:00Z",
                        "model": "gpt-5.4",
                        "credits": 0.42,
                        "fromMessageId": 6,
                        "toMessageId": 7,
                        "tokens": [
                            "input": 90,
                            "output": 20,
                            "cacheReadInputTokens": 15,
                            "cacheCreationInputTokens": 3,
                        ],
                    ],
                ],
                "total": [
                    "input": 90,
                    "output": 20,
                ],
            ],
            "messages": [
                [
                    "role": "assistant",
                    "messageId": 7,
                    "createdAt": "2026-08-20T10:05:00Z",
                    "usage": [
                        "model": "gpt-5.4",
                        "inputTokens": 90,
                        "outputTokens": 20,
                        "cacheReadInputTokens": 15,
                        "cacheCreationInputTokens": 3,
                        "credits": 0.42,
                    ],
                ],
            ],
        ])

        let usage = try await fixture.reader.readUsage(
            from: fixture.date("2026-08-20T00:00:00Z"),
            to: fixture.date("2026-08-21T00:00:00Z"))

        XCTAssertEqual(usage.totalTokens, 128)
        XCTAssertEqual(usage.tokenEvents.count, 1)
        XCTAssertEqual(usage.cost, 0.42, accuracy: 0.000_001)
        XCTAssertEqual(
            try XCTUnwrap(usage.tokenEvents.first?.cost),
            0.42,
            accuracy: 0.000_001)
        XCTAssertEqual(usage.tokenEvents.first?.costIsKnown, true)
        XCTAssertEqual(usage.tokenEvents.first?.provider, "openai")
    }

    func test_duplicateLedgerAndMessageEventsAreDeduplicatedByStableIDs() async throws {
        let fixture = try AmpFixture()
        defer { fixture.remove() }
        let ledgerEvent: [String: Any] = [
            "timestamp": "2026-08-20T11:00:00Z",
            "model": "claude-sonnet-4-6",
            "toMessageId": 9,
            "tokens": ["input": 50, "output": 10],
        ]
        let message: [String: Any] = [
            "role": "assistant",
            "messageId": 9,
            "createdAt": "2026-08-20T11:00:00Z",
            "usage": [
                "model": "claude-sonnet-4-6",
                "inputTokens": 50,
                "outputTokens": 10,
            ],
        ]
        try fixture.writeThread([
            "id": "T-dedup",
            "created": fixture.milliseconds("2026-08-20T10:00:00Z"),
            "usageLedger": ["events": [ledgerEvent, ledgerEvent]],
            "messages": [message, message],
        ])

        let usage = try await fixture.reader.readUsage(
            from: fixture.date("2026-08-20T00:00:00Z"),
            to: fixture.date("2026-08-21T00:00:00Z"))

        XCTAssertEqual(usage.totalTokens, 60)
        XCTAssertEqual(usage.tokenEvents.count, 1)
        XCTAssertEqual(usage.activityEvents.count, 1)
    }
}

extension AmpReaderTests {
    func test_malformedRecordsAreSkippedWithoutDroppingValidUsage() async throws {
        let fixture = try AmpFixture()
        defer { fixture.remove() }
        try fixture.writeThread([
            "id": "T-malformed",
            "created": fixture.milliseconds("2026-08-20T10:00:00Z"),
            "messages": [
                [
                    "role": "assistant",
                    "messageId": 1,
                    "createdAt": "2026-08-20T10:01:00Z",
                    "usage": [
                        "model": "gemini-2.5-pro",
                        "inputTokens": 20,
                        "outputTokens": 5,
                    ],
                ],
                "malformed-middle-record",
                [
                    "role": "assistant",
                    "messageId": 2,
                    "usage": ["inputTokens": 999],
                ],
            ],
        ])

        let usage = try await fixture.reader.readUsage(
            from: fixture.date("2026-08-20T00:00:00Z"),
            to: fixture.date("2026-08-21T00:00:00Z"))

        XCTAssertEqual(usage.totalTokens, 25)
        XCTAssertEqual(usage.tokenEvents.count, 1)
    }

    func test_malformedOptionalThreadMetadataDoesNotDropValidUsage() async throws {
        let fixture = try AmpFixture()
        defer { fixture.remove() }
        try fixture.writeThread([
            "id": "T-lossy-metadata",
            "created": "not-a-timestamp",
            "environment": "not-an-object",
            "messages": [
                [
                    "role": "assistant",
                    "messageId": 1,
                    "createdAt": "2026-08-20T11:00:00Z",
                    "usage": [
                        "model": "gpt-5.4",
                        "inputTokens": 20,
                        "outputTokens": 5,
                    ],
                ],
            ],
        ])

        let usage = try await fixture.reader.readUsage(
            from: fixture.date("2026-08-20T00:00:00Z"),
            to: fixture.date("2026-08-21T00:00:00Z"))

        XCTAssertEqual(usage.totalTokens, 25)
        XCTAssertEqual(usage.tokenEvents.count, 1)
    }

    func test_dateRangeIsStartInclusiveAndEndExclusive() async throws {
        let fixture = try AmpFixture()
        defer { fixture.remove() }
        try fixture.writeThread([
            "id": "T-boundaries",
            "created": fixture.milliseconds("2026-08-20T00:00:00Z"),
            "usageLedger": [
                "events": [
                    [
                        "timestamp": "2026-08-20T00:00:00Z",
                        "model": "gpt-5.4",
                        "toMessageId": 1,
                        "tokens": ["input": 10],
                    ],
                    [
                        "timestamp": "2026-08-21T00:00:00Z",
                        "model": "gpt-5.4",
                        "toMessageId": 2,
                        "tokens": ["input": 100],
                    ],
                ],
            ],
        ])

        let usage = try await fixture.reader.readUsage(
            from: fixture.date("2026-08-20T00:00:00Z"),
            to: fixture.date("2026-08-21T00:00:00Z"))

        XCTAssertEqual(usage.inputTokens, 10)
        XCTAssertEqual(usage.tokenEvents.count, 1)
    }
}

extension AmpReaderTests {
    func test_replicatedThreadFilesReconcileLedgerAndMessageGlobally() async throws {
        let fixture = try AmpFixture()
        defer { fixture.remove() }
        try fixture.writeThread([
            "id": "T-replicated",
            "created": fixture.milliseconds("2026-08-20T10:00:00Z"),
            "usageLedger": [
                "events": [
                    [
                        "timestamp": "2026-08-20T11:00:00Z",
                        "model": "gpt-5.4",
                        "credits": 0.25,
                        "toMessageId": 3,
                        "tokens": ["input": 50],
                    ],
                ],
            ],
        ], named: "a-ledger.json")
        try fixture.writeThread([
            "id": "T-replicated",
            "created": fixture.milliseconds("2026-08-20T10:00:00Z"),
            "messages": [
                [
                    "role": "assistant",
                    "messageId": 3,
                    "createdAt": "2026-08-20T11:00:00Z",
                    "usage": [
                        "model": "gpt-5.4",
                        "inputTokens": 50,
                        "outputTokens": 10,
                        "cacheReadInputTokens": 5,
                        "cacheCreationInputTokens": 2,
                    ],
                ],
            ],
        ], named: "b-message.json")

        let usage = try await fixture.reader.readUsage(
            from: fixture.date("2026-08-20T00:00:00Z"),
            to: fixture.date("2026-08-21T00:00:00Z"))

        XCTAssertEqual(usage.inputTokens, 50)
        XCTAssertEqual(usage.outputTokens, 10)
        XCTAssertEqual(usage.cacheReadTokens, 5)
        XCTAssertEqual(usage.cacheWriteTokens, 2)
        XCTAssertEqual(usage.totalTokens, 67)
        XCTAssertEqual(usage.cost, 0.25, accuracy: 0.000_001)
        XCTAssertEqual(usage.tokenEvents.count, 1)
    }

    func test_differentExplicitMessageIDsDoNotMergeOnMatchingTokens() async throws {
        let fixture = try AmpFixture()
        defer { fixture.remove() }
        try fixture.writeThread([
            "id": "T-distinct-ids",
            "created": fixture.milliseconds("2026-08-20T10:00:00Z"),
            "usageLedger": [
                "events": [
                    [
                        "timestamp": "2026-08-21T00:00:00Z",
                        "model": "claude-sonnet-4-6",
                        "toMessageId": 1,
                        "tokens": ["input": 50, "output": 10],
                    ],
                ],
            ],
            "messages": [
                [
                    "role": "assistant",
                    "messageId": 2,
                    "createdAt": "2026-08-20T11:00:00Z",
                    "usage": [
                        "model": "claude-sonnet-4-6",
                        "inputTokens": 50,
                        "outputTokens": 10,
                    ],
                ],
            ],
        ])

        let usage = try await fixture.reader.readUsage(
            from: fixture.date("2026-08-20T00:00:00Z"),
            to: fixture.date("2026-08-21T00:00:00Z"))

        XCTAssertEqual(usage.totalTokens, 60)
        XCTAssertEqual(usage.tokenEvents.count, 1)
        XCTAssertEqual(
            usage.tokenEvents.first?.timestamp,
            fixture.date("2026-08-20T11:00:00Z"))
    }

    func test_partialLedgerTokensAreCompletedFromMatchingMessage() async throws {
        let fixture = try AmpFixture()
        defer { fixture.remove() }
        try fixture.writeThread([
            "id": "T-partial-ledger",
            "created": fixture.milliseconds("2026-08-20T10:00:00Z"),
            "usageLedger": [
                "events": [
                    [
                        "timestamp": "2026-08-20T11:00:00Z",
                        "model": "gpt-5.4",
                        "credits": 0.25,
                        "toMessageId": 3,
                        "tokens": ["input": 50],
                    ],
                ],
            ],
            "messages": [
                [
                    "role": "assistant",
                    "messageId": 3,
                    "createdAt": "2026-08-20T11:00:00Z",
                    "usage": [
                        "model": "gpt-5.4",
                        "inputTokens": 50,
                        "outputTokens": 10,
                        "cacheReadInputTokens": 5,
                        "cacheCreationInputTokens": 2,
                    ],
                ],
            ],
        ])

        let usage = try await fixture.reader.readUsage(
            from: fixture.date("2026-08-20T00:00:00Z"),
            to: fixture.date("2026-08-21T00:00:00Z"))

        XCTAssertEqual(usage.inputTokens, 50)
        XCTAssertEqual(usage.outputTokens, 10)
        XCTAssertEqual(usage.cacheReadTokens, 5)
        XCTAssertEqual(usage.cacheWriteTokens, 2)
        XCTAssertEqual(usage.totalTokens, 67)
        XCTAssertEqual(usage.cost, 0.25, accuracy: 0.000_001)
        XCTAssertEqual(usage.tokenEvents.count, 1)
    }

    func test_readerPathsUseXDGDefaultAndIgnoreInvalidXDGValues() {
        let home = URL(fileURLWithPath: "/tmp/toki-amp-home")

        XCTAssertEqual(
            LocalUsageReaderPaths(homeDirectory: home, environment: [:]).ampThreads.path,
            "/tmp/toki-amp-home/.local/share/amp/threads")
        XCTAssertEqual(
            LocalUsageReaderPaths(
                homeDirectory: home,
                environment: ["XDG_DATA_HOME": "/tmp/toki-amp-xdg"]).ampThreads.path,
            "/tmp/toki-amp-xdg/amp/threads")
        XCTAssertEqual(
            LocalUsageReaderPaths(
                homeDirectory: home,
                environment: ["XDG_DATA_HOME": "relative"]).ampThreads.path,
            "/tmp/toki-amp-home/.local/share/amp/threads")
        XCTAssertEqual(
            LocalUsageReaderPaths(
                homeDirectory: home,
                environment: ["XDG_DATA_HOME": ""]).ampThreads.path,
            "/tmp/toki-amp-home/.local/share/amp/threads")
    }
}

struct AmpFixture {
    let root: URL
    let threadURL: URL

    init() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("toki-amp-tests-\(UUID().uuidString)", isDirectory: true)
        threadURL = root.appendingPathComponent("T-fixture.json")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    var reader: AmpReader {
        AmpReader(threadsURLOverride: root)
    }

    func writeThread(_ object: [String: Any]) throws {
        try writeThread(object, named: threadURL.lastPathComponent)
    }

    func writeThread(_ object: [String: Any], named fileName: String) throws {
        let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        try data.write(to: root.appendingPathComponent(fileName))
    }

    func milliseconds(_ value: String) -> Int64 {
        Int64(date(value).timeIntervalSince1970 * 1000)
    }

    func date(_ value: String) -> Date {
        ISO8601DateFormatter().date(from: value)!
    }

    func remove() {
        try? FileManager.default.removeItem(at: root)
    }
}
