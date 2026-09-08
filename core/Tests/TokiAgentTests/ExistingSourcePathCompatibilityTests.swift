import Foundation
import TokiSyncProtocol
import TokiUsageCore
import XCTest
@testable import TokiAgentCore
@testable import TokiUsageReaders

/// Synthetic, source-derived fixtures. See docs/compatibility/fixture-provenance.md.
final class ExistingSourcePathCompatibilityTests: XCTestCase {
    private var root: URL!
    private let start = ISO8601DateFormatter().date(from: "2026-09-08T00:00:00Z")!
    private let end = ISO8601DateFormatter().date(from: "2026-09-09T00:00:00Z")!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("toki-common-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try FileManager.default.removeItem(at: root)
    }

    func test_primaryOverridesAndInjectedHomeAreAuthoritative() {
        let paths = LocalUsageReaderPaths(homeDirectory: root, environment: environment)
        XCTAssertEqual(paths.claudeProjects.path, root.path + "/custom-claude/projects")
        XCTAssertEqual(paths.codexDatabase.path, root.path + "/custom-codex/state_5.sqlite")
        XCTAssertEqual(paths.codexSessions.path, root.path + "/custom-codex/sessions")
        XCTAssertEqual(paths.codexArchivedSessions.path, root.path + "/custom-codex/archived_sessions")
        XCTAssertEqual(paths.geminiChats.path, root.path + "/custom-gemini/tmp")
        XCTAssertEqual(paths.gjcSessions.path, root.path + "/custom-gjc/sessions")
        XCTAssertEqual(paths.kimchiSessions.path, root.path + "/custom-kimchi/sessions")
    }

    func test_unsetBlankRelativeAndMalformedOverridesKeepLegacyDefaults() {
        let baseline = LocalUsageReaderPaths(homeDirectory: root, environment: [:])
        for value in ["", " \n\t", "relative", "~/private", "file:///tmp/private", "/tmp/invalid\0suffix"] {
            let invalid = Dictionary(uniqueKeysWithValues: environment.keys.map { ($0, value) })
            let paths = LocalUsageReaderPaths(homeDirectory: root, environment: invalid)
            XCTAssertEqual(paths.claudeProjects, baseline.claudeProjects, value)
            XCTAssertEqual(paths.codexDatabase, baseline.codexDatabase, value)
            XCTAssertEqual(paths.geminiChats, baseline.geminiChats, value)
            XCTAssertEqual(paths.gjcSessions, baseline.gjcSessions, value)
            XCTAssertEqual(paths.kimchiSessions, baseline.kimchiSessions, value)
        }
    }

    func test_absolutePathsPreserveLegitimateSpaces() {
        let directory = root.appendingPathComponent("state with spaces ")
        let paths = LocalUsageReaderPaths(homeDirectory: root, environment: ["CLAUDE_CONFIG_DIR": directory.path])
        XCTAssertEqual(paths.claudeProjects, directory.appendingPathComponent("projects"))
    }

    func test_gjcAllDocumentedRootsAndKimchiOverrideReachPublicReaders() async throws {
        var env = environment
        env["GJC_CONFIG_DIR"] = root.path + "/gjc-config"
        env["PI_CONFIG_DIR"] = root.path + "/pi-config"
        env["XDG_DATA_HOME"] = root.path + "/xdg"
        let roots = [
            "custom-gjc/sessions",
            "gjc-config/agent/sessions",
            "pi-config/agent/sessions",
            "xdg/gjc/sessions",
            ".gjc/agent/sessions",
        ]
        for (index, path) in roots.enumerated() {
            try write(piFixture(id: "session-\(index)"), to: path + "/project/child/usage.jsonl")
        }
        try write(piFixture(id: "kimchi-session"), to: "custom-kimchi/sessions/project/usage.jsonl")
        // A valid Kimchi override selects one root; the default is a different private profile.
        try write(piFixture(id: "unselected"), to: ".config/kimchi/harness/sessions/ignored.jsonl")
        let descriptors = LocalUsageReaderRegistry.agentDescriptors(home: root, environment: env)
        let gjc = try XCTUnwrap(descriptors.first { $0.name == "GJC" })
        XCTAssertEqual(Set(gjc.sourceLocations.map(\.url.path)), Set(roots.map { root.path + "/" + $0 }))
        let usage = try await gjc.reader.readUsage(from: start, to: end)
        // PI_CONFIG_DIR also selects Oh My Pi. That existing reader owns the shared physical root.
        let omp = try XCTUnwrap(descriptors.first { $0.name == OMPReader.sourceName })
        let ompUsage = try await omp.reader.readUsage(from: start, to: end)
        XCTAssertEqual(usage.inputTokens, 28)
        XCTAssertEqual(usage.outputTokens, 20)
        XCTAssertEqual(usage.tokenEvents.count, 4)
        XCTAssertEqual(usage.perModel["common-model"]?.totalTokens, 48)
        XCTAssertEqual(usage.cost, 1, accuracy: 0.000001)
        XCTAssertEqual(Set(usage.tokenEvents.compactMap { $0.attribution?.sessionID }).count, 4)
        XCTAssertEqual(ompUsage.totalTokens, 12)
        XCTAssertEqual(usage.totalTokens + ompUsage.totalTokens, 60)
        XCTAssertEqual(usage.cost + ompUsage.cost, 1.25, accuracy: 0.000001)
        XCTAssertEqual(usage.tokenEvents.count + ompUsage.tokenEvents.count, 5)
        let kimchi = try XCTUnwrap(descriptors.first { $0.name == "Kimchi" })
        let kimchiUsage = try await kimchi.reader.readUsage(from: start, to: end)
        XCTAssertEqual(kimchiUsage.totalTokens, 12)
    }

