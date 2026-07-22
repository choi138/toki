import TokiUsageCore
import XCTest
@testable import Toki
@testable import TokiUsageReaders

final class ClaudeCodeReaderActivityTests: XCTestCase {
    func test_claudeUsageCachePersistsWithPrivatePermissions() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("toki-claude-cache-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let transcriptURL = root.appendingPathComponent("session.jsonl")
        try Data("{}\n".utf8).write(to: transcriptURL)
        let cacheURL = root.appendingPathComponent("private/claude-usage-cache.json")
        let cache = ClaudeUsageCache(cacheURL: cacheURL)

        await cache.store(
            records: [
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
                    cacheWrite: 0),
            ],
            for: transcriptURL)

        let cachePermissions = try XCTUnwrap(
            FileManager.default.attributesOfItem(atPath: cacheURL.path)[.posixPermissions] as? NSNumber)
        let directoryPermissions = try XCTUnwrap(
            FileManager.default.attributesOfItem(
                atPath: cacheURL.deletingLastPathComponent().path)[.posixPermissions] as? NSNumber)
        XCTAssertEqual(cachePermissions.intValue & 0o777, 0o600)
        XCTAssertEqual(directoryPermissions.intValue & 0o777, 0o700)
    }

    func test_claudeUsageCacheRejectsNonPrivateCacheFile() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("toki-claude-cache-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let transcriptURL = root.appendingPathComponent("session.jsonl")
        try Data("{}\n".utf8).write(to: transcriptURL)
        let cacheURL = root.appendingPathComponent("private/claude-usage-cache.json")
        let cache = ClaudeUsageCache(cacheURL: cacheURL)
        await cache.store(
            records: [claudeCachedUsageRecord()],
            for: transcriptURL)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o644],
            ofItemAtPath: cacheURL.path)

        let reloadedCache = ClaudeUsageCache(cacheURL: cacheURL)
        let cachedRecords = await reloadedCache.records(for: transcriptURL)

        XCTAssertNil(cachedRecords)
        let permissions = try XCTUnwrap(
            FileManager.default.attributesOfItem(atPath: cacheURL.path)[.posixPermissions] as? NSNumber)
        XCTAssertEqual(permissions.intValue & 0o777, 0o600)
    }

    func test_claudeUsageCacheRejectsOversizedCacheBeforeDecoding() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("toki-claude-cache-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let transcriptURL = root.appendingPathComponent("session.jsonl")
        try Data("{}\n".utf8).write(to: transcriptURL)
        let cacheURL = root.appendingPathComponent("claude-usage-cache.json")
        try Data(repeating: 0x61, count: 128).write(to: cacheURL)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: cacheURL.path)
        let cache = ClaudeUsageCache(cacheURL: cacheURL, maximumBytes: 64)

        let cachedRecords = await cache.records(for: transcriptURL)

        XCTAssertNil(cachedRecords)
        XCTAssertLessThanOrEqual(try Data(contentsOf: cacheURL).count, 64)
    }

    func test_claudeCodeReaderDerivesProjectNameFromInjectedHome() async throws {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("toki-claude-home-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: home) }
        let encodedHome = home.path.replacingOccurrences(of: "/", with: "-")
        let projectsURL = home.appendingPathComponent(".claude/projects")
        let transcriptURL = projectsURL
            .appendingPathComponent("\(encodedHome)-work-app", isDirectory: true)
            .appendingPathComponent("session-a.jsonl")
        try FileManager.default.createDirectory(
            at: transcriptURL.deletingLastPathComponent(),
            withIntermediateDirectories: true)
        try claudeCodeReaderActivityLine(
            timestamp: "2026-04-10T00:00:00Z",
            requestId: "req-1",
            messageID: "msg-1",
            model: "claude-sonnet-4-6",
            input: 10,
            output: 2)
            .write(to: transcriptURL, atomically: true, encoding: .utf8)
        let reader = ClaudeCodeReader(
            projectsURLOverride: projectsURL,
            usageCache: ClaudeUsageCache(cacheURL: home.appendingPathComponent("cache.json")))

        let usage = try await reader.readUsage(
            from: claudeCodeReaderActivityISODate("2026-04-10T00:00:00Z"),
            to: claudeCodeReaderActivityISODate("2026-04-11T00:00:00Z"))

        XCTAssertEqual(usage.tokenEvents.first?.attribution?.projectName, "work-app")
        XCTAssertEqual(usage.tokenEvents.first?.attribution?.quality, .inferred)
    }

    func test_claudeCodeReader_deduplicatesActivityAcrossLogsForSameRequest() {
        let usage = ClaudeCodeReader.usage(
            fromJSONLSessions: [
                (
                    streamID: "project-a",
                    lines: [
                        claudeCodeReaderActivityLine(
                            timestamp: "2026-04-10T00:00:00Z",
                            requestId: "req-1",
                            messageID: "msg-1",
                            model: "claude-sonnet-4-6",
                            input: 10,
                            output: 2),
                        claudeCodeReaderActivityLine(
                            timestamp: "2026-04-10T00:01:00Z",
                            requestId: "req-1",
                            messageID: "msg-1",
                            model: "claude-sonnet-4-6",
                            input: 10,
                            output: 4),
                    ]),
                (
                    streamID: "project-b",
                    lines: [
                        claudeCodeReaderActivityLine(
                            timestamp: "2026-04-10T00:02:00Z",
                            requestId: "req-1",
                            messageID: "msg-1",
                            model: "claude-sonnet-4-6",
                            input: 10,
                            output: 7),
                    ]),
            ],
            from: claudeCodeReaderActivityISODate("2026-04-10T00:00:00Z"),
            to: claudeCodeReaderActivityISODate("2026-04-11T00:00:00Z"))

        XCTAssertEqual(usage.totalTokens, 17)
        XCTAssertEqual(usage.tokenEvents.count, 1)
        XCTAssertEqual(usage.tokenEvents.first?.timestamp, claudeCodeReaderActivityISODate("2026-04-10T00:02:00Z"))
        XCTAssertEqual(usage.tokenEvents.first?.totalTokens, 17)
        XCTAssertEqual(usage.activeSeconds, 90, accuracy: 0.001)
        XCTAssertEqual(
            usage.perModel["claude-sonnet-4-6"]?.activeSeconds ?? 0,
            90,
            accuracy: 0.001)
    }

    func test_claudeCodeReaderAttachesCwdAttributionToTokenEvents() {
        let usage = ClaudeCodeReader.usage(
            fromJSONLLines: [
                """
                {"type":"assistant","timestamp":"2026-04-10T00:00:00Z","requestId":"req-1",\
                "sessionId":"session-a","cwd":"/Users/example/Toki",\
                "message":{"id":"msg-1","model":"claude-sonnet-4-6","usage":{\
                "input_tokens":10,"output_tokens":2,"cache_read_input_tokens":0,\
                "cache_creation_input_tokens":0}}}
                """,
            ],
            streamID: "/Users/example/.claude/projects/-Users-example-Toki/session-a.jsonl",
            from: claudeCodeReaderActivityISODate("2026-04-10T00:00:00Z"),
            to: claudeCodeReaderActivityISODate("2026-04-11T00:00:00Z"))

        XCTAssertEqual(usage.tokenEvents.first?.attribution?.projectPath, "/Users/example/Toki")
        XCTAssertEqual(usage.tokenEvents.first?.attribution?.projectName, "Toki")
        XCTAssertEqual(usage.tokenEvents.first?.attribution?.sessionID, "session-a")
        XCTAssertEqual(usage.tokenEvents.first?.attribution?.quality, .exact)
    }

    func test_claudeCodeReaderUsesTranscriptIDAndSafeProjectNameWhenSessionIDIsMissing() {
        let usage = ClaudeCodeReader.usage(
            fromJSONLLines: [
                """
                {"type":"assistant","timestamp":"2026-04-10T00:00:00Z","requestId":"req-1",\
                "message":{"id":"msg-1","model":"claude-sonnet-4-6","usage":{\
                "input_tokens":10,"output_tokens":2,"cache_read_input_tokens":0,\
                "cache_creation_input_tokens":0}}}
                """,
            ],
            streamID: "/Users/example/.claude/projects/-Users-me-my-app/session-a.jsonl",
            from: claudeCodeReaderActivityISODate("2026-04-10T00:00:00Z"),
            to: claudeCodeReaderActivityISODate("2026-04-11T00:00:00Z"))

        XCTAssertNil(usage.tokenEvents.first?.attribution?.projectPath)
        XCTAssertEqual(usage.tokenEvents.first?.attribution?.projectName, "Users-me-my-app")
        XCTAssertEqual(usage.tokenEvents.first?.attribution?.sessionID, "session-a")
        XCTAssertEqual(usage.tokenEvents.first?.attribution?.quality, .inferred)
    }
}

private func claudeCachedUsageRecord() -> ClaudeCachedUsageRecord {
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

private func claudeCodeReaderActivityLine(
    timestamp: String,
    requestId: String,
    messageID: String,
    model: String,
    input: Int,
    output: Int,
    cacheRead: Int = 0,
    cacheWrite: Int = 0) -> String {
    """
    {"type":"assistant","timestamp":"\(timestamp)","requestId":"\(requestId)",\
    "message":{"id":"\(messageID)","model":"\(model)","usage":{\
    "input_tokens":\(input),"output_tokens":\(output),"cache_read_input_tokens":\(cacheRead),\
    "cache_creation_input_tokens":\(cacheWrite)}}}
    """
}

private func claudeCodeReaderActivityISODate(_ value: String) -> Date {
    guard let date = DateParser.parse(value) else {
        XCTFail("Failed to parse ISO date: \(value)")
        return Date.distantPast
    }
    return date
}
