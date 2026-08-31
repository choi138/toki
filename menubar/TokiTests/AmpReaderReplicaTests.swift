import Foundation
import XCTest
@testable import TokiUsageReaders

final class AmpReaderReplicaTests: XCTestCase {
    func test_identicalIdlessRecordsInOneFileRemainDistinct() async throws {
        let fixture = try AmpFixture()
        defer { fixture.remove() }
        let record = [
            "timestamp": "2026-08-20T11:00:00Z",
            "model": "gpt-5.4",
            "tokens": ["input": 10],
        ] as [String: Any]
        try fixture.writeThread([
            "id": "T-identical-turns",
            "usageLedger": ["events": [record, record]],
        ], named: "thread.json")

        let usage = try await fixture.reader.readUsage(
            from: fixture.date("2026-08-20T00:00:00Z"),
            to: fixture.date("2026-08-21T00:00:00Z"))

        XCTAssertEqual(usage.totalTokens, 20)
        XCTAssertEqual(usage.tokenEvents.count, 2)
    }

    func test_idlessIndependentRecordsAtSameTimestampRemainDistinct() async throws {
        let fixture = try AmpFixture()
        defer { fixture.remove() }
        try fixture.writeThread([
            "id": "T-independent",
            "usageLedger": [
                "events": [
                    [
                        "timestamp": "2026-08-20T11:00:00Z",
                        "model": "gpt-5.4",
                        "tokens": ["input": 10],
                    ],
                    [
                        "timestamp": "2026-08-20T11:00:00Z",
                        "model": "gpt-5.4",
                        "tokens": ["input": 20],
                    ],
                ],
            ],
        ], named: "thread.json")

        let usage = try await fixture.reader.readUsage(
            from: fixture.date("2026-08-20T00:00:00Z"),
            to: fixture.date("2026-08-21T00:00:00Z"))

        XCTAssertEqual(usage.totalTokens, 30)
        XCTAssertEqual(usage.tokenEvents.count, 2)
    }

    func test_sameKindReplicaMergesWhenOnlyOneRecordHasMessageID() async throws {
        let fixture = try AmpFixture()
        defer { fixture.remove() }
        try fixture.writeThread([
            "id": "T-one-id",
            "usageLedger": [
                "events": [
                    [
                        "timestamp": "2026-08-20T11:00:00Z",
                        "model": "gpt-5.4",
                        "toMessageId": 7,
                        "tokens": ["input": 50],
                    ],
                ],
            ],
        ], named: "a-with-id.json")
        try fixture.writeThread([
            "id": "T-one-id",
            "usageLedger": [
                "events": [
                    [
                        "timestamp": "2026-08-20T11:00:00Z",
                        "model": "gpt-5.4",
                        "credits": 0.25,
                        "tokens": ["input": 50, "output": 10],
                    ],
                ],
            ],
        ], named: "b-without-id.json")

        let usage = try await fixture.reader.readUsage(
            from: fixture.date("2026-08-20T00:00:00Z"),
            to: fixture.date("2026-08-21T00:00:00Z"))

        XCTAssertEqual(usage.totalTokens, 60)
        XCTAssertEqual(usage.cost, 0.25, accuracy: 0.000_001)
        XCTAssertEqual(usage.tokenEvents.count, 1)
    }

    func test_idlessReplicaRecordsMergeMissingTokensAndCost() async throws {
        let fixture = try AmpFixture()
        defer { fixture.remove() }
        try fixture.writeThread([
            "id": "T-idless",
            "usageLedger": [
                "events": [
                    [
                        "timestamp": "2026-08-20T11:00:00Z",
                        "model": "gpt-5.4",
                        "credits": 0.25,
                        "tokens": ["input": 50],
                    ],
                ],
            ],
        ], named: "a-ledger.json")
        try fixture.writeThread([
            "id": "T-idless",
            "usageLedger": [
                "events": [
                    [
                        "timestamp": "2026-08-20T11:00:00Z",
                        "model": "gpt-5.4",
                        "credits": 0.25,
                        "tokens": [
                            "input": 50,
                            "output": 10,
                            "cacheReadInputTokens": 5,
                            "cacheCreationInputTokens": 2,
                        ],
                    ],
                ],
            ],
        ], named: "b-complete-ledger.json")

        let usage = try await fixture.reader.readUsage(
            from: fixture.date("2026-08-20T00:00:00Z"),
            to: fixture.date("2026-08-21T00:00:00Z"))

        XCTAssertEqual(usage.totalTokens, 67)
        XCTAssertEqual(usage.cost, 0.25, accuracy: 0.000_001)
        XCTAssertEqual(usage.tokenEvents.count, 1)
    }
}