    func test_gjcAliasesDoNotCountTwiceAndLateRootsAreDiscovered() async throws {
        let target = root.appendingPathComponent("state")
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("alias"), withDestinationURL: target)
        let env = ["GJC_CONFIG_DIR": target.path, "PI_CONFIG_DIR": root.path + "/alias"]
        let reader = try reader("GJC", environment: env)
        let initialUsage = try await reader.readUsage(from: start, to: end)
        XCTAssertEqual(initialUsage.totalTokens, 0)
        try write(piFixture(id: "late"), to: "state/agent/sessions/project/usage.jsonl")
        let usage = try await reader.readUsage(from: start, to: end)
        let omp = try self.reader(OMPReader.sourceName, environment: env)
        let ompUsage = try await omp.readUsage(from: start, to: end)
        XCTAssertEqual(usage.totalTokens, 0)
        XCTAssertEqual(usage.tokenEvents.count, 0)
        XCTAssertEqual(usage.totalTokens + ompUsage.totalTokens, 12)
        XCTAssertEqual(usage.tokenEvents.count + ompUsage.tokenEvents.count, 1)
        XCTAssertEqual(usage.cost + ompUsage.cost, 0.25, accuracy: 0.000001)
    }

    func test_claudeTranscriptsWithoutProjectsAndReplicasKeepTokensAndWorkTime() async throws {
        let reader = try reader("Claude Code", environment: environment)
        let content = claudeFixture(request: "r1", timestamp: "2026-09-08T00:01:00Z") + "\n"
            + claudeFixture(request: "r2", timestamp: "2026-09-08T00:01:30Z")
        try write(content, to: "custom-claude/transcripts/session.jsonl")
        let transcripts = try await reader.readUsage(from: start, to: end)
        XCTAssertEqual(transcripts.totalTokens, 30)
        XCTAssertEqual(transcripts.tokenEvents.count, 2)
        try write(content, to: "custom-claude/projects/project/session.jsonl")
        let copies = try await reader.readUsage(from: start, to: end)
        XCTAssertEqual(copies.totalTokens, transcripts.totalTokens)
        XCTAssertEqual(copies.activeSeconds, transcripts.activeSeconds)
        XCTAssertEqual(copies.perModel["claude-sonnet-4-20250514"]?.totalTokens, 30)
        XCTAssertGreaterThan(copies.cost, 0)
        try write(
            claudeFixture(request: "excluded", timestamp: "2026-09-09T00:00:00Z"),
            to: "custom-claude/transcripts/end.jsonl")
        let bounded = try await reader.readUsage(from: start, to: end)
        XCTAssertEqual(bounded.totalTokens, 30)
    }

    func test_claudeRootSymlinkAndDefaultProfileStayScoped() async throws {
        let target = root.appendingPathComponent("custom-claude/projects")
        try write(claudeFixture(request: "selected"), to: "custom-claude/projects/session.jsonl")
        try FileManager.default.createSymbolicLink(
            at: root.appendingPathComponent("custom-claude/transcripts"), withDestinationURL: target)
        try write(claudeFixture(request: "private-default"), to: ".claude/projects/session.jsonl")
        let usage = try await reader("Claude Code", environment: environment).readUsage(from: start, to: end)
        XCTAssertEqual(usage.totalTokens, 15)
        XCTAssertEqual(usage.tokenEvents.count, 1)
    }

    func test_codexOverrideReadsArchiveWithoutDatabaseAndDeduplicatesCurrentCopy() async throws {
        let content = [
            #"{"timestamp":"2026-09-08T00:01:00Z","type":"session_meta","payload":"#,
            #"{"id":"common-codex","cwd":"/synthetic/project","source":"cli"}}"#,
            "\n",
            #"{"timestamp":"2026-09-08T00:01:00Z","type":"turn_context","payload":{"model":"gpt-5"}}"#,
            "\n",
            #"{"timestamp":"2026-09-08T00:01:01Z","type":"event_msg","payload":{"type":"token_count","info":"#,
            #"{"total_token_usage":{"input_tokens":100,"cached_input_tokens":10,"output_tokens":25,"#,
            #""reasoning_output_tokens":5,"total_tokens":125}}}}"#,
        ].joined()
        try write(content, to: "custom-codex/archived_sessions/rollout.jsonl")
        try write(content, to: "custom-codex/sessions/2026/09/08/rollout.jsonl")
        let reader = try reader("Codex", environment: environment)
        let usage = try await reader.readUsage(from: start, to: end)
        XCTAssertEqual(usage.totalTokens, 125)
        XCTAssertEqual(usage.tokenEvents.count, 1)
        XCTAssertEqual(usage.perModel["gpt-5"]?.totalTokens, 125)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.path + "/custom-codex/state_5.sqlite"))
    }
}

