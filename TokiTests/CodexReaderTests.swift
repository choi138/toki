import XCTest
@testable import Toki

// swiftlint:disable:next type_body_length
final class CodexReaderTests: XCTestCase {
    func test_codexReader_usesBaselineBeforeRangeAndDeduplicatesSnapshots() {
        let lines = [
            tokenCountLine(
                ts: "2026-04-09T14:59:00Z",
                input: 100,
                cachedInput: 20,
                output: 40,
                reasoning: 10,
                total: 140),
            tokenCountLine(
                ts: "2026-04-10T00:01:00Z",
                input: 140,
                cachedInput: 30,
                output: 55,
                reasoning: 15,
                total: 195),
            tokenCountLine(
                ts: "2026-04-10T00:02:00Z",
                input: 140,
                cachedInput: 30,
                output: 55,
                reasoning: 15,
                total: 195),
            tokenCountLine(
                ts: "2026-04-10T00:03:00Z",
                input: 200,
                cachedInput: 50,
                output: 80,
                reasoning: 20,
                total: 280),
        ]

        let usage = CodexReader.usage(
            fromRolloutLines: lines,
            model: "gpt-5.4",
            from: isoDate("2026-04-10T00:00:00Z"),
            to: isoDate("2026-04-11T00:00:00Z"),
            streamID: "rollout-a")

        XCTAssertEqual(usage.inputTokens, 70)
        XCTAssertEqual(usage.cacheReadTokens, 30)
        XCTAssertEqual(usage.outputTokens, 30)
        XCTAssertEqual(usage.reasoningTokens, 10)
        XCTAssertEqual(usage.totalTokens, 140)
        XCTAssertEqual(usage.tokenEvents.map(\.totalTokens), [55, 85])
        XCTAssertEqual(usage.tokenEvents.first?.timestamp, isoDate("2026-04-10T00:01:00Z"))
        XCTAssertEqual(usage.perModel["gpt-5.4"]?.totalTokens, 140)
        let expectedCost = modelPrice(for: "gpt-5.4")?.cost(
            input: usage.inputTokens,
            output: usage.outputTokens + usage.reasoningTokens,
            cacheRead: usage.cacheReadTokens,
            cacheWrite: 0)
        XCTAssertEqual(usage.cost, expectedCost ?? 0, accuracy: 0.000001)
    }

    func test_codexReader_countsInitialSnapshotWhenSessionStartsInsideRange() {
        let lines = [
            tokenCountLine(
                ts: "2026-04-10T09:00:00Z",
                input: 120,
                cachedInput: 20,
                output: 30,
                reasoning: 5,
                total: 150),
        ]

        let usage = CodexReader.usage(
            fromRolloutLines: lines,
            model: "gpt-5.4-mini",
            from: isoDate("2026-04-10T00:00:00Z"),
            to: isoDate("2026-04-11T00:00:00Z"),
            streamID: "rollout-a")

        XCTAssertEqual(usage.inputTokens, 100)
        XCTAssertEqual(usage.cacheReadTokens, 20)
        XCTAssertEqual(usage.outputTokens, 25)
        XCTAssertEqual(usage.reasoningTokens, 5)
        XCTAssertEqual(usage.totalTokens, 150)
        XCTAssertEqual(usage.perModel["gpt-5.4-mini"]?.totalTokens, 150)
        let expectedCost = modelPrice(for: "gpt-5.4-mini")?.cost(
            input: usage.inputTokens,
            output: usage.outputTokens + usage.reasoningTokens,
            cacheRead: usage.cacheReadTokens,
            cacheWrite: 0)
        XCTAssertEqual(usage.cost, expectedCost ?? 0, accuracy: 0.000001)
    }

    func test_codexReader_doesNotRepeatLastUsageWhenTotalSnapshotIsUnchanged() {
        let repeatedLast = TokenCountLineUsage(
            input: 120,
            cachedInput: 20,
            output: 30,
            reasoning: 5)
        let lines = [
            tokenCountLine(
                ts: "2026-04-10T09:00:00Z",
                input: 120,
                cachedInput: 20,
                output: 30,
                reasoning: 5,
                total: 150,
                lastUsage: repeatedLast),
            tokenCountLine(
                ts: "2026-04-10T09:01:00Z",
                input: 120,
                cachedInput: 20,
                output: 30,
                reasoning: 5,
                total: 150,
                lastUsage: repeatedLast),
            tokenCountLine(
                ts: "2026-04-10T09:02:00Z",
                input: 120,
                cachedInput: 20,
                output: 30,
                reasoning: 5,
                total: 150,
                lastUsage: TokenCountLineUsage(input: 10, cachedInput: 2, output: 3, reasoning: 1)),
        ]

        let usage = CodexReader.usage(
            fromRolloutLines: lines,
            model: "gpt-5.4-mini",
            from: isoDate("2026-04-10T00:00:00Z"),
            to: isoDate("2026-04-11T00:00:00Z"),
            streamID: "rollout-a")

        XCTAssertEqual(usage.totalTokens, 150)
        XCTAssertEqual(usage.tokenEvents.map(\.totalTokens), [150])
    }

