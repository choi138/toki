import Foundation
import TokiUsageCore
import XCTest
@testable import TokiAgentCore
@testable import TokiUsageReaders

final class HermesDelegateUsageTests: XCTestCase {
    func testCodexDelegateOnlyAndCopiedLogsUseDisjointBucketsAndFastReads() async throws {
        let fixture = try DelegateUsageFixture()
        defer { fixture.remove() }
        for path in ["codex/run/task/events.jsonl", "review/copied/review.out", "qa/copied/qa.out"] {
            try fixture.writeCodex(path, session: "worker")
        }
        let reader = try fixture.reader("Codex")
        let usage = try await reader.readUsage(from: fixture.start, to: fixture.end)
        XCTAssertEqual(usage.totalTokens, 120)
        XCTAssertEqual(usage.inputTokens, 20)
        XCTAssertEqual(usage.cacheReadTokens, 80)
        XCTAssertEqual(usage.outputTokens, 15)
        XCTAssertEqual(usage.reasoningTokens, 5)
        XCTAssertEqual(usage.tokenEvents.count, 1)
        XCTAssertEqual(usage.perModel.values.reduce(0) { $0 + $1.totalTokens }, 120)
        let total = try await reader.readTotalTokens(from: fixture.start, to: fixture.end)
        let output = try await reader.readOutputTokens(from: fixture.start, to: fixture.end)
        XCTAssertEqual(total, usage.totalTokens)
        XCTAssertEqual(output, usage.outputTokens)
    }

    func testClaudeFinalModelCountersReplaceSmallAssistantSnapshotsAndCopies() async throws {
        let fixture = try DelegateUsageFixture()
        defer { fixture.remove() }
        for path in ["claude/run/claude.out", "review/copy/review.out"] {
            try fixture.writeClaude(path, session: "worker", completed: true)
        }
        let reader = try fixture.reader("Claude Code")
        let usage = try await reader.readUsage(from: fixture.start, to: fixture.end)
        XCTAssertEqual(usage.totalTokens, 150)
        XCTAssertEqual(usage.inputTokens, 10)
        XCTAssertEqual(usage.cacheReadTokens, 80)
        XCTAssertEqual(usage.cacheWriteTokens, 20)
        XCTAssertEqual(usage.outputTokens, 40)
        XCTAssertEqual(usage.tokenEvents.count, 2)
        XCTAssertEqual(usage.tokenEvents.first?.attribution?.sessionLabel, "Hermes delegation")
        XCTAssertEqual(usage.tokenEvents.first?.attribution?.projectPath, "/synthetic/project")
        XCTAssertTrue(usage.supplemental.isEmpty)
        let output = try await reader.readOutputTokens(from: fixture.start, to: fixture.end)
        XCTAssertEqual(output, 40)
    }

    func testNormalClaudeCopyIsReplacedAndUnrelatedSessionSurvives() async throws {
        let fixture = try DelegateUsageFixture()
        defer { fixture.remove() }
        try fixture.writeClaude("claude/run/claude.out", session: "worker", completed: true)
        try fixture.writeNativeClaude(session: "worker")
        try fixture.writeNativeClaude(session: "unrelated")
        let usage = try await fixture.reader("Claude Code").readUsage(from: fixture.start, to: fixture.end)
        XCTAssertEqual(usage.totalTokens, 162)
        XCTAssertEqual(usage.tokenEvents.count, 3)
        XCTAssertEqual(usage.tokenEvents.filter { $0.attribution?.sessionID == "worker" }.count, 2)
    }