extension ExistingSourcePathCompatibilityTests {
    func test_geminiJSONLReplacesSameIDAndPreservesIndependentSessions() async throws {
        let header = #"{"sessionId":"s1","projectHash":"synthetic","startTime":"2026-09-08T00:00:00Z"}"#
        let old = geminiFixture(input: 10, output: 1)
            .replacingOccurrences(of: "gemini-2.5-pro", with: "gemini-3-pro-high")
        let updated = geminiFixture(input: 20, output: 2)
            .replacingOccurrences(of: "gemini-2.5-pro", with: "gemini-3-pro-high")
        try write(header + "\n" + old + "\n" + updated, to: "custom-gemini/tmp/project/chats/session-a.jsonl")
        // Same session/message in the legacy JSON representation is one request.
        try write(
            "{\"sessionId\":\"s1\",\"messages\":[\(updated)]}",
            to: "custom-gemini/tmp/project/chats/session-a.json")
        try write(
            header.replacingOccurrences(of: "s1", with: "s2") + "\n" + updated,
            to: "custom-gemini/tmp/project/chats/session-b.jsonl")
        let usage = try await reader("Gemini CLI", environment: environment).readUsage(from: start, to: end)
        XCTAssertEqual(usage.totalTokens, 44)
        XCTAssertEqual(usage.tokenEvents.count, 2)
        XCTAssertEqual(usage.perModel["gemini-3-pro-high"]?.totalTokens, 44)
        XCTAssertEqual(Set(usage.tokenEvents.compactMap { $0.attribution?.sessionID }), ["s1", "s2"])
        XCTAssertGreaterThan(usage.cost, 0)
    }

    func test_geminiJSONLPreservesExistingBucketContractAndHalfOpenDates() async throws {
        let content = [
            #"{"type":"init","model":"gemini-2.5-pro","session_id":"buckets"}"#,
            "\n",
            #"{"id":"one","type":"gemini","timestamp":"2026-09-08T00:00:00Z","tokens":"#,
            #"{"input":10,"output":2,"cached":3,"thoughts":4,"tool":1,"total":20}}"#,
            "\n",
            geminiFixture(input: 99, output: 1).replacingOccurrences(
                of: "2026-09-08T00:01:00Z", with: "2026-09-09T00:00:00Z"),
        ].joined()
        try write(content, to: "custom-gemini/tmp/project/chats/session.jsonl")
        let usage = try await reader("Gemini CLI", environment: environment).readUsage(from: start, to: end)
        XCTAssertEqual(usage.inputTokens, 10)
        XCTAssertEqual(usage.outputTokens, 3)
        XCTAssertEqual(usage.cacheReadTokens, 3)
        XCTAssertEqual(usage.reasoningTokens, 4)
        XCTAssertEqual(usage.totalTokens, 20)
        XCTAssertEqual(usage.tokenEvents.count, 1)
    }

