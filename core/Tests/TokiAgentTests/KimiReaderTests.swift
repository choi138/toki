import Foundation
import TokiUsageCore
import XCTest
@testable import TokiUsageReaders

final class KimiReaderTests: XCTestCase {
    private let startDate = Date(timeIntervalSince1970: 1_770_000_000)
    private let endDate = Date(timeIntervalSince1970: 1_780_000_000)

    func test_kimiCLIMapsStatusUsageAndKeepsLargestMessageSnapshot() {
        let lines = [
            #"{"type":"metadata","protocol_version":"1.3"}"#,
            #"{"timestamp":1770983410.0,"message":{"type":"StatusUpdate","payload":{"token_usage":{"# +
                #""input_other":100,"output":20,"input_cache_read":5,"input_cache_creation":2},"# +
                #""message_id":"message-1"}}}"#,
            #"{"timestamp":1770983420.0,"message":{"type":"StatusUpdate","payload":{"token_usage":{"# +
                #""input_other":140,"output":35,"input_cache_read":8,"input_cache_creation":3},"# +
                #""message_id":"message-1"}}}"#,
            #"{"timestamp":1770983430.0,"message":{"type":"StatusUpdate","payload":{"token_usage":{"# +
                #""input_other":40,"output":10,"input_cache_read":1,"input_cache_creation":0},"# +
                #""message_id":"message-2"}}}"#,
        ]

        let usage = KimiCLIReader.usage(
            fromJSONLLines: lines,
            streamID: "/tmp/.kimi/sessions/workspace-a/session-cli/wire.jsonl",
            model: "kimi-k2.5",
            from: startDate,
            to: endDate)

        XCTAssertEqual(usage.inputTokens, 180)
        XCTAssertEqual(usage.outputTokens, 45)
        XCTAssertEqual(usage.cacheReadTokens, 9)
        XCTAssertEqual(usage.cacheWriteTokens, 3)
        XCTAssertEqual(usage.reasoningTokens, 0)
        XCTAssertEqual(usage.cost, 0)
        XCTAssertEqual(usage.tokenEvents.map(\.source), ["Kimi CLI", "Kimi CLI"])
        XCTAssertEqual(usage.tokenEvents.map(\.model), ["kimi-k2.5", "kimi-k2.5"])
        XCTAssertEqual(usage.tokenEvents.map(\.provider), ["moonshot", "moonshot"])
        XCTAssertTrue(usage.tokenEvents.allSatisfy { $0.costIsKnown == false })
        XCTAssertEqual(
            usage.tokenEvents.map(\.attribution?.sessionID),
            ["session-cli", "session-cli"])
        XCTAssertEqual(
            usage.tokenEvents.map(\.attribution?.projectName),
            ["workspace-a", "workspace-a"])
        XCTAssertEqual(usage.activityEvents.count, 2)
    }

    func test_kimiCLIReadsCurrentTOMLModelAndProvider() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
            .appendingPathComponent(".kimi", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let sessions = root.appendingPathComponent("sessions", isDirectory: true)
        let session = sessions
            .appendingPathComponent("workspace", isDirectory: true)
            .appendingPathComponent("session", isDirectory: true)
        try FileManager.default.createDirectory(at: session, withIntermediateDirectories: true)
        let config = [
            #"default_model = "custom-kimi""#,
            "",
            "[providers.openrouter]",
            #"type = "openai_compatible""#,
            #"base_url = "https://openrouter.ai/api/v1""#,
            #"api_key = "unused""#,
            "",
            "[models.custom-kimi]",
            #"provider = "openrouter""#,
            #"model = "moonshotai/kimi-k2.5""#,
            "max_context_size = 262144",
        ].joined(separator: "\n")
        try config.write(
            to: root.appendingPathComponent("config.toml"),
            atomically: true,
            encoding: .utf8)
        let wire = #"{"timestamp":1770983410.0,"message":{"type":"StatusUpdate","payload":{"# +
            #""token_usage":{"input_other":10,"output":2},"message_id":"valid"}}}"#
        try wire.write(
            to: session.appendingPathComponent("wire.jsonl"),
            atomically: true,
            encoding: .utf8)

        let usage = try await KimiCLIReader(sessionRoots: [sessions])
            .readUsage(from: startDate, to: endDate)

        XCTAssertEqual(usage.tokenEvents.first?.model, "moonshotai/kimi-k2.5")
        XCTAssertEqual(usage.tokenEvents.first?.provider, "openrouter")
    }