    func testNormalCodexCopyIsReplacedAndUnrelatedSessionSurvives() async throws {
        let fixture = try DelegateUsageFixture()
        defer { fixture.remove() }
        try fixture.writeCodex("codex/run/task/events.jsonl", session: "worker")
        try fixture.writeNativeCodex(session: "worker")
        try fixture.writeNativeCodex(session: "unrelated")
        let reader = try fixture.reader("Codex")
        let usage = try await reader.readUsage(from: fixture.start, to: fixture.end)
        XCTAssertEqual(usage.totalTokens, 132)
        let fastTotal = try await reader.readTotalTokens(from: fixture.start, to: fixture.end)
        XCTAssertEqual(fastTotal, 132)
    }

    func testIncompleteClaudeIsLowerBoundThenCacheRefreshesToFinalUsage() async throws {
        let fixture = try DelegateUsageFixture()
        defer { fixture.remove() }
        let path = "claude/run/claude.out"
        try fixture.writeClaude(path, session: "worker", completed: false)
        let reader = try fixture.reader("Claude Code")
        let partial = try await reader.readUsage(from: fixture.start, to: fixture.end)
        XCTAssertEqual(partial.totalTokens, 111)
        XCTAssertEqual(partial.supplemental.first?.value, 1)
        XCTAssertEqual(partial.supplemental.first?.includedInTotals, false)
        try fixture.writeClaude(path, session: "worker", completed: true)
        let complete = try await reader.readUsage(from: fixture.start, to: fixture.end)
        XCTAssertEqual(complete.totalTokens, 150)
        XCTAssertTrue(complete.supplemental.isEmpty)
    }

    func testIncompleteNativeClaudeDoesNotDoubleCountPartialWorker() async throws {
        let fixture = try DelegateUsageFixture()
        defer { fixture.remove() }
        try fixture.writeClaude("claude/run/claude.out", session: "worker", completed: false)
        try fixture.writeNativeClaude(session: "worker")
        let usage = try await fixture.reader("Claude Code").readUsage(from: fixture.start, to: fixture.end)
        XCTAssertEqual(usage.totalTokens, 12)
        XCTAssertEqual(usage.supplemental.first?.value, 1)
    }

    func testFailedCodexHasUnknownUsageDiagnosticRatherThanAnExactZero() async throws {
        let fixture = try DelegateUsageFixture()
        defer { fixture.remove() }
        try fixture.writeLog("codex/run/task/events.jsonl", lines: [
            ["type": "thread.started", "thread_id": "failed"],
            ["type": "turn.failed"],
        ])
        let usage = try await fixture.reader("Codex").readUsage(from: fixture.start, to: fixture.end)
        XCTAssertEqual(usage.totalTokens, 0)
        XCTAssertEqual(usage.supplemental.first?.value, 1)
        XCTAssertEqual(usage.supplemental.first?.quality, .contextOnly)
    }

    func testCompletionDateUsesExplicitTimezoneAndExclusiveEnd() async throws {
        let fixture = try DelegateUsageFixture()
        defer { fixture.remove() }
        try fixture.writeClaude("claude/run/claude.out", session: "worker", completed: true)
        let endFile = fixture.delegates.appendingPathComponent("claude/run/ended_at")
        try Data("2026-04-11T00:00:00+0900\n".utf8).write(to: endFile)
        let midnight = try XCTUnwrap(DateParser.parse("2026-04-10T15:00:00Z"))
        let reader = try fixture.reader("Claude Code")
        let before = try await reader.readUsage(from: fixture.start, to: midnight)
        let after = try await reader.readUsage(from: midnight, to: fixture.end)
        XCTAssertEqual(before.totalTokens, 0)
        XCTAssertEqual(after.totalTokens, 150)
    }

    func testModelCounterMismatchFallsBackToAggregateWithoutAddingBoth() async throws {
        let fixture = try DelegateUsageFixture()
        defer { fixture.remove() }
        try fixture.writeLog("claude/run/claude.out", lines: [[
            "type": "result", "session_id": "worker",
            "usage": ["input_tokens": 10, "output_tokens": 20],
            "modelUsage": ["claude-sonnet-4-6": ["inputTokens": 999, "outputTokens": 999]],
        ]])
        let usage = try await fixture.reader("Claude Code").readUsage(from: fixture.start, to: fixture.end)
        XCTAssertEqual(usage.totalTokens, 30)
        XCTAssertEqual(usage.tokenEvents.count, 1)
    }

