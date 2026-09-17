import XCTest
@testable import TokiUsageReaders

final class ClaudeUsageCacheTests: XCTestCase {
    func test_evictsLeastRecentlyUsedEntryOverCountLimit() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("toki-claude-cache-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let first = root.appendingPathComponent("first.jsonl")
        let second = root.appendingPathComponent("second.jsonl")
        try Data("{}\n".utf8).write(to: first)
        try Data("{}\n".utf8).write(to: second)
        let cache = ClaudeUsageCache(
            cacheURL: root.appendingPathComponent("cache.json"),
            maximumEntryCount: 1)

        await cache.store(records: [cachedUsageRecord()], for: first)
        await cache.store(records: [cachedUsageRecord()], for: second)
        let firstRecords = await cache.records(for: first)
        let secondRecords = await cache.records(for: second)

        XCTAssertNil(firstRecords)
        XCTAssertNotNil(secondRecords)
    }

    func test_evictsUntilEncodedPayloadFitsAndPersists() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("toki-claude-cache-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let first = root.appendingPathComponent("aa.jsonl")
        let second = root.appendingPathComponent("bb.jsonl")
        try Data("{}\n".utf8).write(to: first)
        try Data("{}\n".utf8).write(to: second)
        let probeURL = root.appendingPathComponent("probe-cache.json")
        await ClaudeUsageCache(cacheURL: probeURL).store(records: [cachedUsageRecord()], for: first)
        let singleEntryPayloadBytes = try Data(contentsOf: probeURL).count

        // Both entries alone fit, but the second key pushes the encoded file past the limit.
        let cacheURL = root.appendingPathComponent("cache.json")
        let maximumBytes = singleEntryPayloadBytes * 2 - 20
        let cache = ClaudeUsageCache(cacheURL: cacheURL, maximumBytes: maximumBytes)
        await cache.store(records: [cachedUsageRecord()], for: first)
        await cache.store(records: [cachedUsageRecord()], for: second)

        let firstRecords = await cache.records(for: first)
        let secondRecords = await cache.records(for: second)
        let reloadedRecords = await ClaudeUsageCache(cacheURL: cacheURL, maximumBytes: maximumBytes)
            .records(for: second)

        XCTAssertNil(firstRecords)
        XCTAssertNotNil(secondRecords)
        XCTAssertNotNil(reloadedRecords)
        XCTAssertLessThanOrEqual(try Data(contentsOf: cacheURL).count, maximumBytes)
    }

    func test_dropsEntriesForMissingFiles() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("toki-claude-cache-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let retained = root.appendingPathComponent("retained.jsonl")
        let removed = root.appendingPathComponent("removed.jsonl")
        try Data("{}\n".utf8).write(to: retained)
        try Data("{}\n".utf8).write(to: removed)
        let cache = ClaudeUsageCache(cacheURL: root.appendingPathComponent("cache.json"))
        await cache.store(records: [cachedUsageRecord()], for: retained)
        await cache.store(records: [cachedUsageRecord()], for: removed)

        await cache.retainFiles([retained])
        let retainedRecords = await cache.records(for: retained)
        let removedRecords = await cache.records(for: removed)

        XCTAssertNotNil(retainedRecords)
        XCTAssertNil(removedRecords)
    }
}

private func cachedUsageRecord() -> ClaudeCachedUsageRecord {
    ClaudeCachedUsageRecord(
        lineIndex: 0,
        timestamp: 1_750_000_000,
        requestId: "request",
        sessionID: "session",
        cwd: "/private/project",
        messageID: "message",
        model: "claude-sonnet-4-6",
        input: 10,
        output: 2,
        cacheRead: 0,
        cacheWrite: 0)
}