    func test_kimiCodeCountsOnlyTurnUsageRecordsAndUsesConcreteRequestModel() {
        let lines = [
            #"{"type":"llm.request","model":"moonshot/kimi-k2.6"}"#,
            #"{"type":"usage.record","model":"__kimi_env_model__","usage":{"inputOther":200,"# +
                #""output":60,"inputCacheRead":20,"inputCacheCreation":4},"usageScope":"turn","# +
                #""time":1770983410000}"#,
            #"{"type":"step.end","model":"moonshot/kimi-k2.6","usage":{"inputOther":200,"# +
                #""output":60,"inputCacheRead":20,"inputCacheCreation":4},"usageScope":"turn","# +
                #""time":1770983410000}"#,
            #"{"type":"usage.record","model":"moonshot/kimi-k2.6","usage":{"inputOther":999,"# +
                #""output":999},"usageScope":"session","time":1770983420000}"#,
        ]

        let usage = KimiCodeReader.usage(
            fromJSONLLines: lines,
            streamID: "/tmp/.kimi-code/sessions/workspace-b/session-code/agents/main/wire.jsonl",
            from: startDate,
            to: endDate)

        XCTAssertEqual(usage.inputTokens, 200)
        XCTAssertEqual(usage.outputTokens, 60)
        XCTAssertEqual(usage.cacheReadTokens, 20)
        XCTAssertEqual(usage.cacheWriteTokens, 4)
        XCTAssertEqual(usage.reasoningTokens, 0)
        XCTAssertEqual(usage.cost, 0)
        XCTAssertEqual(usage.tokenEvents.map(\.source), ["Kimi Code"])
        XCTAssertEqual(usage.tokenEvents.first?.model, "moonshot/kimi-k2.6")
        XCTAssertEqual(usage.tokenEvents.first?.provider, "moonshot")
        XCTAssertEqual(usage.tokenEvents.first?.costIsKnown, false)
        XCTAssertEqual(usage.tokenEvents.first?.attribution?.sessionID, "session-code")
        XCTAssertEqual(usage.tokenEvents.first?.attribution?.projectName, "workspace-b")
        XCTAssertEqual(usage.activityEvents.count, 1)
    }

    func test_kimiReadersSkipMalformedAndTruncatedRecords() {
        let cliUsage = KimiCLIReader.usage(
            fromJSONLLines: [
                #"{"timestamp":1770983410.0,"message":{"type":"StatusUpdate","payload":{"# +
                    #""token_usage":{"input_other":10,"output":2},"message_id":"valid"}}}"#,
                "not-json",
                #"{"timestamp":1770983420.0,"message":{"type":"StatusUpdate""#,
            ],
            streamID: "/tmp/.kimi/sessions/workspace/session/wire.jsonl",
            model: nil,
            from: startDate,
            to: endDate)
        let codeUsage = KimiCodeReader.usage(
            fromJSONLLines: [
                #"{"type":"usage.record","model":"kimi-k2","usage":{"inputOther":12,"output":3},"# +
                    #""usageScope":"turn","time":1770983410000}"#,
                #"{"type":"usage.record","model":"kimi-k2","usage":"#,
            ],
            streamID: "/tmp/.kimi-code/sessions/workspace/session/agents/main/wire.jsonl",
            from: startDate,
            to: endDate)

        XCTAssertEqual(cliUsage.totalTokens, 12)
        XCTAssertEqual(codeUsage.totalTokens, 15)
    }
}

