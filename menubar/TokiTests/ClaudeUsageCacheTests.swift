import XCTest
@testable import TokiUsageReaders

final class ClaudeUsageCacheTests: XCTestCase {
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

    func test_readOutputTokensSkipsFilesUntouchedSinceStartAndDefersPersistence() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("toki-claude-cache-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let projects = root.appendingPathComponent("projects", isDirectory: true)
        try FileManager.default.createDirectory(at: projects, withIntermediateDirectories: true)
        let now = Date()
        let start = now.addingTimeInterval(-3600)
        let recent = projects.appendingPathComponent("recent.jsonl")
        let untouched = projects.appendingPathComponent("untouched.jsonl")
        try Data(assistantLine(id: "recent", at: now.addingTimeInterval(-60), output: 7).utf8)
            .write(to: recent)
        try Data(assistantLine(id: "untouched", at: now.addingTimeInterval(-60), output: 100).utf8)
            .write(to: untouched)
        try FileManager.default.setAttributes(
            [.modificationDate: start.addingTimeInterval(-60)],
            ofItemAtPath: untouched.path)
        let cacheURL = root.appendingPathComponent("cache.json")
        let reader = ClaudeCodeReader(
            projectsURLOverride: projects,
            usageCache: ClaudeUsageCache(cacheURL: cacheURL))

        let outputTokens = try await reader.readOutputTokens(from: start, to: now)
        let cacheWrittenByOutputRead = FileManager.default.fileExists(atPath: cacheURL.path)
        let fullUsage = try await reader.readUsage(from: start, to: now)

        XCTAssertEqual(outputTokens, 7)
        XCTAssertFalse(cacheWrittenByOutputRead)
        XCTAssertEqual(fullUsage.outputTokens, 107)
        XCTAssertTrue(FileManager.default.fileExists(atPath: cacheURL.path))
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

private func assistantLine(id: String, at date: Date, output: Int) -> String {
    let timestamp = ISO8601DateFormatter().string(from: date)
    return #"{"type":"assistant","timestamp":"\#(timestamp)","requestId":"\#(id)","#
        + #""message":{"id":"\#(id)","model":"claude-sonnet-4-6","#
        + #""usage":{"input_tokens":1,"output_tokens":\#(output)}}}"#
        + "\n"
}