extension AmpReaderReplicaTests {
    func test_matchingMessageIDCoalescesAcrossTimestampSkew() async throws {
        let fixture = try AmpFixture()
        defer { fixture.remove() }
        try fixture.writeThread([
            "id": "T-skewed-id",
            "usageLedger": ["events": [[
                "timestamp": "2026-08-20T11:05:00Z",
                "model": "gpt-5.4",
                "toMessageId": 42,
                "tokens": ["input": 20, "output": 5],
            ]]],
            "messages": [[
                "role": "assistant",
                "messageId": 42,
                "createdAt": "2026-08-20T11:00:00Z",
                "usage": [
                    "model": "gpt-5.4",
                    "timestamp": "2026-08-20T11:00:00Z",
                    "inputTokens": 20,
                    "outputTokens": 5,
                ],
            ]],
        ])

        let usage = try await fixture.reader.readUsage(
            from: fixture.date("2026-08-20T00:00:00Z"),
            to: fixture.date("2026-08-21T00:00:00Z"))

        XCTAssertEqual(usage.totalTokens, 25)
        XCTAssertEqual(usage.tokenEvents.count, 1)
    }

    func test_malformedLedgerCounterKeepsOtherValidTokens() async throws {
        let fixture = try AmpFixture()
        defer { fixture.remove() }
        try fixture.writeThread([
            "id": "T-lossy-ledger-tokens",
            "usageLedger": ["events": [[
                "timestamp": "2026-08-20T11:00:00Z",
                "model": "gpt-5.4",
                "tokens": [
                    "input": 20,
                    "output": "not-a-counter",
                    "cacheReadInputTokens": 5,
                ],
            ]]],
        ])

        let usage = try await fixture.reader.readUsage(
            from: fixture.date("2026-08-20T00:00:00Z"),
            to: fixture.date("2026-08-21T00:00:00Z"))

        XCTAssertEqual(usage.inputTokens, 20)
        XCTAssertEqual(usage.outputTokens, 0)
        XCTAssertEqual(usage.cacheReadTokens, 5)
        XCTAssertEqual(usage.tokenEvents.count, 1)
    }

    func test_malformedMessageAndLedgerMetadataKeepValidUsage() async throws {
        let fixture = try AmpFixture()
        defer { fixture.remove() }
        try fixture.writeThread([
            "id": "T-lossy-parent-metadata",
            "created": fixture.milliseconds("2026-08-20T10:00:00Z"),
            "usageLedger": ["events": [[
                "timestamp": "2026-08-20T12:00:00Z",
                "model": "gpt-5.4",
                "credits": "not-a-number",
                "fromMessageId": "not-an-id",
                "toMessageId": ["unexpected": true],
                "tokens": ["input": 30, "output": 6],
            ]]],
            "messages": [[
                "role": "assistant",
                "messageId": "not-an-id",
                "createdAt": 42,
                "usage": [
                    "model": "gpt-5.4",
                    "timestamp": "2026-08-20T11:00:00Z",
                    "inputTokens": 20,
                    "outputTokens": 5,
                ],
            ]],
        ])

        let usage = try await fixture.reader.readUsage(
            from: fixture.date("2026-08-20T00:00:00Z"),
            to: fixture.date("2026-08-21T00:00:00Z"))

        XCTAssertEqual(usage.totalTokens, 61)
        XCTAssertEqual(usage.tokenEvents.count, 2)
    }