    func test_codexReader_usesCumulativeDifferenceWhenTotalAdvances() {
        let lines = [
            tokenCountLine(
                ts: "2026-04-10T09:00:00Z",
                input: 100,
                cachedInput: 20,
                output: 30,
                reasoning: 5,
                total: 130,
                lastUsage: TokenCountLineUsage(input: 100, cachedInput: 20, output: 30, reasoning: 5)),
            tokenCountLine(
                ts: "2026-04-10T09:01:00Z",
                input: 140,
                cachedInput: 30,
                output: 42,
                reasoning: 8,
                total: 182,
                lastUsage: TokenCountLineUsage(input: 999, cachedInput: 0, output: 999, reasoning: 0)),
        ]

        let usage = CodexReader.usage(
            fromRolloutLines: lines,
            model: "gpt-5.4-mini",
            from: isoDate("2026-04-10T00:00:00Z"),
            to: isoDate("2026-04-11T00:00:00Z"),
            streamID: "rollout-a")

        XCTAssertEqual(usage.tokenEvents.map(\.totalTokens), [130, 52])
        XCTAssertEqual(usage.totalTokens, 182)
        XCTAssertEqual(usage.outputTokens, 34)
        XCTAssertEqual(usage.reasoningTokens, 8)
    }

    func test_codexReader_suppressesStaleTotalRegression() {
        let lines = [
            tokenCountLine(
                ts: "2026-04-10T09:00:00Z",
                input: 1000,
                cachedInput: 800,
                output: 100,
                reasoning: 40,
                total: 1100,
                lastUsage: TokenCountLineUsage(
                    input: 100,
                    cachedInput: 80,
                    output: 10,
                    reasoning: 4)),
            tokenCountLine(
                ts: "2026-04-10T09:01:00Z",
                input: 900,
                cachedInput: 850,
                output: 90,
                reasoning: 30,
                total: 990,
                lastUsage: TokenCountLineUsage(
                    input: 50,
                    cachedInput: 40,
                    output: 8,
                    reasoning: 2)),
        ]

        let usage = CodexReader.usage(
            fromRolloutLines: lines,
            model: "gpt-5.4-mini",
            from: isoDate("2026-04-10T00:00:00Z"),
            to: isoDate("2026-04-11T00:00:00Z"),
            streamID: "rollout-a")
        let summary = codexRolloutDailySummary(
            fromSnapshots: codexRolloutSnapshots(fromRolloutLines: lines))

        XCTAssertEqual(usage.inputTokens, 20)
        XCTAssertEqual(usage.cacheReadTokens, 80)
        XCTAssertEqual(usage.outputTokens, 6)
        XCTAssertEqual(usage.reasoningTokens, 4)
        XCTAssertEqual(usage.totalTokens, 110)
        XCTAssertEqual(usage.tokenEvents.map(\.totalTokens), [110])
        XCTAssertEqual(summary.dailyUsage["2026-04-10"]?.totalTokens, 110)
        XCTAssertEqual(summary.dailyTokenUsageEvents["2026-04-10"]?.map(\.totalTokens), [110])
    }

    func test_codexReader_rebaselinesAfterRealCounterReset() {
        let lines = [
            tokenCountLine(
                ts: "2026-04-10T09:00:00Z",
                input: 10_000,
                cachedInput: 1_000,
                output: 400,
                reasoning: 50,
                total: 10_400,
                lastUsage: TokenCountLineUsage(input: 10_000, cachedInput: 1_000, output: 400, reasoning: 50)),
            tokenCountLine(
                ts: "2026-04-10T09:01:00Z",
                input: 7_600,
                cachedInput: 800,
                output: 280,
                reasoning: 35,
                total: 7_880,
                lastUsage: TokenCountLineUsage(input: 25, cachedInput: 5, output: 4, reasoning: 1)),
            tokenCountLine(
                ts: "2026-04-10T09:02:00Z",
                input: 7_625,
                cachedInput: 805,
                output: 284,
                reasoning: 36,
                total: 7_909,
                lastUsage: TokenCountLineUsage(input: 999, cachedInput: 0, output: 999, reasoning: 0)),
        ]

        let usage = CodexReader.usage(
            fromRolloutLines: lines,
            model: "gpt-5.4-mini",
            from: isoDate("2026-04-10T00:00:00Z"),
            to: isoDate("2026-04-11T00:00:00Z"),
            streamID: "rollout-a")

        XCTAssertEqual(usage.tokenEvents.map(\.totalTokens), [10_400, 29, 29])
    }

    func test_codexReader_preservesBaselineAcrossZeroSnapshot() {
        let lines = [
            tokenCountLine(
                ts: "2026-04-10T09:00:00Z",
                input: 500,
                cachedInput: 50,
                output: 80,
                reasoning: 10,
                total: 580),
            tokenCountLine(
                ts: "2026-04-10T09:01:00Z",
                input: 0,
                cachedInput: 0,
                output: 0,
                reasoning: 0,
                total: 0,
                lastUsage: TokenCountLineUsage(input: 0, cachedInput: 0, output: 0, reasoning: 0)),
            tokenCountLine(
                ts: "2026-04-10T09:02:00Z",
                input: 510,
                cachedInput: 52,
                output: 83,
                reasoning: 11,
                total: 593,
                lastUsage: TokenCountLineUsage(input: 10, cachedInput: 2, output: 3, reasoning: 1)),
        ]

        let usage = CodexReader.usage(
            fromRolloutLines: lines,
            model: "gpt-5.4-mini",
            from: isoDate("2026-04-10T00:00:00Z"),
            to: isoDate("2026-04-11T00:00:00Z"),
            streamID: "rollout-a")

        XCTAssertEqual(usage.tokenEvents.map(\.totalTokens), [580, 13])
        XCTAssertEqual(usage.totalTokens, 593)
    }