    func testCompletedClaudePreservesOneHourCacheWritesWithMatchingModelCounters() async throws {
        let fixture = try DelegateUsageFixture()
        defer { fixture.remove() }
        let model = "claude-sonnet-4-6"
        try fixture.writeLog("claude/run/claude.out", lines: [[
            "type": "result", "session_id": "worker",
            "usage": [
                "input_tokens": 10, "output_tokens": 20, "cache_creation_input_tokens": 1000,
                "cache_creation": ["ephemeral_1h_input_tokens": 800],
            ],
            "modelUsage": [model: ["inputTokens": 10, "outputTokens": 20, "cacheCreationInputTokens": 1000]],
        ]])
        let reader = try fixture.reader("Claude Code")
        let price = try XCTUnwrap(modelPrice(for: model, at: fixture.start))
        let expectedCost = price.cost(input: 10, output: 20, cacheRead: 0, cacheWrite: 200, cacheWriteOneHour: 800)
        for _ in 0..<2 {
            let usage = try await reader.readUsage(from: fixture.start, to: fixture.end)
            XCTAssertEqual(usage.totalTokens, 1030)
            XCTAssertEqual(usage.cacheWriteTokens, 1000)
            XCTAssertEqual(usage.cost, expectedCost, accuracy: 0.000_001)
            XCTAssertEqual(usage.tokenEvents.first?.model, model)
            XCTAssertEqual(try XCTUnwrap(usage.tokenEvents.first).cost, expectedCost, accuracy: 0.000_001)
        }
    }

    func testMixedModelResultRetainsAggregateWhenPerModelCacheTTLsAreUnavailable() throws {
        let fixture = try DelegateUsageFixture()
        defer { fixture.remove() }
        let path = "claude/run/claude.out"
        try fixture.writeLog(path, lines: [[
            "type": "result", "session_id": "worker",
            "usage": [
                "input_tokens": 10, "output_tokens": 20, "cache_creation_input_tokens": 1000,
                "cache_creation": ["ephemeral_1h_input_tokens": 800],
            ],
            "modelUsage": [
                "claude-sonnet-4-6": ["inputTokens": 5, "outputTokens": 10, "cacheCreationInputTokens": 500],
                "claude-opus-4-6": ["inputTokens": 5, "outputTokens": 10, "cacheCreationInputTokens": 500],
            ],
        ]])
        let parsed = try HermesDelegateLogParser.parse(file: fixture.delegates.appendingPathComponent(path))
        XCTAssertTrue(parsed.isComplete)
        XCTAssertEqual(parsed.entries.count, 1)
        XCTAssertEqual(parsed.entries.first?.totalTokens, 1030)
        XCTAssertEqual(parsed.entries.first?.cacheWriteOneHour, 800)
    }

    func testInvalidCountersAndChildSymlinksCannotInflateTotals() async throws {
        let fixture = try DelegateUsageFixture()
        defer { fixture.remove() }
        try fixture.writeLog("codex/invalid/events.jsonl", lines: [[
            "type": "turn.completed", "usage": ["input_tokens": -1, "output_tokens": 20],
        ]])
        let outside = fixture.home.appendingPathComponent("outside")
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        try Data("{}\n".utf8).write(to: outside.appendingPathComponent("events.jsonl"))
        try FileManager.default.createSymbolicLink(
            at: fixture.delegates.appendingPathComponent("linked"), withDestinationURL: outside)
        let usage = try await fixture.reader("Codex").readUsage(from: fixture.start, to: fixture.end)
        XCTAssertEqual(usage.totalTokens, 0)
        XCTAssertEqual(usage.supplemental.first?.value, 1)
    }
}

