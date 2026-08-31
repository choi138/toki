import Foundation
import XCTest
@testable import TokiAgentCore
@testable import TokiUsageReaders

final class CopilotCLIAgentIntegrationTests: XCTestCase {
    func test_oversizedIntegerTokenTotalIsIgnoredWithoutTrapping() {
        let line =
            #"{"type":"span","name":"chat sentinel","startTime":[1784199940,0],"attributes":{"# +
            #""gen_ai.operation.name":"chat","gen_ai.usage.input_tokens":9223372036854775807,"# +
            #""gen_ai.usage.output_tokens":1}}"#

        let usage = CopilotCLIReader.usage(
            fromJSONLLines: [line],
            streamID: "fixture.jsonl",
            from: Date(timeIntervalSince1970: 1_784_199_000),
            to: Date(timeIntervalSince1970: 1_784_201_000))

        XCTAssertEqual(usage.totalTokens, 0)
        XCTAssertTrue(usage.tokenEvents.isEmpty)
    }

    func test_oversizedFloatingPointTokenValueIsIgnoredWithoutTrapping() throws {
        let line =
            #"{"type":"span","name":"chat sentinel","attributes":{"# +
            #""gen_ai.operation.name":"chat","gen_ai.usage.input_tokens":1e100,"# +
            #""gen_ai.usage.output_tokens":3}}"#
        let data = Data(line.utf8)

        let record = try JSONDecoder().decode(CopilotOTELRecord.self, from: data)

        XCTAssertNil(record.attributes.inputTokens)
        XCTAssertEqual(record.attributes.outputTokens, 3)
    }

    func test_defaultAgentRegistryExportsCopilotUsageAndProvider() async throws {
        let now = Date(timeIntervalSince1970: 1_784_200_000)
        let fixture = try AgentSnapshotFixture()
        defer { fixture.remove() }
        let otelDirectory = fixture.root.appendingPathComponent(".copilot/otel")
        try FileManager.default.createDirectory(at: otelDirectory, withIntermediateDirectories: true)
        let line =
            #"{"type":"span","traceId":"trace-agent","spanId":"span-agent","# +
            #""name":"chat sentinel","startTime":[1784199940,0],"attributes":{"# +
            #""gen_ai.operation.name":"chat","gen_ai.response.id":"response-agent","# +
            #""gen_ai.response.model":"claude-sonnet-4.6","gen_ai.provider.name":"github","# +
            #""gen_ai.usage.input_tokens":21,"gen_ai.usage.output_tokens":8}}"#
        try line.write(
            to: otelDirectory.appendingPathComponent("usage.jsonl"),
            atomically: true,
            encoding: .utf8)
        let builder = AgentSnapshotBuilder(home: fixture.root, environment: [:])

        let snapshot = try await builder.build(configuration: fixture.configuration, now: now)
        let event = try XCTUnwrap(
            snapshot.tokenEvents.first { $0.source == CopilotCLIReader.sourceName })

        XCTAssertEqual(event.model, "claude-sonnet-4.6")
        XCTAssertEqual(event.provider, "github")
        XCTAssertEqual(event.inputTokens, 21)
        XCTAssertEqual(event.outputTokens, 8)
    }

    func test_sourceSignatureTracksCopilotDefaultAndExporterFiles() async throws {
        let fixture = try AgentSnapshotFixture()
        defer { fixture.remove() }
        let exporterFile = fixture.root.appendingPathComponent("export/copilot.jsonl")
        let builder = AgentSnapshotBuilder(
            home: fixture.root,
            environment: ["COPILOT_OTEL_FILE_EXPORTER_PATH": exporterFile.path])
        let initial = try await builder.sourceSignature(
            configuration: fixture.configuration,
            now: fixture.now)

        let defaultFile = fixture.root.appendingPathComponent(".copilot/otel/default.jsonl")
        try FileManager.default.createDirectory(
            at: defaultFile.deletingLastPathComponent(),
            withIntermediateDirectories: true)
        try Data("{}\n".utf8).write(to: defaultFile)
        try FileManager.default.setAttributes(
            [.modificationDate: fixture.now],
            ofItemAtPath: defaultFile.path)
        let afterDefault = try await builder.sourceSignature(
            configuration: fixture.configuration,
            now: fixture.now)

        try FileManager.default.createDirectory(
            at: exporterFile.deletingLastPathComponent(),
            withIntermediateDirectories: true)
        try Data("{}\n".utf8).write(to: exporterFile)
        let afterExporter = try await builder.sourceSignature(
            configuration: fixture.configuration,
            now: fixture.now)

        XCTAssertNotEqual(initial, afterDefault)
        XCTAssertNotEqual(afterDefault, afterExporter)
    }
}