    func test_modelLessMessageCoalescesWithKnownModelLedgerReplica() async throws {
        let fixture = try AmpFixture()
        defer { fixture.remove() }
        try fixture.writeThread([
            "id": "T-model-less-replica",
            "created": fixture.milliseconds("2026-08-20T10:00:00Z"),
            "usageLedger": ["events": [[
                "timestamp": "2026-08-20T11:00:00Z",
                "model": "gpt-5.4",
                "tokens": ["input": 20, "output": 5],
            ]]],
            "messages": [[
                "role": "assistant",
                "createdAt": "2026-08-20T11:00:00Z",
                "usage": ["inputTokens": 20, "outputTokens": 5],
            ]],
        ])

        let usage = try await fixture.reader.readUsage(
            from: fixture.date("2026-08-20T00:00:00Z"),
            to: fixture.date("2026-08-21T00:00:00Z"))

        XCTAssertEqual(usage.totalTokens, 25)
        XCTAssertEqual(usage.tokenEvents.count, 1)
        XCTAssertEqual(usage.tokenEvents.first?.model, "gpt-5.4")
    }

    func test_idlessPartialReplicaDoesNotShiftLogicalIdentity() async throws {
        let fixture = try AmpFixture()
        defer { fixture.remove() }
        let first = [
            "timestamp": "2026-08-20T11:00:00Z",
            "model": "gpt-5.4",
            "tokens": ["input": 10],
        ] as [String: Any]
        let second = [
            "timestamp": "2026-08-20T11:01:00Z",
            "model": "gpt-5.4",
            "tokens": ["input": 20],
        ] as [String: Any]
        try fixture.writeThread([
            "id": "T-partial-replica",
            "usageLedger": ["events": [first, second]],
        ], named: "a-complete.json")
        try fixture.writeThread([
            "id": "T-partial-replica",
            "usageLedger": ["events": [second]],
        ], named: "b-partial.json")

        let usage = try await fixture.reader.readUsage(
            from: fixture.date("2026-08-20T00:00:00Z"),
            to: fixture.date("2026-08-21T00:00:00Z"))

        XCTAssertEqual(usage.totalTokens, 30)
        XCTAssertEqual(usage.tokenEvents.count, 2)
    }

    func test_sameTimestampPartialReplicaMatchesCompatibleRecord() async throws {
        let fixture = try AmpFixture()
        defer { fixture.remove() }
        let first = [
            "timestamp": "2026-08-20T11:00:00Z",
            "model": "gpt-5.4",
            "tokens": ["input": 10],
        ] as [String: Any]
        let second = [
            "timestamp": "2026-08-20T11:00:00Z",
            "model": "gpt-5.4",
            "tokens": ["input": 20],
        ] as [String: Any]
        try fixture.writeThread([
            "id": "T-same-time-partial",
            "usageLedger": ["events": [first, second]],
        ], named: "a-complete.json")
        try fixture.writeThread([
            "id": "T-same-time-partial",
            "usageLedger": ["events": [second]],
        ], named: "b-partial.json")

        let usage = try await fixture.reader.readUsage(
            from: fixture.date("2026-08-20T00:00:00Z"),
            to: fixture.date("2026-08-21T00:00:00Z"))

        XCTAssertEqual(usage.totalTokens, 30)
        XCTAssertEqual(usage.tokenEvents.count, 2)
    }

    func test_idlessExplicitTimestampRecordsWithConflictingTokensRemainDistinct() async throws {
        let fixture = try AmpFixture()
        defer { fixture.remove() }
        try fixture.writeThread([
            "id": "T-idless-conflict",
            "usageLedger": [
                "events": [[
                    "timestamp": "2026-08-20T11:00:00Z",
                    "model": "gpt-5.4",
                    "tokens": ["input": 10],
                ]],
            ],
        ], named: "a-first.json")
        try fixture.writeThread([
            "id": "T-idless-conflict",
            "usageLedger": [
                "events": [[
                    "timestamp": "2026-08-20T11:00:00Z",
                    "model": "gpt-5.4",
                    "tokens": ["input": 20],
                ]],
            ],
        ], named: "b-second.json")

        let usage = try await fixture.reader.readUsage(
            from: fixture.date("2026-08-20T00:00:00Z"),
            to: fixture.date("2026-08-21T00:00:00Z"))

        XCTAssertEqual(usage.totalTokens, 30)
        XCTAssertEqual(usage.tokenEvents.count, 2)
    }