extension HermesDelegateUsageTests {
    func testDiscoveryRejectsOverflowBeforeFilteringLogNamesAcrossExtensions() async throws {
        let limits = PiCompatibleReadLimits(
            maximumFileCount: 2, maximumFileBytes: 1024, maximumLineBytes: 1024,
            maximumEventCount: 100, maximumEntryCount: 100)
        for extensions in [["jsonl", "jsonl", "jsonl"], ["out", "out", "out"], ["jsonl", "out", "out"]] {
            let fixture = try DelegateUsageFixture()
            defer { fixture.remove() }
            for (index, ext) in extensions.enumerated() {
                try fixture.writeLog("run-\(index)/ignored.\(ext)", lines: [])
            }
            do {
                _ = try await HermesDelegateUsageSource(root: fixture.delegates, provider: .codex).read(limits: limits)
                XCTFail("Truncated discovery must not appear complete: \(extensions)")
            } catch is HermesDelegateReadError {
                // Bounds failures are deliberately path-free.
            }
        }
    }

    func testDiscoveryAcceptsExactlyTheFileLimitAcrossExtensions() async throws {
        let fixture = try DelegateUsageFixture()
        defer { fixture.remove() }
        try fixture.writeCodex("codex/run/events.jsonl", session: "codex-worker")
        try fixture.writeClaude("claude/run/claude.out", session: "claude-worker", completed: true)
        let limits = PiCompatibleReadLimits(
            maximumFileCount: 2, maximumFileBytes: 1024, maximumLineBytes: 1024,
            maximumEventCount: 100, maximumEntryCount: 100)
        let usage = try await HermesDelegateUsageSource(root: fixture.delegates, provider: .codex)
            .read(limits: limits).usage(from: fixture.start, to: fixture.end)
        XCTAssertEqual(usage.totalTokens, 120)
    }

    func testRegisteredSourcesDetectOutFilesAndCompletionMetadataChanges() async throws {
        let agent = try AgentSyncFixture()
        defer { agent.remove() }
        for name in ["Codex", "Claude Code"] {
            let fixture = try DelegateUsageFixture()
            defer { fixture.remove() }
            let descriptor = try XCTUnwrap(LocalUsageReaderRegistry.agentDescriptors(
                home: fixture.home, environment: [:]).first { $0.name == name })
            XCTAssertEqual(descriptor.collectorRevision, 2)
            let builder = AgentSnapshotBuilder(
                home: fixture.home, environment: [:], readerDescriptors: [descriptor])
            let before = try await builder.sourceSignature(configuration: agent.configuration, now: fixture.end)
            let path = name == "Codex" ? "qa/run/qa.out" : "claude/run/claude.out"
            if name == "Codex" {
                try fixture.writeCodex(path, session: "worker")
            } else {
                try fixture.writeClaude(path, session: "worker", completed: true)
            }
            let after = try await builder.sourceSignature(configuration: agent.configuration, now: fixture.end)
            XCTAssertNotEqual(before, after, name)
            let marker = fixture.delegates.appendingPathComponent(path).deletingLastPathComponent()
                .appendingPathComponent("ended_at")
            try Data("2026-04-11T21:00:00+0900\n".utf8).write(to: marker)
            let updated = try await builder.sourceSignature(configuration: agent.configuration, now: fixture.end)
            XCTAssertNotEqual(after, updated, name)
        }
    }