    func test_codexReader_skipsForkedParentReplayBeforeAndAfterTurnContext() {
        let lines = [
            #"{"timestamp":"2026-04-10T08:59:58Z","type":"session_meta","payload":{"id":"child-session","source":{"subagent":{"thread_spawn":{"parent_thread_id":"parent-session"}}}}}"#,
            tokenCountLine(
                ts: "2026-04-10T08:59:59Z",
                input: 300,
                cachedInput: 100,
                output: 30,
                reasoning: 5,
                total: 330,
                lastUsage: TokenCountLineUsage(input: 300, cachedInput: 100, output: 30, reasoning: 5)),
            #"{"timestamp":"2026-04-10T09:00:00Z","type":"turn_context","payload":{"model":"gpt-5.4-mini"}}"#,
            tokenCountLine(
                ts: "2026-04-10T09:00:01Z",
                input: 300,
                cachedInput: 100,
                output: 30,
                reasoning: 5,
                total: 330,
                lastUsage: TokenCountLineUsage(input: 300, cachedInput: 100, output: 30, reasoning: 5)),
            tokenCountLine(
                ts: "2026-04-10T09:00:02Z",
                input: 310,
                cachedInput: 100,
                output: 32,
                reasoning: 5,
                total: 342,
                lastUsage: TokenCountLineUsage(input: 10, cachedInput: 0, output: 2, reasoning: 0)),
        ]

        let usage = CodexReader.usage(
            fromRolloutLines: lines,
            model: "gpt-5.4-mini",
            from: isoDate("2026-04-10T00:00:00Z"),
            to: isoDate("2026-04-11T00:00:00Z"),
            streamID: "child-rollout")

        XCTAssertEqual(usage.tokenEvents.map(\.totalTokens), [12])
        XCTAssertEqual(usage.totalTokens, 12)
    }

    func test_codexReader_skipsParentTurnContextsUntilForkChildTurnStarts() {
        let childID = "019b0000-0000-7000-8000-000000000001"
        let parentTurnID = "019a0000-0000-7000-8000-000000000001"
        let childTurnID = "019c0000-0000-7000-8000-000000000001"
        let lines = [
            #"{"timestamp":"2026-04-10T08:59:55Z","type":"session_meta","payload":{"id":"\#(childID)","forked_from_id":"parent-session"}}"#,
            #"{"timestamp":"2026-04-10T08:59:56Z","type":"session_meta","payload":{"id":"parent-session"}}"#,
            #"{"timestamp":"2026-04-10T08:59:57Z","type":"turn_context","payload":{"turn_id":"\#(parentTurnID)","model":"gpt-5.4-mini"}}"#,
            tokenCountLine(
                ts: "2026-04-10T08:59:58Z",
                input: 300,
                cachedInput: 100,
                output: 30,
                reasoning: 5,
                total: 330),
            #"{"timestamp":"2026-04-10T08:59:59Z","type":"event_msg","payload":{"type":"task_started","turn_id":"\#(childTurnID)"}}"#,
            #"{"timestamp":"2026-04-10T09:00:00Z","type":"turn_context","payload":{"turn_id":"\#(childTurnID)","model":"gpt-5.4-mini"}}"#,
            tokenCountLine(
                ts: "2026-04-10T09:00:01Z",
                input: 310,
                cachedInput: 100,
                output: 32,
                reasoning: 5,
                total: 342,
                lastUsage: TokenCountLineUsage(input: 10, cachedInput: 0, output: 2, reasoning: 0)),
        ]

        let usage = CodexReader.usage(
            fromRolloutLines: lines,
            model: "gpt-5.4-mini",
            from: isoDate("2026-04-10T00:00:00Z"),
            to: isoDate("2026-04-11T00:00:00Z"),
            streamID: "child-rollout")

        XCTAssertEqual(usage.tokenEvents.map(\.totalTokens), [12])
        XCTAssertEqual(usage.totalTokens, 12)
    }

    func test_codexReader_countsUserForkTurnAfterRepeatedActiveChildMetadata() {
        let lines = [
            #"{"timestamp":"2026-01-02T03:10:00.000Z","type":"session_meta","payload":{"id":"22222222-2222-7222-8222-222222222222","forked_from_id":"11111111-1111-7111-8111-111111111111","source":"vscode","thread_source":"user"}}"#,
            #"{"timestamp":"2026-01-02T03:10:00.001Z","type":"session_meta","payload":{"id":"11111111-1111-7111-8111-111111111111","source":"vscode","thread_source":"user"}}"#,
            #"{"timestamp":"2026-01-02T03:10:00.100Z","type":"turn_context","payload":{"turn_id":"11111111-3333-7333-8333-333333333333","model":"gpt-5.4-mini"}}"#,
            tokenCountLine(
                ts: "2026-01-02T03:10:00.200Z",
                input: 1_000,
                cachedInput: 400,
                output: 100,
                reasoning: 0,
                total: 1_100),
            #"{"timestamp":"2026-01-02T03:10:30.100Z","type":"turn_context","payload":{"turn_id":"22222222-4444-7444-8444-444444444444","model":"gpt-5.4-mini"}}"#,
            #"{"timestamp":"2026-01-02T03:10:30.200Z","type":"session_meta","payload":{"id":"22222222-2222-7222-8222-222222222222","forked_from_id":"11111111-1111-7111-8111-111111111111","source":"vscode","thread_source":"user"}}"#,
            tokenCountLine(
                ts: "2026-01-02T03:10:31.100Z",
                input: 1_250,
                cachedInput: 450,
                output: 120,
                reasoning: 0,
                total: 1_370,
                lastUsage: TokenCountLineUsage(input: 250, cachedInput: 50, output: 20, reasoning: 0)),
        ]

        let usage = CodexReader.usage(
            fromRolloutLines: lines,
            model: "gpt-5.4-mini",
            from: isoDate("2026-01-02T00:00:00Z"),
            to: isoDate("2026-01-03T00:00:00Z"),
            streamID: "user-fork")

        XCTAssertEqual(usage.tokenEvents.map(\.totalTokens), [270])
        XCTAssertEqual(usage.totalTokens, 270)
    }