    func test_geminiUnrecognizedJSONLIsDiagnosedAndEmptyStoreIsEmpty() async throws {
        let reader = try reader("Gemini CLI", environment: environment)
        let empty = try await reader.readUsage(from: start, to: end)
        XCTAssertEqual(empty.totalTokens, 0)
        for content in [#"{"stats":{"tokens":{"input":5}}}"#, #"{"type":"unknown","usage":{"input":5}}"#] {
            try write(content, to: "custom-gemini/tmp/project/chats/session.jsonl")
            do {
                _ = try await reader.readUsage(from: start, to: end)
                XCTFail("Unsupported schema must not look like successful no-data")
            } catch {
                XCTAssertTrue(error is LocalUsageReaderDiagnosticError)
            }
        }
    }

    func test_sourceSignatureAndSnapshotTrackLateOverrideFiles() async throws {
        let builder = AgentSnapshotBuilder(home: root, environment: environment)
        let config = try AgentConfiguration(bundle: AgentPairingBundle(
            hubURL: XCTUnwrap(URL(string: "https://hub.example.com")), deviceID: "device", deviceName: "Fixture",
            uploadToken: SnapshotCipher.randomToken(), encryptionKey: SnapshotCipher.generateKey(),
            retentionDays: 7, syncIntervalSeconds: 900))
        let now = start.addingTimeInterval(3600)
        var signature = try await builder.sourceSignature(configuration: config, now: now)
        for (path, content) in [
            ("custom-claude/transcripts/session.jsonl", claudeFixture(request: "late")),
            ("custom-gemini/tmp/project/chats/session.jsonl", geminiFixture(input: 10, output: 2)),
            ("custom-gjc/sessions/session.jsonl", piFixture(id: "gjc")),
            ("custom-kimchi/sessions/session.jsonl", piFixture(id: "kimchi")),
        ] {
            try write(content, to: path)
            let changed = try await builder.sourceSignature(configuration: config, now: now)
            XCTAssertNotEqual(signature, changed, path)
            signature = changed
        }
        let snapshot = try await builder.build(configuration: config, now: now)
        XCTAssertEqual(Set(snapshot.tokenEvents.map(\.source)), ["Claude Code", "Gemini CLI", "GJC", "Kimchi"])
        XCTAssertEqual(snapshot.tokenEvents.reduce(0) { $0 + $1.totalTokens }, 51)
        XCTAssertEqual(snapshot.tokenEvents.count, 4)
        let warm = try await builder.build(configuration: config, now: now)
        XCTAssertEqual(snapshot.tokenEvents, warm.tokenEvents)
        XCTAssertEqual(snapshot.activityEvents, warm.activityEvents)
    }

    func test_gjcIndependentRootsKeepCollidingSessionAndMessageIDs() async throws {
        try write(piFixture(id: "same-session"), to: "custom-gjc/sessions/session.jsonl")
        try write(piFixture(id: "same-session"), to: ".gjc/agent/sessions/session.jsonl")
        let usage = try await reader("GJC", environment: environment).readUsage(from: start, to: end)
        XCTAssertEqual(usage.totalTokens, 24)
        XCTAssertEqual(usage.tokenEvents.count, 2)
        XCTAssertEqual(usage.perModel["common-model"]?.totalTokens, 24)
        XCTAssertEqual(usage.cost, 0.5, accuracy: 0.000001)
        XCTAssertEqual(Set(usage.tokenEvents.compactMap { $0.attribution?.sessionID }).count, 2)
        XCTAssertEqual(Set(usage.activityEvents.map(\.streamID)).count, 2)
    }