    func testSourceSignatureCountsLogsSeparatelyFromTheirMetadata() async throws {
        let configuration = try AgentSyncFixture().configuration
        for name in ["Codex", "Claude Code"] {
            let fixture = try DelegateUsageFixture()
            defer { fixture.remove() }
            try fixture.writeCodex("run/events.jsonl", session: "worker")
            let original = try XCTUnwrap(LocalUsageReaderRegistry.agentDescriptors(
                home: fixture.home, environment: [:]).first { $0.name == name })
            let descriptor = LocalUsageReaderDescriptor(
                reader: original.reader, sourceLocations: original.sourceLocations,
                sourceSignatureStrategy: .boundedAllFiles(maximumFileCount: 1, maximumEntryCount: 100))
            let builder = AgentSnapshotBuilder(
                home: fixture.home, environment: [:], readerDescriptors: [descriptor])
            var signature = try await builder.sourceSignature(configuration: configuration, now: fixture.end)
            let directory = fixture.delegates.appendingPathComponent("run")
            for name in ["unrelated.json", "stdout", "started_at"] {
                try Data("ignored".utf8).write(to: directory.appendingPathComponent(name))
            }
            let unchanged = try await builder.sourceSignature(configuration: configuration, now: fixture.end)
            XCTAssertEqual(signature, unchanged)
            for name in ["meta.json", "status.json", "ended_at"] {
                try Data("changed".utf8).write(to: directory.appendingPathComponent(name))
                let changed = try await builder.sourceSignature(configuration: configuration, now: fixture.end)
                XCTAssertNotEqual(signature, changed, name)
                signature = changed
            }
        }
    }

    /// Opt-in local QA, using injected private caches; normal CI never reads a user's logs.
    func testLocalLogQAWhenExplicitlyEnabled() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let home = env["TOKI_DELEGATE_QA_HOME"],
              let from = env["TOKI_DELEGATE_QA_FROM"].flatMap(DateParser.parse),
              let to = env["TOKI_DELEGATE_QA_TO"].flatMap(DateParser.parse) else {
            throw XCTSkip("Local-log QA requires an explicitly selected home and date range.")
        }
        let fixture = try DelegateUsageFixture()
        defer { fixture.remove() }
        let paths = LocalUsageReaderPaths(homeDirectory: URL(fileURLWithPath: home), environment: [:])
        let codexCache = CodexRolloutUsageCache(cacheURL: fixture.home.appendingPathComponent("codex-cache"))
        let claudeCache = ClaudeUsageCache(cacheURL: fixture.home.appendingPathComponent("claude-cache"))
        let descriptors = LocalUsageReaderRegistry.descriptors(
            home: paths.homeDirectory, environment: [:], cacheScope: .agent,
            codexRolloutUsageCache: codexCache, claudeUsageCache: claudeCache)
        for (name, key) in [("Codex", "TOKI_DELEGATE_QA_CODEX"), ("Claude Code", "TOKI_DELEGATE_QA_CLAUDE")] {
            let delegatedExpected = try XCTUnwrap(env[key].flatMap(Int.init))
            let provider: HermesDelegateProvider = name == "Codex" ? .codex : .claude
            let delegated = try await HermesDelegateUsageSource(root: paths.hermesDelegateState, provider: provider)
                .read().usage(from: from, to: to)
            XCTAssertEqual(delegated.totalTokens, delegatedExpected, name)
            let nativeReader: any TokenReader = name == "Codex"
                ? CodexReader(dbPath: paths.codexDatabase.path, rolloutUsageCache: codexCache)
                : ClaudeCodeReader(
                    projectsURLOverride: paths.claudeProjects, usageCache: claudeCache,
                    transcriptsURLOverride: paths.claudeTranscripts, attributionHomeDirectory: paths.homeDirectory)
            let native = try await nativeReader.readUsage(from: from, to: to)
            let expected = native.totalTokens + delegatedExpected
            let reader = try XCTUnwrap(descriptors.first { $0.name == name }?.reader)
            let cold = try await reader.readUsage(from: from, to: to)
            let warm = try await reader.readUsage(from: from, to: to)
            XCTAssertEqual(cold.totalTokens, expected, name)
            XCTAssertEqual(warm.totalTokens, expected, name)
            XCTAssertEqual(cold.tokenEvents.reduce(0) { $0 + $1.totalTokens }, expected, name)
            XCTAssertEqual(cold.perModel.values.reduce(0) { $0 + $1.totalTokens }, expected, name)
            let fast = try await reader.readTotalTokens(from: from, to: to)
            XCTAssertEqual(fast, expected, name)
            let output = try await reader.readOutputTokens(from: from, to: to)
            XCTAssertEqual(output, cold.outputTokens, name)
            print(
                "Local QA \(name): native=\(native.totalTokens), delegated=\(delegated.totalTokens), "
                    + "total=\(cold.totalTokens), fast=\(fast), events=\(cold.tokenEvents.count)")
        }
    }
}

