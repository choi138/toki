import Foundation
import TokiUsageCore
import XCTest
@testable import TokiUsageReaders

final class QwenReaderTests: XCTestCase {
    private let startDate = Date(timeIntervalSince1970: 1_770_000_000)
    private let endDate = Date(timeIntervalSince1970: 1_780_000_000)

    func test_qwenMapsAssistantUsageMetadataWithoutInventingCost() throws {
        let lines = [
            #"{"uuid":"message-1","type":"assistant","model":"qwen3.5-plus","# +
                #""timestamp":"2026-02-23T14:24:56.857Z","sessionId":"session-qwen","# +
                #""cwd":"/Users/test/Projects/my-project","usageMetadata":{"promptTokenCount":120,"# +
                #""candidatesTokenCount":30,"thoughtsTokenCount":7,"cachedContentTokenCount":11}}"#,
            #"{"type":"session","model":"qwen3.5-plus","timestamp":"2026-02-23T14:25:00.000Z","# +
                #""sessionId":"session-qwen","usageMetadata":{"promptTokenCount":999,"# +
                #""candidatesTokenCount":999,"thoughtsTokenCount":999,"cachedContentTokenCount":999}}"#,
        ]

        let usage = try QwenCLIReader.usage(
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
        XCTAssertNotEqual(usage.tokenEvents.first?.attribution?.sessionID, "session-qwen")
        XCTAssertEqual(usage.tokenEvents.first?.attribution?.sessionLabel, "session-qwen")
        XCTAssertEqual(
            usage.tokenEvents.first?.attribution?.projectPath,
            "/Users/test/Projects/my-project")
        XCTAssertEqual(usage.tokenEvents.first?.attribution?.projectName, "my-project")
        XCTAssertEqual(usage.tokenEvents.first?.attribution?.quality, .exact)
        XCTAssertEqual(usage.activityEvents.count, 1)
    }

    func test_qwenDeduplicatesDivergentReplicasByRecordUUID() throws {
        let usage = try QwenCLIReader.usage(
            fromJSONLSessions: [
                (
                    streamID: "/tmp/default/projects/workspace/chats/one.jsonl",
                    lines: [
                        #"{"uuid":"message-a","type":"assistant","model":"qwen3-coder","# +
                            #""timestamp":"2026-02-23T14:24:56.857Z","sessionId":"replicated","# +
                            #""usageMetadata":{"promptTokenCount":10,"candidatesTokenCount":0}}"#,
                        #"{"uuid":"message-b","type":"assistant","model":"qwen3-coder","# +
                            #""timestamp":"2026-02-23T14:25:56.857Z","sessionId":"replicated","# +
                            #""usageMetadata":{"promptTokenCount":20,"candidatesTokenCount":0}}"#,
                    ]),
                (
                    streamID: "/tmp/override/projects/workspace/chats/copy.jsonl",
                    lines: [
                        #"{"uuid":"message-b","type":"assistant","model":"qwen3-coder","# +
                            #""timestamp":"2026-02-23T14:25:56.857Z","sessionId":"replicated","# +
                            #""usageMetadata":{"promptTokenCount":20,"candidatesTokenCount":0}}"#,
                        #"{"uuid":"message-c","type":"assistant","model":"qwen3-coder","# +
                            #""timestamp":"2026-02-23T14:26:56.857Z","sessionId":"replicated","# +
                            #""usageMetadata":{"promptTokenCount":30,"candidatesTokenCount":0}}"#,
                    ]),
            ],
            from: startDate,
            to: endDate)

        XCTAssertEqual(usage.totalTokens, 60)
        XCTAssertEqual(usage.tokenEvents.count, 3)
    }

    func test_qwenDeduplicatesUUIDAcrossDifferentReplicaMetadata() throws {
        let replicated =
            #"{"uuid":"same-message","type":"assistant","model":"qwen3-coder","# +
            #""timestamp":"2026-02-23T14:24:56.857Z","usageMetadata":{"promptTokenCount":10,"# +
            #""candidatesTokenCount":2}}"#
        let usage = try QwenCLIReader.usage(
            fromJSONLSessions: [
                (
                    streamID: "/tmp/default/projects/-tmp-workspace/chats/original.jsonl",
                    lines: [
                        replicated.replacingOccurrences(
                            of: #""usageMetadata""#,
                            with: #""sessionId":"original","cwd":"/tmp/workspace","usageMetadata""#),
                    ]),
                (
                    streamID: "/tmp/override/projects/-tmp-workspace/chats/renamed.jsonl",
                    lines: [replicated]),
            ],
            from: startDate,
            to: endDate)

        XCTAssertEqual(usage.totalTokens, 12)
        XCTAssertEqual(usage.tokenEvents.count, 1)
    }

    func test_qwenSkipsMalformedAndTruncatedRecords() throws {
        let usage = try QwenCLIReader.usage(
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
        XCTAssertNotEqual(usage.tokenEvents.first?.attribution?.sessionID, "fallback-session")
        XCTAssertEqual(usage.tokenEvents.first?.attribution?.sessionLabel, "fallback-session")
    }

    func test_qwenPreservesUsageWhenOptionalMetadataIsMalformed() throws {
        let usage = try QwenCLIReader.usage(
            fromJSONLLines: [
                #"{"uuid":{"unexpected":true},"type":"assistant","model":["qwen3"],"# +
                    #""timestamp":"2026-02-23T14:24:56.857Z","sessionId":42,"cwd":false,"# +
                    #""usageMetadata":{"promptTokenCount":10,"candidatesTokenCount":2}}"#,
            ],
            streamID: "/tmp/.qwen/projects/workspace/chats/fallback-session.jsonl",
            from: startDate,
            to: endDate)

        XCTAssertEqual(usage.totalTokens, 12)
        XCTAssertEqual(usage.tokenEvents.count, 1)
        XCTAssertNil(usage.tokenEvents.first?.model)
        XCTAssertEqual(usage.tokenEvents.first?.attribution?.sessionLabel, "fallback-session")
        XCTAssertEqual(usage.tokenEvents.first?.attribution?.quality, .inferred)
    }

    func test_qwenSkipsOverflowingTokenRecords() throws {
        let overflowing =
            #"{"uuid":"overflow","type":"assistant","model":"qwen3","# +
            #""timestamp":"2026-02-23T14:24:56.857Z","usageMetadata":{"promptTokenCount":"# +
            String(Int.max) +
            #","candidatesTokenCount":1}}"#
        let valid =
            #"{"uuid":"valid","type":"assistant","model":"qwen3","# +
            #""timestamp":"2026-02-23T14:25:56.857Z","usageMetadata":{"promptTokenCount":10,"# +
            #""candidatesTokenCount":2}}"#

        let usage = try QwenCLIReader.usage(
            fromJSONLLines: [overflowing, valid],
            streamID: "/tmp/.qwen/projects/workspace/chats/fallback-session.jsonl",
            from: startDate,
            to: endDate)

        XCTAssertEqual(usage.totalTokens, 12)
        XCTAssertEqual(usage.tokenEvents.count, 1)
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

extension QwenReaderTests {
    func test_qwenDeduplicatesUUIDlessDivergentReplicasByContent() throws {
        func line(timestamp: String, tokens: Int) -> String {
            #"{"type":"assistant","model":"qwen3","timestamp":""# + timestamp +
                #"","sessionId":"session","cwd":"/tmp/workspace","# +
                #""usageMetadata":{"promptTokenCount":"# + String(tokens) +
                #","candidatesTokenCount":0}}"#
        }
        let eventA = line(timestamp: "2026-02-23T14:24:56.857Z", tokens: 10)
        let eventB = line(timestamp: "2026-02-23T14:25:56.857Z", tokens: 20)
        let eventC = line(timestamp: "2026-02-23T14:26:56.857Z", tokens: 30)

        let usage = try QwenCLIReader.usage(
            fromJSONLSessions: [
                (streamID: "/tmp/a/projects/workspace/chats/a.jsonl", lines: [eventA, eventB]),
                (streamID: "/tmp/b/projects/workspace/chats/b.jsonl", lines: [eventB, eventC]),
            ],
            from: startDate,
            to: endDate)

        XCTAssertEqual(usage.totalTokens, 60)
        XCTAssertEqual(usage.tokenEvents.count, 3)
    }

    func test_qwenDeduplicatesUUIDlessReplicaWhenOnlyOneHasCWD() throws {
        let replicated =
            #"{"type":"assistant","model":"qwen3","timestamp":"2026-02-23T14:24:56.857Z","# +
            #""sessionId":"session","usageMetadata":{"promptTokenCount":10,"# +
            #""candidatesTokenCount":2}}"#
        let withCWD = replicated.replacingOccurrences(
            of: #""usageMetadata""#,
            with: #""cwd":"/tmp/workspace","usageMetadata""#)

        let usage = try QwenCLIReader.usage(
            fromJSONLSessions: [
                (
                    streamID: "/tmp/default/projects/workspace/chats/original.jsonl",
                    lines: [withCWD]),
                (
                    streamID: "/tmp/override/projects/workspace/chats/replica.jsonl",
                    lines: [replicated]),
            ],
            from: startDate,
            to: endDate)

        XCTAssertEqual(usage.totalTokens, 12)
        XCTAssertEqual(usage.tokenEvents.count, 1)
        XCTAssertEqual(usage.tokenEvents.first?.attribution?.projectPath, "/tmp/workspace")
    }

    func test_qwenKeepsUUIDlessContentAcrossDifferentExactProjects() throws {
        func line(cwd: String) -> String {
            #"{"type":"assistant","model":"qwen3","timestamp":"2026-02-23T14:24:56.857Z","# +
                #""sessionId":"session","cwd":""# + cwd +
                #"","usageMetadata":{"promptTokenCount":10,"candidatesTokenCount":2}}"#
        }

        let usage = try QwenCLIReader.usage(
            fromJSONLSessions: [
                (
                    streamID: "/tmp/default/projects/shared/chats/first.jsonl",
                    lines: [line(cwd: "/tmp/first")]),
                (
                    streamID: "/tmp/override/projects/shared/chats/second.jsonl",
                    lines: [line(cwd: "/tmp/second")]),
            ],
            from: startDate,
            to: endDate)

        XCTAssertEqual(usage.totalTokens, 24)
        XCTAssertEqual(usage.tokenEvents.count, 2)
        XCTAssertEqual(
            Set(usage.tokenEvents.compactMap(\.attribution?.projectPath)),
            ["/tmp/first", "/tmp/second"])
    }

    func test_chineseCLIReadersPropagateCancellation() async {
        let readers: [any TokenReader] = [
            KimiCLIReader(sessionRoots: []),
            KimiCodeReader(sessionRoots: []),
            QwenCLIReader(projectRoots: []),
        ]

        for reader in readers {
            let task = Task {
                while !Task.isCancelled {
                    await Task.yield()
                }
                return try await reader.readUsage(from: startDate, to: endDate)
            }
            task.cancel()

            do {
                _ = try await task.value
                XCTFail("Expected cancellation from \(reader.name)")
            } catch is CancellationError {
                // Expected.
            } catch {
                XCTFail("Unexpected error from \(reader.name): \(error)")
            }
        }
    }

    func test_chineseCLIReadersPropagateRootTraversalFailure() async throws {
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: file) }
        try Data().write(to: file)

        let readers: [any TokenReader] = [
            KimiCLIReader(sessionRoots: [file]),
            KimiCodeReader(sessionRoots: [file]),
            QwenCLIReader(projectRoots: [file]),
        ]

        for reader in readers {
            do {
                _ = try await reader.readUsage(from: startDate, to: endDate)
                XCTFail("Expected discovery failure from \(reader.name)")
            } catch is UsageFileDiscoveryError {
                // Expected.
            } catch {
                XCTFail("Unexpected error from \(reader.name): \(error)")
            }
        }
    }

    func test_qwenResolvesConflictingUUIDReplicasDeterministically() throws {
        let smaller =
            #"{"uuid":"same","type":"assistant","model":"qwen3","# +
            #""timestamp":"2026-02-23T14:24:56.857Z","sessionId":"session","# +
            #""usageMetadata":{"promptTokenCount":10,"candidatesTokenCount":0}}"#
        let larger =
            #"{"uuid":"same","type":"assistant","model":"qwen3","# +
            #""timestamp":"2026-02-23T14:25:56.857Z","sessionId":"session","# +
            #""usageMetadata":{"promptTokenCount":20,"candidatesTokenCount":0}}"#
        let sessions = [
            (streamID: "/tmp/a/projects/workspace/chats/a.jsonl", lines: [smaller]),
            (streamID: "/tmp/b/projects/workspace/chats/b.jsonl", lines: [larger]),
        ]

        let forward = try QwenCLIReader.usage(
            fromJSONLSessions: sessions,
            from: startDate,
            to: endDate)
        let reversed = try QwenCLIReader.usage(
            fromJSONLSessions: Array(sessions.reversed()),
            from: startDate,
            to: endDate)

        XCTAssertEqual(forward.totalTokens, 20)
        XCTAssertEqual(reversed.totalTokens, 20)
        XCTAssertEqual(forward.tokenEvents, reversed.tokenEvents)
    }

    func test_qwenDeduplicatesUUIDReplicasBeforeDateFiltering() throws {
        let boundary = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-02-23T14:25:00Z"))
        let before =
            #"{"uuid":"same","type":"assistant","model":"qwen3","# +
            #""timestamp":"2026-02-23T14:24:59.000Z","sessionId":"session","# +
            #""usageMetadata":{"promptTokenCount":10,"candidatesTokenCount":0}}"#
        let after =
            #"{"uuid":"same","type":"assistant","model":"qwen3","# +
            #""timestamp":"2026-02-23T14:25:01.000Z","sessionId":"session","# +
            #""usageMetadata":{"promptTokenCount":20,"candidatesTokenCount":0}}"#
        let sessions = [
            (streamID: "/tmp/a/projects/workspace/chats/a.jsonl", lines: [before]),
            (streamID: "/tmp/b/projects/workspace/chats/b.jsonl", lines: [after]),
        ]

        let beforeBoundary = try QwenCLIReader.usage(
            fromJSONLSessions: sessions,
            from: startDate,
            to: boundary)
        let afterBoundary = try QwenCLIReader.usage(
            fromJSONLSessions: sessions,
            from: boundary,
            to: endDate)

        XCTAssertEqual(beforeBoundary.totalTokens, 0)
        XCTAssertEqual(afterBoundary.totalTokens, 20)
        XCTAssertEqual(beforeBoundary.totalTokens + afterBoundary.totalTokens, 20)
    }

    func test_qwenKeepsSameUUIDAcrossDifferentProjects() throws {
        let first =
            #"{"uuid":"same","type":"assistant","model":"qwen3","# +
            #""timestamp":"2026-02-23T14:24:56.857Z","sessionId":"session","# +
            #""usageMetadata":{"promptTokenCount":10,"candidatesTokenCount":0}}"#
        let second =
            #"{"uuid":"same","type":"assistant","model":"qwen3","# +
            #""timestamp":"2026-02-23T14:25:56.857Z","sessionId":"session","# +
            #""usageMetadata":{"promptTokenCount":20,"candidatesTokenCount":0}}"#

        let usage = try QwenCLIReader.usage(
            fromJSONLSessions: [
                (streamID: "/tmp/root/projects/first/chats/a.jsonl", lines: [first]),
                (streamID: "/tmp/root/projects/second/chats/b.jsonl", lines: [second]),
            ],
            from: startDate,
            to: endDate)

        XCTAssertEqual(usage.totalTokens, 30)
        XCTAssertEqual(usage.tokenEvents.count, 2)
        XCTAssertEqual(Set(usage.tokenEvents.compactMap(\.attribution?.sessionID)).count, 2)
        XCTAssertEqual(Set(usage.tokenEvents.compactMap(\.attribution?.sessionLabel)), ["session"])
        XCTAssertEqual(usage.resolvedWorkTime.activeStreamCount, 2)
    }

    func test_qwenPrefersCWDWhenRootsShareProjectLayout() throws {
        let first =
            #"{"uuid":"same","type":"assistant","model":"qwen3","# +
            #""timestamp":"2026-02-23T14:24:56.857Z","sessionId":"session","# +
            #""cwd":"/tmp/first-project","usageMetadata":{"promptTokenCount":10,"# +
            #""candidatesTokenCount":0}}"#
        let second =
            #"{"uuid":"same","type":"assistant","model":"qwen3","# +
            #""timestamp":"2026-02-23T14:24:56.857Z","sessionId":"session","# +
            #""cwd":"/tmp/second-project","usageMetadata":{"promptTokenCount":20,"# +
            #""candidatesTokenCount":0}}"#

        let usage = try QwenCLIReader.usage(
            fromJSONLSessions: [
                (streamID: "/tmp/default/projects/shared/chats/session.jsonl", lines: [first]),
                (streamID: "/tmp/override/projects/shared/chats/session.jsonl", lines: [second]),
            ],
            from: startDate,
            to: endDate)

        XCTAssertEqual(usage.totalTokens, 30)
        XCTAssertEqual(usage.tokenEvents.count, 2)
        XCTAssertEqual(
            Set(usage.tokenEvents.compactMap(\.attribution?.projectPath)),
            ["/tmp/first-project", "/tmp/second-project"])
        XCTAssertEqual(Set(usage.tokenEvents.compactMap(\.attribution?.sessionID)).count, 2)
        XCTAssertEqual(Set(usage.tokenEvents.compactMap(\.attribution?.sessionLabel)), ["session"])
        XCTAssertEqual(usage.resolvedWorkTime.activeStreamCount, 2)
    }

    func test_qwenReadsInRangeRecordFromFileWithOldModificationDate() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let file = root
            .appendingPathComponent("workspace/chats", isDirectory: true)
            .appendingPathComponent("session.jsonl")
        try FileManager.default.createDirectory(
            at: file.deletingLastPathComponent(),
            withIntermediateDirectories: true)
        let line =
            #"{"uuid":"message","type":"assistant","model":"qwen3","# +
            #""timestamp":"2026-02-23T14:24:56.857Z","sessionId":"session","# +
            #""cwd":"/tmp/workspace","usageMetadata":{"promptTokenCount":10,"candidatesTokenCount":2}}"#
        try line.write(to: file, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.modificationDate: startDate.addingTimeInterval(-1)],
            ofItemAtPath: file.path)

        let usage = try await QwenCLIReader(projectRoots: [root])
            .readUsage(from: startDate, to: endDate)

        XCTAssertEqual(usage.totalTokens, 12)
    }

    func test_qwenDoesNotRedateTimestampLessRecordWhenFileGrows() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let file = root.appendingPathComponent("workspace/chats/session.jsonl")
        try FileManager.default.createDirectory(
            at: file.deletingLastPathComponent(),
            withIntermediateDirectories: true)
        let timestampLess =
            #"{"uuid":"old","type":"assistant","model":"qwen3","# +
            #""usageMetadata":{"promptTokenCount":10,"candidatesTokenCount":2}}"#
        try timestampLess.write(to: file, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.modificationDate: startDate.addingTimeInterval(1)],
            ofItemAtPath: file.path)

        let usage = try await QwenCLIReader(projectRoots: [root])
            .readUsage(from: startDate, to: endDate)

        XCTAssertEqual(usage.totalTokens, 0)
        XCTAssertTrue(usage.tokenEvents.isEmpty)
    }

    func test_jsonlIteratorHandlesChunkBoundariesIncrementally() throws {
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: file) }
        let longLine = String(repeating: "x", count: 70000)
        try Data(" \(longLine) \n\nsecond\nthird".utf8).write(to: file)

        var lines: [String] = []
        forEachJSONLLine(at: file) { line, _ in lines.append(line) }

        XCTAssertEqual(lines, [longLine, "second", "third"])
    }

    func test_jsonlLineSourcePropagatesOpenFailure() {
        let missingFile = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)

        XCTAssertThrowsError(
            try JSONLLineSource.file(missingFile).consume { _ in })
    }
}