extension KimiReaderTests {
    func test_kimiCLIKeepsSameNamedSessionsFromDifferentWorkspaces() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let sessions = root.appendingPathComponent("sessions", isDirectory: true)
        for (workspace, tokens) in [("workspace-a", 10), ("workspace-b", 20)] {
            let file = sessions
                .appendingPathComponent(workspace, isDirectory: true)
                .appendingPathComponent("session", isDirectory: true)
                .appendingPathComponent("wire.jsonl")
            try FileManager.default.createDirectory(
                at: file.deletingLastPathComponent(),
                withIntermediateDirectories: true)
            let line =
                #"{"timestamp":1770983410.0,"message":{"type":"StatusUpdate","payload":{"# +
                #""token_usage":{"input_other":"# + String(tokens) +
                #","output":0},"message_id":"same-message"}}}"#
            try line.write(to: file, atomically: true, encoding: .utf8)
        }

        let usage = try await KimiCLIReader(sessionRoots: [sessions])
            .readUsage(from: startDate, to: endDate)

        XCTAssertEqual(usage.totalTokens, 30)
        XCTAssertEqual(Set(usage.tokenEvents.compactMap(\.attribution?.projectName)), [
            "workspace-a",
            "workspace-b",
        ])
    }

    func test_kimiCLIDeduplicatesMessageWithoutIDAcrossDivergentReplicas() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let defaultRoot = root.appendingPathComponent("default", isDirectory: true)
        let overrideRoot = root.appendingPathComponent("override", isDirectory: true)
        let relativePath = "workspace/session/wire.jsonl"
        let defaultWire = defaultRoot.appendingPathComponent(relativePath)
        let overrideWire = overrideRoot.appendingPathComponent(relativePath)
        for file in [defaultWire, overrideWire] {
            try FileManager.default.createDirectory(
                at: file.deletingLastPathComponent(),
                withIntermediateDirectories: true)
        }
        let event =
            #"{"timestamp":1770983410.0,"message":{"type":"StatusUpdate","payload":{"# +
            #""token_usage":{"input_other":10,"output":0}}}}"#
        try event.write(to: defaultWire, atomically: true, encoding: .utf8)
        try [#"{"type":"metadata"}"#, event].joined(separator: "\n")
            .write(to: overrideWire, atomically: true, encoding: .utf8)

        let usage = try await KimiCLIReader(sessionRoots: [defaultRoot, overrideRoot])
            .readUsage(from: startDate, to: endDate)

        XCTAssertEqual(usage.totalTokens, 10)
        XCTAssertEqual(usage.tokenEvents.count, 1)
    }

    func test_kimiReadersSkipOverflowingTokenRecords() {
        let overflowingCLI =
            #"{"timestamp":1770983410.0,"message":{"type":"StatusUpdate","payload":{"token_usage":{"input_other":"# +
            String(Int.max) +
            #","output":1},"message_id":"overflow"}}}"#
        let validCLI =
            #"{"timestamp":1770983420.0,"message":{"type":"StatusUpdate","payload":{"# +
            #""token_usage":{"input_other":10,"output":2},"message_id":"valid"}}}"#
        let overflowingCode =
            #"{"type":"usage.record","model":"kimi-k2","usage":{"inputOther":"# +
            String(Int.max) +
            #","output":1},"usageScope":"turn","time":1770983410000}"#
        let validCode =
            #"{"type":"usage.record","model":"kimi-k2","usage":{"inputOther":12,"output":3},"# +
            #""usageScope":"turn","time":1770983420000}"#

        let cliUsage = KimiCLIReader.usage(
            fromJSONLLines: [overflowingCLI, validCLI],
            streamID: "/tmp/.kimi/sessions/workspace/session/wire.jsonl",
            model: nil,
            from: startDate,
            to: endDate)
        let codeUsage = KimiCodeReader.usage(
            fromJSONLLines: [overflowingCode, validCode],
            streamID: "/tmp/.kimi-code/sessions/workspace/session/agents/main/wire.jsonl",
            from: startDate,
            to: endDate)

        XCTAssertEqual(cliUsage.totalTokens, 12)
        XCTAssertEqual(codeUsage.totalTokens, 15)
    }

    func test_kimiCodeDeduplicatesDivergentReplicasByStableEventContent() async throws {
        let temporaryRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: temporaryRoot) }

        let defaultRoot = temporaryRoot.appendingPathComponent("default", isDirectory: true)
        let overrideRoot = temporaryRoot.appendingPathComponent("override", isDirectory: true)
        let relativeWirePath = "workspace/session/agents/main/wire.jsonl"
        let defaultWire = defaultRoot.appendingPathComponent(relativeWirePath)
        let overrideWire = overrideRoot.appendingPathComponent(relativeWirePath)
        try FileManager.default.createDirectory(
            at: defaultWire.deletingLastPathComponent(),
            withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: overrideWire.deletingLastPathComponent(),
            withIntermediateDirectories: true)

        let eventA =
            #"{"type":"usage.record","model":"kimi-k2","usage":{"inputOther":10,"output":0},"# +
            #""usageScope":"turn","time":1770983410000}"#
        let eventB =
            #"{"type":"usage.record","model":"kimi-k2","usage":{"inputOther":20,"output":0},"# +
            #""usageScope":"turn","time":1770983420000}"#
        let eventC =
            #"{"type":"usage.record","model":"kimi-k2","usage":{"inputOther":30,"output":0},"# +
            #""usageScope":"turn","time":1770983430000}"#
        try [eventA, eventB].joined(separator: "\n")
            .write(to: defaultWire, atomically: true, encoding: .utf8)
        try [eventB, eventC].joined(separator: "\n")
            .write(to: overrideWire, atomically: true, encoding: .utf8)

        let usage = try await KimiCodeReader(sessionRoots: [defaultRoot, overrideRoot])
            .readUsage(from: startDate, to: endDate)

        XCTAssertEqual(usage.totalTokens, 60)
        XCTAssertEqual(usage.tokenEvents.count, 3)
    }

    func test_kimiCodeKeepsSameNamedSessionsFromDifferentWorkspaces() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let event =
            #"{"type":"usage.record","model":"kimi-k2","usage":{"inputOther":10,"output":0},"# +
            #""usageScope":"turn","time":1770983410000}"#
        for workspace in ["workspace-a", "workspace-b"] {
            let file = root
                .appendingPathComponent(workspace, isDirectory: true)
                .appendingPathComponent("session/agents/main", isDirectory: true)
                .appendingPathComponent("wire.jsonl")
            try FileManager.default.createDirectory(
                at: file.deletingLastPathComponent(),
                withIntermediateDirectories: true)
            try event.write(to: file, atomically: true, encoding: .utf8)
        }

        let usage = try await KimiCodeReader(sessionRoots: [root])
            .readUsage(from: startDate, to: endDate)

        XCTAssertEqual(usage.totalTokens, 20)
        XCTAssertEqual(Set(usage.tokenEvents.compactMap(\.attribution?.projectName)), [
            "workspace-a",
            "workspace-b",
        ])
    }

    func test_kimiDiscoveryRootsUseAbsoluteOverridesWithoutDuplicatingDefaults() {
        let paths = LocalUsageReaderPaths(
            homeDirectory: URL(fileURLWithPath: "/tmp/toki-home"),
            environment: [
                "KIMI_SHARE_DIR": "/tmp/toki-home/.kimi",
                "KIMI_CODE_HOME": "/tmp/kimi-code",
            ])

        XCTAssertEqual(paths.kimiCLISessions.map(\.path), ["/tmp/toki-home/.kimi/sessions"])
        XCTAssertEqual(
            paths.kimiCodeSessions.map(\.path),
            ["/tmp/toki-home/.kimi-code/sessions", "/tmp/kimi-code/sessions"])
    }
}