    func test_codexReader_countsSameMillisecondUserForkTurnWithoutTaskStarted() {
        let childSessionID = "22222222-2222-7fff-8fff-ffffffffffff"
        let childTurnID = "22222222-2222-7000-8000-000000000001"
        let lines = [
            #"{"timestamp":"2026-01-02T03:10:00.000Z","type":"session_meta","payload":{"id":"\#(childSessionID)","forked_from_id":"11111111-1111-7111-8111-111111111111","source":"vscode","thread_source":"user"}}"#,
            #"{"timestamp":"2026-01-02T03:10:00.001Z","type":"session_meta","payload":{"id":"11111111-1111-7111-8111-111111111111","source":"vscode"}}"#,
            #"{"timestamp":"2026-01-02T03:10:00.100Z","type":"turn_context","payload":{"turn_id":"11111111-3333-7333-8333-333333333333","model":"gpt-5.4-mini"}}"#,
            tokenCountLine(
                ts: "2026-01-02T03:10:00.200Z",
                input: 1_000,
                cachedInput: 400,
                output: 100,
                reasoning: 0,
                total: 1_100),
            #"{"timestamp":"2026-01-02T03:10:30.100Z","type":"turn_context","payload":{"turn_id":"\#(childTurnID)","model":"gpt-5.4-mini"}}"#,
            tokenCountLine(
                ts: "2026-01-02T03:10:31.100Z",
                input: 1_250,
                cachedInput: 450,
                output: 120,
                reasoning: 0,
                total: 1_370,
                lastUsage: TokenCountLineUsage(input: 250, cachedInput: 50, output: 20, reasoning: 0)),
        ]

        let usage = CodexReader.usage(
            fromRolloutLines: lines,
            model: "gpt-5.4-mini",
            from: isoDate("2026-01-02T00:00:00Z"),
            to: isoDate("2026-01-03T00:00:00Z"),
            streamID: "same-ms-user-fork")

        XCTAssertEqual(usage.tokenEvents.map(\.totalTokens), [270])
        XCTAssertEqual(usage.totalTokens, 270)
    }

    func test_codexReader_acceptsMissingTurnIDAfterForkReplay() {
        let lines = [
            #"{"timestamp":"2026-05-05T21:52:10.000Z","type":"session_meta","payload":{"id":"019e5c03-1e99-7000-8000-000000000001","forked_from_id":"019e5b00-0000-7000-8000-000000000001"}}"#,
            #"{"timestamp":"2026-05-05T21:52:10.001Z","type":"session_meta","payload":{"id":"019e5b00-0000-7000-8000-000000000001"}}"#,
            tokenCountLine(
                ts: "2026-05-05T21:52:10.200Z",
                input: 300,
                cachedInput: 0,
                output: 30,
                reasoning: 0,
                total: 330),
            #"{"timestamp":"2026-05-05T21:52:20.100Z","type":"turn_context","payload":{"model":"gpt-5.4-mini"}}"#,
            tokenCountLine(
                ts: "2026-05-05T21:52:20.200Z",
                input: 320,
                cachedInput: 0,
                output: 32,
                reasoning: 0,
                total: 352,
                lastUsage: TokenCountLineUsage(input: 20, cachedInput: 0, output: 2, reasoning: 0)),
        ]

        let usage = CodexReader.usage(
            fromRolloutLines: lines,
            model: "gpt-5.4-mini",
            from: isoDate("2026-05-05T00:00:00Z"),
            to: isoDate("2026-05-06T00:00:00Z"),
            streamID: "missing-turn-id-fork")

        XCTAssertEqual(usage.tokenEvents.map(\.totalTokens), [22])
        XCTAssertEqual(usage.totalTokens, 22)
    }

    func test_codexReader_acceptsNonV7TurnIDAfterForkReplay() {
        let lines = [
            #"{"timestamp":"2026-05-05T21:52:10.000Z","type":"session_meta","payload":{"id":"019e5c03-1e99-7000-8000-000000000001","forked_from_id":"019e5b00-0000-7000-8000-000000000001"}}"#,
            #"{"timestamp":"2026-05-05T21:52:10.001Z","type":"session_meta","payload":{"id":"019e5b00-0000-7000-8000-000000000001"}}"#,
            tokenCountLine(
                ts: "2026-05-05T21:52:10.200Z",
                input: 300,
                cachedInput: 0,
                output: 30,
                reasoning: 0,
                total: 330),
            #"{"timestamp":"2026-05-05T21:52:20.100Z","type":"turn_context","payload":{"turn_id":"not-a-v7-turn","model":"gpt-5.4-mini"}}"#,
            tokenCountLine(
                ts: "2026-05-05T21:52:20.200Z",
                input: 320,
                cachedInput: 0,
                output: 32,
                reasoning: 0,
                total: 352,
                lastUsage: TokenCountLineUsage(input: 20, cachedInput: 0, output: 2, reasoning: 0)),
        ]

        let usage = CodexReader.usage(
            fromRolloutLines: lines,
            model: "gpt-5.4-mini",
            from: isoDate("2026-05-05T00:00:00Z"),
            to: isoDate("2026-05-06T00:00:00Z"),
            streamID: "non-v7-turn-id-fork")

        XCTAssertEqual(usage.tokenEvents.map(\.totalTokens), [22])
        XCTAssertEqual(usage.totalTokens, 22)
    }