    func test_unmatchedModelLessLedgerUsageIsPreserved() async throws {
        let fixture = try AmpFixture()
        defer { fixture.remove() }
        try fixture.writeThread([
            "id": "T-model-less",
            "usageLedger": [
                "events": [[
                    "timestamp": "2026-08-20T11:00:00Z",
                    "tokens": ["input": 12, "output": 3],
                ]],
            ],
        ])

        let usage = try await fixture.reader.readUsage(
            from: fixture.date("2026-08-20T00:00:00Z"),
            to: fixture.date("2026-08-21T00:00:00Z"))

        XCTAssertEqual(usage.totalTokens, 15)
        XCTAssertEqual(usage.tokenEvents.count, 1)
        XCTAssertNil(usage.tokenEvents.first?.model)
    }

    func test_workspaceRootWinsAcrossReplicasRegardlessOfFileOrder() async throws {
        let fixture = try AmpFixture()
        defer { fixture.remove() }
        try fixture.writeThread([
            "id": "T-project",
            "environment": ["workingDirectory": "/tmp/Amp/core"],
            "messages": [
                [
                    "role": "assistant",
                    "messageId": 1,
                    "createdAt": "2026-08-20T11:00:00Z",
                    "usage": [
                        "model": "gpt-5.4",
                        "inputTokens": 10,
                    ],
                ],
            ],
        ], named: "a-working-directory.json")
        try fixture.writeThread([
            "id": "T-project",
            "environment": ["workspaceRoot": "/tmp/Amp"],
        ], named: "b-workspace-root.json")

        let usage = try await fixture.reader.readUsage(
            from: fixture.date("2026-08-20T00:00:00Z"),
            to: fixture.date("2026-08-21T00:00:00Z"))

        XCTAssertEqual(usage.tokenEvents.first?.attribution?.projectPath, "/tmp/Amp")
        XCTAssertEqual(usage.tokenEvents.first?.attribution?.projectName, "Amp")
    }

    func test_sameExplicitMessageIDWithConflictingTokensDoesNotMerge() async throws {
        let fixture = try AmpFixture()
        defer { fixture.remove() }
        try fixture.writeThread([
            "id": "T-conflict",
            "usageLedger": [
                "events": [
                    [
                        "timestamp": "2026-08-20T11:00:00Z",
                        "model": "gpt-5.4",
                        "toMessageId": 7,
                        "tokens": ["input": 50],
                    ],
                ],
            ],
            "messages": [
                [
                    "role": "assistant",
                    "messageId": 7,
                    "createdAt": "2026-08-20T11:00:00Z",
                    "usage": [
                        "model": "gpt-5.4",
                        "inputTokens": 60,
                    ],
                ],
            ],
        ])

        let usage = try await fixture.reader.readUsage(
            from: fixture.date("2026-08-20T00:00:00Z"),
            to: fixture.date("2026-08-21T00:00:00Z"))

        XCTAssertEqual(usage.totalTokens, 110)
        XCTAssertEqual(usage.tokenEvents.count, 2)
    }

    func test_modelLessLedgerCompletesFromMatchingMessageBeforeValidation() async throws {
        let fixture = try AmpFixture()
        defer { fixture.remove() }
        try fixture.writeThread([
            "id": "T-model-fill",
            "usageLedger": [
                "events": [
                    [
                        "timestamp": "2026-08-20T11:00:00Z",
                        "toMessageId": 9,
                        "credits": 0.25,
                        "tokens": ["input": 50],
                    ],
                ],
            ],
            "messages": [
                [
                    "role": "assistant",
                    "messageId": 9,
                    "createdAt": "2026-08-20T11:00:00Z",
                    "usage": [
                        "model": "gpt-5.4",
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
        XCTAssertEqual(usage.cost, 0.25, accuracy: 0.000_001)
        XCTAssertEqual(usage.tokenEvents.count, 1)
        XCTAssertEqual(usage.tokenEvents.first?.model, "gpt-5.4")
    }
}