    func test_geminiSessionSwitchKeepsMessageIDsAndResetsModelHint() async throws {
        let message = geminiFixture(input: 10, output: 2)
            .replacingOccurrences(of: "\"model\":\"gemini-2.5-pro\",", with: "")
        XCTAssertNoThrow(try JSONSerialization.jsonObject(with: Data(message.utf8)))
        let content = #"{"type":"init","session_id":"first","model":"gemini-2.5-pro"}"# + "\n"
            + message + "\n" + #"{"type":"init","session_id":"second"}"# + "\n" + message
        try write(content, to: "custom-gemini/tmp/project/chats/session.jsonl")
        let usage = try await reader("Gemini CLI", environment: environment).readUsage(from: start, to: end)
        XCTAssertEqual(usage.totalTokens, 24)
        XCTAssertEqual(usage.tokenEvents.count, 2)
        XCTAssertEqual(usage.perModel["gemini-2.5-pro"]?.totalTokens, 12)
        XCTAssertEqual(usage.perModel[UsageModelGrouping.mixedOrUnattributedKey]?.totalTokens, 12)
        let unknown = try XCTUnwrap(usage.tokenEvents.first { $0.attribution?.sessionID == "second" })
        XCTAssertNil(unknown.model)
        XCTAssertEqual(unknown.costIsKnown, false)
    }

    func test_geminiLaterRevisionMayDecreaseUsageAndMoveOutsideRange() async throws {
        let path = "custom-gemini/tmp/project/chats/session.jsonl"
        let header = #"{"sessionId":"revised"}"# + "\n"
        let old = geminiFixture(input: 20, output: 2)
        let revision = geminiFixture(input: 5, output: 1)
        try write(header + old + "\n" + revision, to: path)
        let reader = try reader("Gemini CLI", environment: environment)
        let smaller = try await reader.readUsage(from: start, to: end)
        XCTAssertEqual(smaller.totalTokens, 6)
        try write(header + old + "\n" + revision.replacingOccurrences(
            of: "2026-09-08T00:01:00Z", with: "2026-09-09T00:00:00Z"), to: path)
        let excluded = try await reader.readUsage(from: start, to: end)
        XCTAssertEqual(excluded.totalTokens, 0)
        XCTAssertTrue(excluded.tokenEvents.isEmpty)
    }