    func test_codexReader_nestedForkMetadataRemainsReplayUntilChildTaskStarts() {
        let childID = "019e5c03-1e99-7000-8000-000000000001"
        let parentID = "019e5b00-0000-7000-8000-000000000001"
        let parentTurnID = "019e5b00-0001-7000-8000-000000000001"
        let childTurnID = "019e5c03-6425-7000-8000-000000000001"
        let lines = [
            #"{"timestamp":"2026-05-05T21:52:10.000Z","type":"session_meta","payload":{"id":"\#(childID)","forked_from_id":"\#(parentID)"}}"#,
            #"{"timestamp":"2026-05-05T21:52:10.001Z","type":"session_meta","payload":{"id":"\#(parentID)","forked_from_id":"019e5a00-0000-7000-8000-000000000001"}}"#,
            #"{"timestamp":"2026-05-05T21:52:10.100Z","type":"turn_context","payload":{"turn_id":"\#(parentTurnID)","model":"gpt-5.4-mini"}}"#,
            tokenCountLine(
                ts: "2026-05-05T21:52:10.200Z",
                input: 500,
                cachedInput: 0,
                output: 50,
                reasoning: 0,
                total: 550),
            #"{"timestamp":"2026-05-05T21:52:20.000Z","type":"event_msg","payload":{"type":"task_started","turn_id":"\#(childTurnID)"}}"#,
            #"{"timestamp":"2026-05-05T21:52:20.100Z","type":"turn_context","payload":{"turn_id":"\#(childTurnID)","model":"gpt-5.4-mini"}}"#,
            tokenCountLine(
                ts: "2026-05-05T21:52:20.200Z",
                input: 520,
                cachedInput: 0,
                output: 52,
                reasoning: 0,
                total: 572,
                lastUsage: TokenCountLineUsage(input: 20, cachedInput: 0, output: 2, reasoning: 0)),
        ]

        let usage = CodexReader.usage(
            fromRolloutLines: lines,
            model: "gpt-5.4-mini",
            from: isoDate("2026-05-05T00:00:00Z"),
            to: isoDate("2026-05-06T00:00:00Z"),
            streamID: "nested-fork-metadata")

        XCTAssertEqual(usage.tokenEvents.map(\.totalTokens), [22])
        XCTAssertEqual(usage.totalTokens, 22)
    }

    func test_codexReader_sameMillisecondSubagentReplayWaitsForTaskStartedTurn() {
        let childTimestampPrefix = "019e5c03-1e99"
        let lines = [
            #"{"timestamp":"2026-05-05T21:52:10.000Z","type":"session_meta","payload":{"id":"\#(childTimestampPrefix)-7000-8000-0000000000ff","forked_from_id":"019e5b00-0000-7000-8000-000000000001","source":{"subagent":{"thread_spawn":{"parent_thread_id":"019e5b00-0000-7000-8000-000000000001"}}}}}"#,
            #"{"timestamp":"2026-05-05T21:52:10.001Z","type":"session_meta","payload":{"id":"019e5b00-0000-7000-8000-000000000001"}}"#,
            #"{"timestamp":"2026-05-05T21:52:10.100Z","type":"turn_context","payload":{"turn_id":"\#(childTimestampPrefix)-7000-8000-000000000001","model":"gpt-5.4-mini"}}"#,
            tokenCountLine(
                ts: "2026-05-05T21:52:10.200Z",
                input: 500,
                cachedInput: 0,
                output: 50,
                reasoning: 0,
                total: 550),
            #"{"timestamp":"2026-05-05T21:52:20.000Z","type":"event_msg","payload":{"type":"task_started","turn_id":"\#(childTimestampPrefix)-7000-8000-000000000002"}}"#,
            #"{"timestamp":"2026-05-05T21:52:20.100Z","type":"turn_context","payload":{"turn_id":"\#(childTimestampPrefix)-7000-8000-000000000002","model":"gpt-5.4-mini"}}"#,
            tokenCountLine(
                ts: "2026-05-05T21:52:20.200Z",
                input: 520,
                cachedInput: 0,
                output: 52,
                reasoning: 0,
                total: 572,
                lastUsage: TokenCountLineUsage(input: 20, cachedInput: 0, output: 2, reasoning: 0)),
        ]

        let usage = CodexReader.usage(
            fromRolloutLines: lines,
            model: "gpt-5.4-mini",
            from: isoDate("2026-05-05T00:00:00Z"),
            to: isoDate("2026-05-06T00:00:00Z"),
            streamID: "same-ms-subagent-fork")

        XCTAssertEqual(usage.tokenEvents.map(\.totalTokens), [22])
        XCTAssertEqual(usage.totalTokens, 22)
    }

