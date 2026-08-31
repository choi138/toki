import XCTest
@testable import TokiUsageReaders

final class CodexRolloutIncrementalCacheTests: XCTestCase {
    func test_completedBatchPersistsCheckpointWhileAnotherBatchRemainsActive() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("toki-rollout-overlapping-batch-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let rolloutURL = directory.appendingPathComponent("rollout.jsonl")
        let cacheURL = directory.appendingPathComponent("cache.json")
        let cache = CodexRolloutUsageCache(cacheURL: cacheURL)
        try Data((tokenCountLine(
            ts: "2026-04-10T08:00:00Z",
            input: 100,
            cachedInput: 20,
            output: 10,
            reasoning: 2,
            total: 110) + "\n").utf8).write(to: rolloutURL)

        let longLivedBatch = await cache.beginBatch(retaining: [rolloutURL.path])
        let completedBatch = await cache.beginBatch(retaining: [rolloutURL.path])
        _ = await cache.dailySummary(for: rolloutURL, includingDerivedData: false)
        await cache.endBatch(completedBatch)

        let cacheData = try Data(contentsOf: cacheURL)
        let cacheFile = try JSONDecoder().decode(CodexRolloutUsageCacheFile.self, from: cacheData)
        XCTAssertNotNil(cacheFile.entries[rolloutURL.path])

        await cache.endBatch(longLivedBatch)
    }

    func test_fastTimestampParserPreservesFractionalSecondsAndOffsets() throws {
        let utc = try XCTUnwrap(codexParseTimestamp("2026-04-10T08:00:00.125Z"))
        let offset = try XCTUnwrap(codexParseTimestamp("2026-04-10T17:00:00.125+09:00"))

        XCTAssertEqual(utc.timeIntervalSince1970, offset.timeIntervalSince1970, accuracy: 0.000_001)
    }

    func test_summaryStreamsPastOversizedIrrelevantLineWithoutLosingFollowingTokenEvent() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("toki-rollout-oversized-line-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let rolloutURL = directory.appendingPathComponent("rollout.jsonl")
        let cacheURL = directory.appendingPathComponent("cache.json")
        let cache = CodexRolloutUsageCache(cacheURL: cacheURL)
        let compactedPrefix = #"{"timestamp":"2026-04-10T07:59:59Z","type":"compacted","#
            + #""payload":{"content":"embedded \"token_count\" and \"session_meta\" "#
        var rollout = Data(compactedPrefix.utf8)
        XCTAssertTrue(codexDataIsCompactedRolloutEntry(rollout))
        rollout.append(Data(repeating: 0x78, count: 2 * 1024 * 1024))
        rollout.append(Data("\"}}\n".utf8))
        rollout.append(Data((tokenCountLine(
            ts: "2026-04-10T08:00:00Z",
            input: 100,
            cachedInput: 20,
            output: 10,
            reasoning: 2,
            total: 110) + "\n").utf8))
        try rollout.write(to: rolloutURL)

        let summary = await cache.dailySummary(for: rolloutURL)

        XCTAssertEqual(summary.dailyUsage["2026-04-10"]?.totalTokens, 110)
        XCTAssertEqual(summary.dailyTokenUsageEvents["2026-04-10"]?.count, 1)
        let cacheData = try Data(contentsOf: cacheURL)
        let cacheFile = try JSONDecoder().decode(CodexRolloutUsageCacheFile.self, from: cacheData)
        let cachedEntry = try XCTUnwrap(cacheFile.entries[rolloutURL.path])
        XCTAssertEqual(cachedEntry.processingState?.processedLineCount, 2)
        XCTAssertEqual(cachedEntry.processingState?.processedByteCount, cachedEntry.fileSize)
    }

    func test_tokenOnlySummaryCachesFullyReadRolloutWithoutTokenEvents() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("toki-rollout-empty-cache-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let rolloutURL = directory.appendingPathComponent("rollout.jsonl")
        let cacheURL = directory.appendingPathComponent("cache.json")
        let cache = CodexRolloutUsageCache(cacheURL: cacheURL)
        try Data("{\"timestamp\":\"2026-04-10T08:00:00Z\",\"type\":\"response_item\"}\n".utf8)
            .write(to: rolloutURL)

        let batch = await cache.beginBatch(retaining: [rolloutURL.path])
        let summary = await cache.dailySummary(for: rolloutURL, includingDerivedData: false)
        await cache.endBatch(batch)

        XCTAssertTrue(summary.isEmpty)
        let cacheData = try Data(contentsOf: cacheURL)
        let cacheFile = try JSONDecoder().decode(CodexRolloutUsageCacheFile.self, from: cacheData)
        let cachedEntry = try XCTUnwrap(cacheFile.entries[rolloutURL.path])
        XCTAssertTrue(cachedEntry.summary.isEmpty)
        XCTAssertEqual(cachedEntry.processingState?.processedByteCount, cachedEntry.fileSize)
    }