extension HermesDelegateUsageTests {
    func testCopiedResultWithDifferentCompletionDayAndModelRepresentationCountsOnce() async throws {
        let fixture = try DelegateUsageFixture()
        defer { fixture.remove() }
        try fixture.writeClaude("claude/original/claude.out", session: "worker", completed: true)
        try fixture.writeLog("review/copy/review.out", lines: [[
            "type": "result", "session_id": "worker", "usage": [
                "input_tokens": 10, "cache_read_input_tokens": 80,
                "cache_creation_input_tokens": 20, "output_tokens": 40,
            ],
        ]])
        try Data("2026-04-11T21:00:00+0900\n".utf8)
            .write(to: fixture.delegates.appendingPathComponent("review/copy/ended_at"))
        let midnight = try XCTUnwrap(DateParser.parse("2026-04-10T15:00:00Z"))
        let reader = try fixture.reader("Claude Code")
        let whole = try await reader.readUsage(from: fixture.start, to: fixture.end)
        let first = try await reader.readUsage(from: fixture.start, to: midnight)
        let second = try await reader.readUsage(from: midnight, to: fixture.end)
        XCTAssertEqual(whole.totalTokens, 150)
        XCTAssertEqual(first.totalTokens, 150)
        XCTAssertEqual(second.totalTokens, 0)
    }

    func testOverflowingModelBreakdownFallsBackToValidAggregate() async throws {
        let fixture = try DelegateUsageFixture()
        defer { fixture.remove() }
        let large = Int.max / 2 + 1
        try fixture.writeLog("claude/run/claude.out", lines: [[
            "type": "result", "session_id": "worker", "usage": ["input_tokens": 10, "output_tokens": 20],
            "modelUsage": ["model-a": ["inputTokens": large], "model-b": ["inputTokens": large]],
        ]])
        let usage = try await fixture.reader("Claude Code").readUsage(from: fixture.start, to: fixture.end)
        XCTAssertEqual(usage.totalTokens, 30)
    }

    func testCodexCompletedTurnFollowedByRunningTurnIsStillIncomplete() async throws {
        let fixture = try DelegateUsageFixture()
        defer { fixture.remove() }
        try fixture.writeLog("codex/run/task/events.jsonl", lines: [
            ["type": "thread.started", "thread_id": "worker"],
            ["type": "turn.completed", "usage": ["input_tokens": 10, "output_tokens": 2]],
            ["type": "turn.started"],
        ])
        let usage = try await fixture.reader("Codex").readUsage(from: fixture.start, to: fixture.end)
        XCTAssertEqual(usage.totalTokens, 12)
        XCTAssertEqual(usage.supplemental.first?.value, 1)
    }
}

struct DelegateUsageFixture {
    let home: URL
    let start: Date
    let end: Date
    var delegates: URL {
        home.appendingPathComponent(".local/state/hermes-delegate")
    }

    init() throws {
        home = FileManager.default.temporaryDirectory.appendingPathComponent("toki-delegate-\(UUID().uuidString)")
        start = try XCTUnwrap(DateParser.parse("2026-04-10T00:00:00Z"))
        end = try XCTUnwrap(DateParser.parse("2026-04-12T00:00:00Z"))
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
    }

    func remove() {
        try? FileManager.default.removeItem(at: home)
    }