    func test_codexReader_usesReportedTotalToSuppressForkReplayAfterComponentRewrite() {
        let lines = [
            #"{"timestamp":"2026-04-10T08:59:58Z","type":"session_meta","payload":{"id":"child-session","forked_from_id":"parent-session"}}"#,
            tokenCountLine(
                ts: "2026-04-10T08:59:59Z",
                input: 100,
                cachedInput: 20,
                output: 10,
                reasoning: 2,
                total: 110),
            #"{"timestamp":"2026-04-10T09:00:00Z","type":"turn_context","payload":{"model":"gpt-5.4-mini"}}"#,
            tokenCountLine(
                ts: "2026-04-10T09:00:01Z",
                input: 95,
                cachedInput: 15,
                output: 20,
                reasoning: 2,
                total: 105,
                lastUsage: TokenCountLineUsage(input: 5, cachedInput: 0, output: 10, reasoning: 0)),
            tokenCountLine(
                ts: "2026-04-10T09:00:02Z",
                input: 110,
                cachedInput: 22,
                output: 12,
                reasoning: 3,
                total: 122,
                lastUsage: TokenCountLineUsage(input: 10, cachedInput: 2, output: 2, reasoning: 1)),
        ]

        let usage = CodexReader.usage(
            fromRolloutLines: lines,
            model: "gpt-5.4-mini",
            from: isoDate("2026-04-10T00:00:00Z"),
            to: isoDate("2026-04-11T00:00:00Z"),
            streamID: "child-rollout")

        XCTAssertEqual(usage.tokenEvents.map(\.totalTokens), [12])
        XCTAssertEqual(usage.totalTokens, 12)
    }

    func test_codexReader_deduplicatesSameSessionAcrossFilesButKeepsIndependentSessions() {
        let merged = CodexReader().mergedSessions(
            databaseSessions: [
                CodexSession(
                    rolloutPath: "/tmp/current/replayed.jsonl",
                    model: "gpt-5.4-mini",
                    upstreamSessionID: "shared-session"),
                CodexSession(
                    rolloutPath: "/tmp/archived/copied.jsonl",
                    model: "gpt-5.4-mini",
                    upstreamSessionID: "shared-session"),
                CodexSession(
                    rolloutPath: "/tmp/current/independent.jsonl",
                    model: "gpt-5.4-mini",
                    upstreamSessionID: "independent-session"),
            ],
            jsonlSessions: [])

        XCTAssertEqual(merged.count, 2)
        XCTAssertEqual(Set(merged.map(\.upstreamSessionID)), ["shared-session", "independent-session"])
    }

    func test_codexRolloutCacheInvalidatesPreDedupSchema() throws {
        let legacyJSON = #"{"schemaVersion":1,"fileSize":10,"modifiedAt":100,"timeZoneIdentifier":"UTC","dailyUsage":{},"dailyActivityTimestamps":{},"dailyTokenUsageEvents":{}}"#
        let entry = try JSONDecoder().decode(
            CodexRolloutUsageCacheEntry.self,
            from: Data(legacyJSON.utf8))

        XCTAssertEqual(CodexRolloutUsageCacheEntry.currentSchemaVersion, 2)
        XCTAssertFalse(entry.isCurrentSchema)
    }

    func test_codexReaderAttachesSessionAttributionToTokenEvents() {
        let usage = CodexReader.usage(
            fromRolloutLines: [
                tokenCountLine(
                    ts: "2026-04-10T09:00:00Z",
                    input: 120,
                    cachedInput: 20,
                    output: 30,
                    reasoning: 5,
                    total: 150),
            ],
            model: "gpt-5.4-mini",
            from: isoDate("2026-04-10T00:00:00Z"),
            to: isoDate("2026-04-11T00:00:00Z"),
            streamID: "/tmp/rollout-a.jsonl",
            attribution: UsageAttribution(
                projectPath: "/Users/example/Toki",
                sessionID: "rollout-a",
                quality: .exact))

        XCTAssertEqual(usage.tokenEvents.first?.attribution?.projectName, "Toki")
        XCTAssertEqual(usage.tokenEvents.first?.attribution?.sessionID, "rollout-a")
        XCTAssertEqual(usage.tokenEvents.first?.attribution?.quality, .exact)
    }

    func test_codexReader_respects_partialDayRange() {
        let lines = [
            tokenCountLine(
                ts: "2026-04-10T08:00:00Z",
                input: 120,
                cachedInput: 20,
                output: 30,
                reasoning: 5,
                total: 150),
            tokenCountLine(
                ts: "2026-04-10T15:00:00Z",
                input: 170,
                cachedInput: 30,
                output: 40,
                reasoning: 10,
                total: 220),
        ]

        let usage = CodexReader.usage(
            fromRolloutLines: lines,
            model: "gpt-5.4-mini",
            from: isoDate("2026-04-10T12:00:00Z"),
            to: isoDate("2026-04-10T23:00:00Z"),
            streamID: "rollout-a")

        XCTAssertEqual(usage.inputTokens, 40)
        XCTAssertEqual(usage.cacheReadTokens, 10)
        XCTAssertEqual(usage.outputTokens, 5)
        XCTAssertEqual(usage.reasoningTokens, 5)
        XCTAssertEqual(usage.totalTokens, 60)
    }