    func test_tokenOnlySummaryStaysCompactAndUpgradesForDetailedUsage() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("toki-rollout-compact-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let rolloutURL = directory.appendingPathComponent("rollout.jsonl")
        let cache = CodexRolloutUsageCache(cacheURL: directory.appendingPathComponent("cache.json"))
        let initial = tokenCountLine(
            ts: "2026-04-10T08:00:00Z",
            input: 100,
            cachedInput: 20,
            output: 10,
            reasoning: 2,
            total: 110)
        try Data((initial + "\n").utf8).write(to: rolloutURL)

        let compact = await cache.dailySummary(for: rolloutURL, includingDerivedData: false)
        XCTAssertEqual(compact.dailyUsage["2026-04-10"]?.totalTokens, 110)
        XCTAssertTrue(compact.dailyActivityTimestamps.isEmpty)
        XCTAssertTrue(compact.dailyTokenUsageEvents.isEmpty)

        let detailed = await cache.dailySummary(for: rolloutURL)
        XCTAssertEqual(detailed.dailyUsage["2026-04-10"]?.totalTokens, 110)
        XCTAssertEqual(detailed.dailyActivityTimestamps["2026-04-10"]?.count, 1)
        XCTAssertEqual(detailed.dailyTokenUsageEvents["2026-04-10"]?.count, 1)
    }

    func test_rolloutCacheIncrementallyProcessesAppendedForkContinuation() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("toki-rollout-incremental-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let rolloutURL = directory.appendingPathComponent("rollout.jsonl")
        let cache = CodexRolloutUsageCache(cacheURL: directory.appendingPathComponent("cache.json"))
        let initialLines = [
            tokenCountLine(
                ts: "2026-04-10T08:00:00Z",
                input: 100,
                cachedInput: 20,
                output: 10,
                reasoning: 2,
                total: 110),
            """
            {"timestamp":"2026-04-10T08:59:58Z","type":"session_meta",\
            "payload":{"id":"child-session","forked_from_id":"parent-session"}}
            """,
            tokenCountLine(
                ts: "2026-04-10T08:59:59Z",
                input: 100,
                cachedInput: 20,
                output: 10,
                reasoning: 2,
                total: 110),
        ]
        try Data((initialLines.joined(separator: "\n") + "\n").utf8).write(to: rolloutURL)

        let initial = await cache.dailySummary(for: rolloutURL)
        XCTAssertEqual(initial.dailyUsage["2026-04-10"]?.totalTokens, 110)

        let appendedLines = [
            #"{"timestamp":"2026-04-10T09:00:00Z","type":"turn_context","payload":{"model":"gpt-5.4-mini"}}"#,
            tokenCountLine(
                ts: "2026-04-10T09:00:01Z",
                input: 100,
                cachedInput: 20,
                output: 10,
                reasoning: 2,
                total: 110),
            tokenCountLine(
                ts: "2026-04-10T09:00:02Z",
                input: 120,
                cachedInput: 25,
                output: 15,
                reasoning: 3,
                total: 135),
        ]
        let handle = try FileHandle(forWritingTo: rolloutURL)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data((appendedLines.joined(separator: "\n") + "\n").utf8))
        try handle.close()

        let incrementallyUpdated = await cache.dailySummary(for: rolloutURL)
        let fullyRebuilt = codexRolloutDailySummary(fromRolloutAt: rolloutURL)

        XCTAssertEqual(incrementallyUpdated.dailyUsage["2026-04-10"]?.totalTokens, 135)
        XCTAssertEqual(
            incrementallyUpdated.dailyTokenUsageEvents["2026-04-10"]?.map(\.totalTokens),
            fullyRebuilt.dailyTokenUsageEvents["2026-04-10"]?.map(\.totalTokens))
        XCTAssertEqual(
            incrementallyUpdated.dailyActivityTimestamps["2026-04-10"],
            fullyRebuilt.dailyActivityTimestamps["2026-04-10"])
    }

    func test_rolloutCacheRebuildsWhenAppendedSnapshotIsOutOfOrder() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("toki-rollout-order-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let rolloutURL = directory.appendingPathComponent("rollout.jsonl")
        let cache = CodexRolloutUsageCache(cacheURL: directory.appendingPathComponent("cache.json"))
        let later = tokenCountLine(
            ts: "2026-04-10T13:00:00Z",
            input: 170,
            cachedInput: 30,
            output: 40,
            reasoning: 10,
            total: 220)
        try Data((later + "\n").utf8).write(to: rolloutURL)
        _ = await cache.dailySummary(for: rolloutURL)

        let earlier = tokenCountLine(
            ts: "2026-04-10T10:00:00Z",
            input: 120,
            cachedInput: 20,
            output: 30,
            reasoning: 5,
            total: 150)
        let handle = try FileHandle(forWritingTo: rolloutURL)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data((earlier + "\n").utf8))
        try handle.close()

        let updated = await cache.dailySummary(for: rolloutURL)

        XCTAssertEqual(updated.dailyUsage["2026-04-10"]?.totalTokens, 210)
        XCTAssertEqual(updated.dailyTokenUsageEvents["2026-04-10"]?.map(\.totalTokens), [150, 60])
    }
}