    func reader(_ name: String) throws -> any TokenReader {
        try XCTUnwrap(LocalUsageReaderRegistry.descriptors(home: home, environment: [:], cacheScope: .agent)
            .first { $0.name == name }?.reader)
    }

    func writeLog(_ path: String, lines: [[String: Any]]) throws {
        let file = delegates.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        var data = Data()
        for line in lines {
            try data.append(JSONSerialization.data(withJSONObject: line, options: [.sortedKeys]))
            data.append(0x0A)
        }
        try data.write(to: file)
        try Data("2026-04-10T21:00:00+0900\n".utf8)
            .write(to: file.deletingLastPathComponent().appendingPathComponent("ended_at"))
        try JSONSerialization.data(withJSONObject: ["workdir": "/synthetic/project", "model": "gpt-5"])
            .write(to: file.deletingLastPathComponent().appendingPathComponent("meta.json"))
    }

    func writeCodex(_ path: String, session: String) throws {
        try writeLog(path, lines: [
            ["type": "thread.started", "thread_id": session],
            ["type": "turn.completed", "usage": [
                "input_tokens": 100, "cached_input_tokens": 80, "output_tokens": 20, "reasoning_output_tokens": 5,
            ]],
        ])
    }

    func writeClaude(_ path: String, session: String, completed: Bool) throws {
        let assistant: [String: Any] = [
            "type": "assistant", "session_id": session, "timestamp": "2026-04-10T01:00:00Z",
            "message": ["id": "message", "model": "claude-sonnet-4-6", "usage": [
                "input_tokens": 10, "cache_read_input_tokens": 80, "cache_creation_input_tokens": 20,
                "output_tokens": 1,
            ]],
        ]
        var lines = [assistant, assistant]
        if completed {
            lines.append([
                "type": "result", "session_id": session,
                "usage": [
                    "input_tokens": 10,
                    "cache_read_input_tokens": 80,
                    "cache_creation_input_tokens": 20,
                    "output_tokens": 40,
                ],
                "modelUsage": [
                    "claude-sonnet-4-6": [
                        "inputTokens": 8,
                        "cacheReadInputTokens": 70,
                        "cacheCreationInputTokens": 18,
                        "outputTokens": 30,
                    ],
                    "claude-opus-4-6": [
                        "inputTokens": 2,
                        "cacheReadInputTokens": 10,
                        "cacheCreationInputTokens": 2,
                        "outputTokens": 10,
                    ],
                ],
            ])
        }
        try writeLog(path, lines: lines)
    }

    func writeNativeClaude(session: String) throws {
        let file = home.appendingPathComponent(".claude/projects/synthetic/\(session).jsonl")
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: [
            "type": "assistant", "timestamp": "2026-04-10T01:00:00Z", "sessionId": session,
            "requestId": "request-\(session)", "message": [
                "id": "message-\(session)", "model": "claude-sonnet-4-6",
                "usage": ["input_tokens": 10, "output_tokens": 2],
            ],
        ]).write(to: file)
    }

    func writeNativeCodex(session: String) throws {
        let file = home.appendingPathComponent(".codex/sessions/2026/04/10/\(session).jsonl")
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        let lines: [[String: Any]] = [
            [
                "timestamp": "2026-04-10T01:00:00Z",
                "type": "session_meta",
                "payload": ["id": session, "source": "cli"],
            ],
            ["timestamp": "2026-04-10T01:00:00Z", "type": "turn_context", "payload": ["model": "gpt-5"]],
            ["timestamp": "2026-04-10T01:00:01Z", "type": "event_msg", "payload": [
                "type": "token_count", "info": ["total_token_usage": ["input_tokens": 10, "output_tokens": 2]],
            ]],
        ]
        var data = Data()
        for line in lines {
            try data.append(JSONSerialization.data(withJSONObject: line))
            data.append(0x0A)
        }
        try data.write(to: file)
    }
}