    func test_codexReader_respectsPartialDayRangeWithOutOfOrderSnapshots() {
        let lines = [
            tokenCountLine(
                ts: "2026-04-10T15:00:00Z",
                input: 170,
                cachedInput: 30,
                output: 40,
                reasoning: 10,
                total: 220),
            tokenCountLine(
                ts: "2026-04-10T10:00:00Z",
                input: 120,
                cachedInput: 20,
                output: 30,
                reasoning: 5,
                total: 150),
        ]

        let usage = CodexReader.usage(
            fromRolloutLines: lines,
            model: "gpt-5.4-mini",
            from: isoDate("2026-04-10T12:00:00Z"),
            to: isoDate("2026-04-10T23:00:00Z"),
            streamID: "rollout-a")

        XCTAssertEqual(usage.inputTokens, 40)
        XCTAssertEqual(usage.cacheReadTokens, 10)
        XCTAssertEqual(usage.outputTokens, 5)
        XCTAssertEqual(usage.reasoningTokens, 5)
        XCTAssertEqual(usage.totalTokens, 60)
    }

    func test_codexRolloutDailySummaryBuildsTotalsActivityAndTokenEventsInTimestampOrder() {
        let lines = [
            tokenCountLine(
                ts: "2026-04-10T13:00:00Z",
                input: 170,
                cachedInput: 30,
                output: 40,
                reasoning: 10,
                total: 220),
            tokenCountLine(
                ts: "2026-04-10T10:00:00Z",
                input: 120,
                cachedInput: 20,
                output: 30,
                reasoning: 5,
                total: 150),
        ]

        let summary = codexRolloutDailySummary(
            fromSnapshots: codexRolloutSnapshots(fromRolloutLines: lines))
        let daySummary = summary.dailyUsage["2026-04-10"]

        XCTAssertEqual(daySummary?.inputTokens, 140)
        XCTAssertEqual(daySummary?.cacheReadTokens, 30)
        XCTAssertEqual(daySummary?.outputTokens, 30)
        XCTAssertEqual(daySummary?.reasoningTokens, 10)
        XCTAssertEqual(daySummary?.totalTokens, 210)
        XCTAssertEqual(summary.dailyActivityTimestamps["2026-04-10"]?.count, 2)
        XCTAssertEqual(summary.dailyTokenUsageEvents["2026-04-10"]?.map(\.totalTokens), [150, 60])
    }

    func test_codexRolloutDailySummaryStreamsJsonlWithoutMaterializingLines() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let url = directory.appendingPathComponent("rollout.jsonl")
        let content = [
            tokenCountLine(
                ts: "2026-04-10T00:01:00Z",
                input: 100,
                cachedInput: 10,
                output: 20,
                reasoning: 5,
                total: 125),
            tokenCountLine(
                ts: "2026-04-10T00:02:00Z",
                input: 130,
                cachedInput: 20,
                output: 35,
                reasoning: 10,
                total: 165),
        ].joined(separator: "\n")
        try content.write(to: url, atomically: true, encoding: .utf8)

        let summary = codexRolloutDailySummary(fromRolloutAt: url)

