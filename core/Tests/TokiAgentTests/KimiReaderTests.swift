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

    func test_kimiCodePartialReplicaDoesNotShiftEventIdentity() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("toki-kimi-replica-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let firstRoot = root.appendingPathComponent("first")
        let secondRoot = root.appendingPathComponent("second")
        let relativePath = "workspace/session/agents/main/wire.jsonl"
        let firstFile = firstRoot.appendingPathComponent(relativePath)
        let secondFile = secondRoot.appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(
            at: firstFile.deletingLastPathComponent(),
            withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: secondFile.deletingLastPathComponent(),
            withIntermediateDirectories: true)
        let firstEvent = [
            #"{"type":"usage.record","model":"kimi-k2","usage":{"inputOther":10},"#,
            #""usageScope":"turn","time":1770983410000}"#,
        ].joined()
        let secondEvent = [
            #"{"type":"usage.record","model":"kimi-k2","usage":{"inputOther":20},"#,
            #""usageScope":"turn","time":1770983420000}"#,
        ].joined()
        try Data([firstEvent, secondEvent].joined(separator: "\n").utf8).write(to: firstFile)
        try Data(secondEvent.utf8).write(to: secondFile)

        let usage = try await KimiCodeReader(sessionRoots: [firstRoot, secondRoot])
            .readUsage(from: startDate, to: endDate)

        XCTAssertEqual(usage.inputTokens, 30)
        XCTAssertEqual(usage.tokenEvents.count, 2)
    }

    func test_kimiCLIIdlessPartialReplicaDoesNotShiftEventIdentity() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("toki-kimi-cli-replica-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let firstRoot = root.appendingPathComponent("first")
        let secondRoot = root.appendingPathComponent("second")
        let relativePath = "workspace/session/wire.jsonl"
        let firstFile = firstRoot.appendingPathComponent(relativePath)
        let secondFile = secondRoot.appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(
            at: firstFile.deletingLastPathComponent(),
            withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: secondFile.deletingLastPathComponent(),
            withIntermediateDirectories: true)
        let firstEvent =
            #"{"timestamp":1770983410.0,"message":{"type":"StatusUpdate","payload":{"# +
            #""token_usage":{"input_other":10}}}}"#
        let secondEvent =
            #"{"timestamp":1770983420.0,"message":{"type":"StatusUpdate","payload":{"# +
            #""token_usage":{"input_other":20}}}}"#
        try Data([firstEvent, secondEvent].joined(separator: "\n").utf8).write(to: firstFile)
        try Data(secondEvent.utf8).write(to: secondFile)

        let usage = try await KimiCLIReader(sessionRoots: [firstRoot, secondRoot])
            .readUsage(from: startDate, to: endDate)

        XCTAssertEqual(usage.inputTokens, 30)
        XCTAssertEqual(usage.tokenEvents.count, 2)
    }

    func test_kimiCodeSameSessionAcrossWorkspacesRemainsIndependent() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("toki-kimi-code-workspaces-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let relativePath = "session/agents/main/wire.jsonl"
        let firstFile = root.appendingPathComponent("workspace-a/\(relativePath)")
        let secondFile = root.appendingPathComponent("workspace-b/\(relativePath)")
        try FileManager.default.createDirectory(
            at: firstFile.deletingLastPathComponent(),
            withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: secondFile.deletingLastPathComponent(),
            withIntermediateDirectories: true)
        let event = [
            #"{"type":"usage.record","model":"kimi-k2","usage":{"inputOther":10},"#,
            #""usageScope":"turn","time":1770983410000}"#,
        ].joined()
        try Data(event.utf8).write(to: firstFile)
        try Data(event.utf8).write(to: secondFile)

        let usage = try await KimiCodeReader(sessionRoots: [root])
            .readUsage(from: startDate, to: endDate)

        XCTAssertEqual(usage.inputTokens, 20)
        XCTAssertEqual(usage.tokenEvents.count, 2)
        XCTAssertEqual(
            Set(usage.tokenEvents.compactMap(\.attribution?.projectName)),
            ["workspace-a", "workspace-b"])
    }
}