    func test_geminiLegacyJSONAndIdlessJSONLKeepIndependentUsage() async throws {
        let path = "custom-gemini/tmp/project/chats/legacy.json"
        try write(#"[{"usageMetadata":{"promptTokenCount":300,"candidatesTokenCount":40}}]"#, to: path)
        try FileManager.default.setAttributes(
            [.modificationDate: start.addingTimeInterval(60)], ofItemAtPath: root.appendingPathComponent(path).path)
        let message = geminiFixture(input: 10, output: 2).replacingOccurrences(of: "\"id\":\"m1\",", with: "")
        XCTAssertNoThrow(try JSONSerialization.jsonObject(with: Data(message.utf8)))
        try write(message + "\n" + message, to: "custom-gemini/tmp/project/chats/idless.jsonl")
        let usage = try await reader("Gemini CLI", environment: environment).readUsage(from: start, to: end)
        XCTAssertEqual(usage.totalTokens, 364)
        XCTAssertEqual(usage.tokenEvents.count, 3)
        XCTAssertEqual(usage.perModel[UsageModelGrouping.mixedOrUnattributedKey]?.totalTokens, 340)
    }
}

extension ExistingSourcePathCompatibilityTests {
    func test_geminiUnrelatedMetadataAndLegacyMessagesWithoutUsageRemainCompatible() async throws {
        try write("[]", to: "custom-gemini/tmp/project/chats/empty.json")
        try write(
            #"[{"role":"user","parts":[{"text":"synthetic"}]}]"#,
            to: "custom-gemini/tmp/project/chats/user-only.json")
        try write(#"{"role":"user"}"#, to: "custom-gemini/tmp/project/chats/single-user.json")
        try write(
            #"{"projectHash":"synthetic","settings":{"enabled":true}}"#,
            to: "custom-gemini/tmp/project/metadata.json")
        let legacy = "custom-gemini/tmp/project/chats/legacy.json"
        try write(
            #"[{"role":"user"},{"usageMetadata":{"promptTokenCount":3,"candidatesTokenCount":2}}]"#,
            to: legacy)
        try FileManager.default.setAttributes(
            [.modificationDate: start.addingTimeInterval(60)], ofItemAtPath: root.appendingPathComponent(legacy).path)
        let usage = try await reader("Gemini CLI", environment: environment).readUsage(from: start, to: end)
        XCTAssertEqual(usage.totalTokens, 5)
        XCTAssertEqual(usage.tokenEvents.count, 1)
    }

    func test_geminiMixedCanonicalAndUnsupportedTokenFieldsAreDiagnosed() async throws {
        let message = geminiFixture(input: 10, output: 2)
            .replacingOccurrences(of: #""input":10"#, with: #""input":10,"cached_tokens":3"#)
        try write(message, to: "custom-gemini/tmp/project/chats/session.jsonl")
        do {
            _ = try await reader("Gemini CLI", environment: environment).readUsage(from: start, to: end)
            XCTFail("An unsupported bucket must not silently lose tokens")
        } catch {
            XCTAssertTrue(error is LocalUsageReaderDiagnosticError)
        }
    }

    func test_claudeVersionThreeCacheIsReparsedBeforeAcceptingEmptyUsage() async throws {
        let path = "custom-claude/projects/session.jsonl"
        try write(#"{"type":"assistant","unfinished":"#, to: path)
        let file = root.appendingPathComponent(path).resolvingSymlinksInPath().standardizedFileURL
        let values = try file.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
        let cacheURL = root.appendingPathComponent("claude-cache.json")
        let entry: [String: Any] = try [
            "parserVersion": 3,
            "fileSize": XCTUnwrap(values.fileSize),
            "modifiedAt": XCTUnwrap(values.contentModificationDate).timeIntervalSince1970,
            "records": [],
        ]
        try JSONSerialization.data(withJSONObject: ["entries": [file.path: entry]]).write(to: cacheURL)
        let reader = ClaudeCodeReader(
            projectsURLOverride: file.deletingLastPathComponent(), usageCache: ClaudeUsageCache(cacheURL: cacheURL))
        do {
            _ = try await reader.readUsage(from: start, to: end)
            XCTFail("The old empty cache entry must not hide malformed source data")
        } catch {
            XCTAssertTrue(error is LocalUsageReaderDiagnosticError)
        }
    }

    func test_claudeOldMTimeIsReadAndNestedSymlinkIsNotFollowed() async throws {
        let path = "custom-claude/transcripts/session.jsonl"
        try write(claudeFixture(request: "old-mtime"), to: path)
        try FileManager.default.setAttributes(
            [.modificationDate: start.addingTimeInterval(-86400)], ofItemAtPath: root.appendingPathComponent(path).path)
        try write(claudeFixture(request: "outside"), to: "unselected/secret.jsonl")
        try FileManager.default.createSymbolicLink(
            at: root.appendingPathComponent("custom-claude/transcripts/escape"),
            withDestinationURL: root.appendingPathComponent("unselected"))
        let usage = try await reader("Claude Code", environment: environment).readUsage(from: start, to: end)
        XCTAssertEqual(usage.totalTokens, 15)
        XCTAssertEqual(usage.tokenEvents.count, 1)
    }

    func test_malformedClaudeAndTruncatedGeminiDoNotBecomeSuccessfulEmptyReads() async throws {
        for (name, path) in [
            ("Claude Code", "custom-claude/transcripts/session.jsonl"),
            ("Gemini CLI", "custom-gemini/tmp/project/chats/session.jsonl"),
        ] {
            try write(#"{"type":"assistant","unfinished":"#, to: path)
            do {
                _ = try await reader(name, environment: environment).readUsage(from: start, to: end)
                XCTFail("Malformed \(name) data must be diagnosed")
            } catch {
                XCTAssertTrue(error is LocalUsageReaderDiagnosticError)
            }
        }
    }

    func test_geminiJSONLLineBudgetAndCancellationAreEnforced() async throws {
        try write(
            String(repeating: "x", count: PiCompatibleReadLimits.default.maximumLineBytes + 1),
            to: "custom-gemini/tmp/project/chats/session.jsonl")
        let reader = try reader("Gemini CLI", environment: environment)
        do {
            _ = try await reader.readUsage(from: start, to: end)
            XCTFail("Oversized JSONL record must fail before decoding")
        } catch {
            guard case PiCompatibleReaderError.lineTooLong = error else {
                return XCTFail("Unexpected error: \(type(of: error))")
            }
        }
        let startDate = start
        let endDate = end
        let task = Task {
            while !Task.isCancelled {
                await Task.yield()
            }
            return try await reader.readUsage(from: startDate, to: endDate)
        }
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("Cancelled reader must not report successful empty usage")
        } catch {
            XCTAssertTrue(error is CancellationError)
        }
    }

    func test_preexistingCommonOverridePoliciesRemainCompatible() {
        let paths = LocalUsageReaderPaths(homeDirectory: root, environment: [
            "XDG_DATA_HOME": root.path + "/data", "XDG_CONFIG_HOME": root.path + "/config",
            "PI_CODING_AGENT_DIR": root.path + "/pi", "PI_CODING_AGENT_SESSION_DIR": root.path + "/pi-sessions",
            "PI_CONFIG_DIR": root.path + "/omp", "OMP_PROFILE": "work",
            "KIMI_SHARE_DIR": root.path + "/kimi", "KIMI_CODE_HOME": root.path + "/kimi-code",
            "QWEN_HOME": root.path + "/qwen", "QWEN_RUNTIME_DIR": root.path + "/qwen-runtime",
            "SENPI_CODING_AGENT_DIR": root.path + "/senpi", "SENPI_CODING_AGENT_SESSION_DIR": root.path + "/children",
            "PWD": root.path + "/project", "COPILOT_OTEL_FILE_EXPORTER_PATH": root.path + "/copilot.jsonl",
        ])
        XCTAssertEqual(paths.ampThreads.path, root.path + "/data/amp/threads")
        XCTAssertEqual(paths.piSessions.path, root.path + "/pi-sessions")
        XCTAssertEqual(paths.ompSessionRoots.map(\.path), [root.path + "/omp/profiles/work/agent/sessions"])
        XCTAssertEqual(paths.kimchiSessions.path, root.path + "/config/kimchi/harness/sessions")
        XCTAssertEqual(
            paths.kimiCLISessions.map(\.path), [root.path + "/.kimi/sessions", root.path + "/kimi/sessions"])
        XCTAssertEqual(paths.kimiCodeSessions.count, 2)
        XCTAssertEqual(paths.qwenProjects.count, 3)
        XCTAssertTrue(paths.senpiSessionDirectories.contains(root.appendingPathComponent("senpi/sessions")))
        XCTAssertTrue(paths.senpiSessionDirectories.contains(root.appendingPathComponent("children")))
        XCTAssertTrue(
            paths.senpiSessionDirectories.contains(root.appendingPathComponent("project/.omo/senpi-task/children")))
        XCTAssertEqual(paths.copilotOTELExporterFile?.path, root.path + "/copilot.jsonl")
    }
}

private extension ExistingSourcePathCompatibilityTests {
    var environment: [String: String] {
        [
            "CLAUDE_CONFIG_DIR": root.path + "/custom-claude",
            "CODEX_HOME": root.path + "/custom-codex",
            "GEMINI_CLI_HOME": root.path + "/custom-gemini",
            "GJC_CODING_AGENT_DIR": root.path + "/custom-gjc",
            "KIMCHI_CODING_AGENT_DIR": root.path + "/custom-kimchi",
        ]
    }

    func reader(_ name: String, environment: [String: String]) throws -> any TokenReader {
        try XCTUnwrap(LocalUsageReaderRegistry.agentDescriptors(home: root, environment: environment)
            .first { $0.name == name }?.reader)
    }

    func write(_ content: String, to path: String) throws {
        let url = root.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data((content + "\n").utf8).write(to: url)
    }

    func piFixture(id: String) -> String {
        [
            "{\"type\":\"session\",\"id\":\"\(id)\",\"timestamp\":\"2026-09-08T00:00:00Z\"}\n",
            #"{"type":"message","id":"m1","timestamp":"2026-09-08T00:01:00Z","message":"#,
            #"{"role":"assistant","model":"common-model","provider":"synthetic","usage":"#,
            #"{"input":7,"output":5,"cost":{"total":0.25}}}}"#,
        ].joined()
    }

    func claudeFixture(request: String, timestamp: String = "2026-09-08T00:01:00Z") -> String {
        [
            "{\"type\":\"assistant\",\"requestId\":\"\(request)\",\"timestamp\":\"\(timestamp)\",",
            #""message":{"model":"claude-sonnet-4-20250514","usage":"#,
            #"{"input_tokens":10,"output_tokens":2,"cache_read_input_tokens":3}}}"#,
        ].joined()
    }

    func geminiFixture(input: Int, output: Int) -> String {
        [
            #"{"type":"gemini","id":"m1","timestamp":"2026-09-08T00:01:00Z","model":"gemini-2.5-pro","tokens":"#,
            #"{"input":\#(input),"output":\#(output)}}"#,
        ].joined()
    }
}