        XCTAssertEqual(summary.dailyUsage["2026-04-10"]?.totalTokens, 165)
        XCTAssertEqual(summary.dailyTokenUsageEvents["2026-04-10"]?.map(\.totalTokens), [120, 45])
    }

    func test_codexReaderSkipsJsonlLookupWhenDatabaseHasCompleteAttribution() {
        let skippedPaths = CodexReader().pathsWithCompleteDatabaseAttribution(
            in: [
                CodexSession(
                    rolloutPath: "/tmp/main-with-model.jsonl",
                    model: "gpt-5.4",
                    projectPath: "/tmp/project-a",
                    projectAttributionQuality: .exact),
                CodexSession(
                    rolloutPath: "/tmp/subagent-with-model.jsonl",
                    model: "gpt-5.4",
                    agentKind: .subagent,
                    projectPath: "/tmp/project-b",
                    projectAttributionQuality: .exact),
                CodexSession(rolloutPath: "/tmp/subagent-without-model.jsonl", model: nil, agentKind: .subagent),
                CodexSession(
                    rolloutPath: "/tmp/model-without-source.jsonl",
                    model: "gpt-5.4",
                    hasSourceAttribution: false,
                    projectPath: "/tmp/project-c",
                    projectAttributionQuality: .exact),
            ])

        XCTAssertEqual(skippedPaths, ["/tmp/main-with-model.jsonl", "/tmp/subagent-with-model.jsonl"])
    }

    func test_codexReaderSkipsJsonlLookupForTotalOnlyAttributionWithoutProjectPath() {
        let skippedPaths = CodexReader().pathsWithCompleteDatabaseAttribution(
            in: [
                CodexSession(rolloutPath: "/tmp/main-with-model.jsonl", model: "gpt-5.4"),
                CodexSession(
                    rolloutPath: "/tmp/model-without-source.jsonl",
                    model: "gpt-5.4",
                    hasSourceAttribution: false),
            ],
            requiresProjectAttribution: false)

        XCTAssertEqual(skippedPaths, ["/tmp/main-with-model.jsonl"])
    }

    func test_codexReaderUsesDatabaseCwdForProjectAttribution() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let dbURL = directory.appendingPathComponent("state_5.sqlite")
        let rolloutPath = directory.appendingPathComponent("rollout.jsonl").path
        try createSecurityAuditSQLiteDB(
            at: dbURL,
            statements: [
                """
                CREATE TABLE threads (
                    rollout_path TEXT NOT NULL,
                    model TEXT,
                    source TEXT NOT NULL,
                    cwd TEXT NOT NULL,
                    created_at INTEGER NOT NULL,
                    updated_at INTEGER NOT NULL
                )
                """,
                """
                INSERT INTO threads (
                    rollout_path,
                    model,
                    source,
                    cwd,
                    created_at,
                    updated_at
                ) VALUES (
                    '\(rolloutPath)',
                    'gpt-5.4-mini',
                    'vscode',
                    '/Users/example/Desktop/Project/content',
                    1775779200,
                    1775782800
                )
                """,
            ])

        let session = try XCTUnwrap(
            CodexReader(dbPath: dbURL.path)
                .overlappingSessions(
                    from: isoDate("2026-04-10T00:00:00Z"),
                    to: isoDate("2026-04-11T00:00:00Z"))
                .first { $0.rolloutPath == rolloutPath })

        XCTAssertEqual(session.projectPath, "/Users/example/Desktop/Project/content")
        XCTAssertEqual(session.projectAttributionQuality, .exact)
        XCTAssertEqual(session.attribution.projectName, "content")
    }

    func test_codexReaderKeepsDatabaseSessionsWhenCwdColumnIsMissing() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let dbURL = directory.appendingPathComponent("state_5.sqlite")
        let rolloutPath = directory.appendingPathComponent("rollout.jsonl").path
        try createSecurityAuditSQLiteDB(
            at: dbURL,
            statements: [
                """
                CREATE TABLE threads (
                    rollout_path TEXT NOT NULL,
                    model TEXT,
                    source TEXT NOT NULL,
                    created_at INTEGER NOT NULL,
                    updated_at INTEGER NOT NULL
                )
                """,
                """
                INSERT INTO threads (
                    rollout_path,
                    model,
                    source,
                    created_at,
                    updated_at
                ) VALUES (
                    '\(rolloutPath)',
                    'gpt-5.4-mini',
                    'vscode',
                    1775779200,
                    1775782800
                )
                """,
            ])

        let session = try XCTUnwrap(
            CodexReader(dbPath: dbURL.path)
                .overlappingSessions(
                    from: isoDate("2026-04-10T00:00:00Z"),
                    to: isoDate("2026-04-11T00:00:00Z"))
                .first { $0.rolloutPath == rolloutPath })

        XCTAssertEqual(session.model, "gpt-5.4-mini")
        XCTAssertEqual(session.hasSourceAttribution, true)
        XCTAssertNil(session.projectPath)
        XCTAssertEqual(session.projectAttributionQuality, .unknown)
    }

    func test_codexReaderMergesJsonlSourceAttributionWhenDatabaseSourceIsMissing() {
        let merged = CodexReader().mergedSessions(
            databaseSessions: [
                CodexSession(
                    rolloutPath: "/tmp/rollout-a.jsonl",
                    model: "gpt-5.4",
                    hasSourceAttribution: false),
            ],
            jsonlSessions: [
                CodexSession(
                    rolloutPath: "/tmp/rollout-a.jsonl",
                    model: nil,
                    agentKind: .subagent,
                    hasSourceAttribution: true),
            ])

        XCTAssertEqual(merged.count, 1)
        XCTAssertEqual(merged.first?.model, "gpt-5.4")
        XCTAssertEqual(merged.first?.agentKind, .subagent)
        XCTAssertEqual(merged.first?.hasSourceAttribution, true)
    }

    private func tokenCountLine(
        ts: String,
        input: Int,
        cachedInput: Int,
        output: Int,
        reasoning: Int,
        total: Int) -> String {
        tokenCountLine(
            ts: ts,
            input: input,
            cachedInput: cachedInput,
            output: output,
            reasoning: reasoning,
            total: total,
            additionalInfoFields: [])
    }

    private func tokenCountLine(
        ts: String,
        input: Int,
        cachedInput: Int,
        output: Int,
        reasoning: Int,
        total: Int,
        lastUsage: TokenCountLineUsage) -> String {
        tokenCountLine(
            ts: ts,
            input: input,
            cachedInput: cachedInput,
            output: output,
            reasoning: reasoning,
            total: total,
            additionalInfoFields: [
                tokenUsageField("last_token_usage", usage: lastUsage),
            ])
    }

    private func tokenCountLine(
        ts: String,
        input: Int,
        cachedInput: Int,
        output: Int,
        reasoning: Int,
        total: Int,
        additionalInfoFields: [String]) -> String {
        let totalUsage = TokenCountLineUsage(
            input: input,
            cachedInput: cachedInput,
            output: output,
            reasoning: reasoning,
            total: total)
        let infoFields = [
            tokenUsageField("total_token_usage", usage: totalUsage),
        ] + additionalInfoFields

        return """
        {"timestamp":"\(ts)","type":"event_msg",\
        "payload":{"type":"token_count","info":{\(infoFields.joined(separator: ","))}}}
        """
    }

    private func tokenUsageField(_ name: String, usage: TokenCountLineUsage) -> String {
        """
        "\(name)":{"input_tokens":\(usage.input),\
        "cached_input_tokens":\(usage.cachedInput),\
        "output_tokens":\(usage.output),\
        "reasoning_output_tokens":\(usage.reasoning),\
        "total_tokens":\(usage.total)}
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

private struct TokenCountLineUsage {
    let input: Int
    let cachedInput: Int
    let output: Int
    let reasoning: Int
    let total: Int

    init(
        input: Int,
        cachedInput: Int,
        output: Int,
        reasoning: Int) {
        self.init(
            input: input,
            cachedInput: cachedInput,
            output: output,
            reasoning: reasoning,
            total: input + output)
    }

    init(
        input: Int,
        cachedInput: Int,
        output: Int,
        reasoning: Int,
        total: Int) {
        self.input = input
        self.cachedInput = cachedInput
        self.output = output
        self.reasoning = reasoning
        self.total = total
    }
}
