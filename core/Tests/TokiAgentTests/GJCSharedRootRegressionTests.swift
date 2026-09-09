import Foundation
import TokiUsageCore
import XCTest
@testable import TokiUsageReaders

final class GJCSharedRootRegressionTests: XCTestCase {
    private var root: URL!
    private let start = ISO8601DateFormatter().date(from: "2026-09-08T00:00:00Z")!
    private let end = ISO8601DateFormatter().date(from: "2026-09-09T00:00:00Z")!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("toki-gjc-shared-\(UUID())")
        try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try FileManager.default.removeItem(at: root)
    }

    func test_sharedOMPAndPiRetainHeaderlessModellessAndTaskUsage() async throws {
        try writeFixtures()
        let standalone = try await GJCReader(sessionsURLOverride: sessions).readUsage(from: start, to: end)
        XCTAssertEqual(standalone.totalTokens, 45)
        for environment in [
            ["PI_CONFIG_DIR": root.appendingPathComponent(".gjc").path],
            ["PI_CODING_AGENT_SESSION_DIR": sessions.path],
            [
                "PI_CONFIG_DIR": root.appendingPathComponent(".gjc").path,
                "PI_CODING_AGENT_SESSION_DIR": sessions.path,
            ],
        ] {
            let readers = LocalUsageReaderRegistry.readers(home: root, environment: environment)
            var combined = RawTokenUsage()
            var gjc = RawTokenUsage()
            for reader in readers where ["GJC", "Pi", "Oh My Pi", "Pi / Oh My Pi"].contains(reader.name) {
                let usage = try await reader.readUsage(from: start, to: end)
                if reader.name == "GJC" { gjc = usage }
                combined.inputTokens += usage.inputTokens
                combined.outputTokens += usage.outputTokens
                combined.tokenEvents += usage.tokenEvents
            }
            XCTAssertEqual(gjc.totalTokens, 33)
            XCTAssertEqual(combined.totalTokens, standalone.totalTokens)
            XCTAssertEqual(combined.tokenEvents.count, 4)
            XCTAssertEqual(combined.inputTokens, standalone.inputTokens)
            XCTAssertEqual(combined.outputTokens, standalone.outputTokens)
        }
    }

    func test_piLeadingTitleRejectionKeepsGJCUsage() async throws {
        try write(
            "{\"type\":\"title\",\"title\":\"Synthetic\"}\n" + header("title") + message("title", input: 8, output: 4),
            name: "title")
        let readers = LocalUsageReaderRegistry.readers(
            home: root, environment: ["PI_CODING_AGENT_SESSION_DIR": sessions.path])
        let gjc = try XCTUnwrap(readers.first { $0.name == "GJC" })
        let pi = try XCTUnwrap(readers.first { $0.name == "Pi" })
        let gjcUsage = try await gjc.readUsage(from: start, to: end)
        let piUsage = try await pi.readUsage(from: start, to: end)
        XCTAssertEqual(gjcUsage.totalTokens, 12)
        XCTAssertEqual(piUsage.totalTokens, 0)
    }

    func test_liveSharedRootAliasRetargetChangesOnlyCommonRecordOwnership() async throws {
        try writeFixtures()
        let unrelated = root.appendingPathComponent("unrelated")
        try FileManager.default.createDirectory(at: unrelated, withIntermediateDirectories: true)
        let alias = root.appendingPathComponent("selected")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: unrelated)
        let gjc = try XCTUnwrap(LocalUsageReaderRegistry.readers(
            home: root, environment: ["PI_CONFIG_DIR": alias.path]).first { $0.name == "GJC" })
        for (target, expected) in [(unrelated, 45), (root.appendingPathComponent(".gjc"), 33), (unrelated, 45)] {
            try FileManager.default.removeItem(at: alias)
            try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: target)
            let usage = try await gjc.readUsage(from: start, to: end)
            XCTAssertEqual(usage.totalTokens, expected)
        }
    }

    private var sessions: URL {
        root.appendingPathComponent(".gjc/agent/sessions")
    }

    private func writeFixtures() throws {
        try write(message("headerless", input: 10, output: 5), name: "headerless")
        try write(header("modelless") + message("modelless", input: 7, output: 3, model: false), name: "modelless")
        try write(header("common") + message("common", input: 8, output: 4), name: "common")
        let task = #"{"type":"message","id":"task","timestamp":"2026-09-08T00:01:00Z","message":"#
            + #"{"role":"toolResult","toolName":"task","details":{"usage":{"input":6,"output":2}}}}"#
        try write(header("task") + task, name: "task")
    }

    private func header(_ id: String) -> String {
        "{\"type\":\"session\",\"id\":\"\(id)\"}\n"
    }

    private func message(_ id: String, input: Int, output: Int, model: Bool = true) -> String {
        let modelField = model ? "\"model\":\"synthetic-model\"," : ""
        return "{\"type\":\"message\",\"id\":\"\(id)\",\"timestamp\":\"2026-09-08T00:01:00Z\",\"message\":"
            + "{\"role\":\"assistant\",\(modelField)\"usage\":{\"input\":\(input),\"output\":\(output)}}}"
    }

    private func write(_ content: String, name: String) throws {
        try Data((content + "\n").utf8).write(to: sessions.appendingPathComponent(name + ".jsonl"))
    }
}
