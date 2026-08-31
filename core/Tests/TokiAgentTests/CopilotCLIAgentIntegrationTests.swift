import Foundation
import TokiSyncProtocol
import XCTest
@testable import TokiAgentCore
@testable import TokiUsageReaders

final class CopilotCLIAgentIntegrationTests: XCTestCase {
    func test_defaultAgentRegistryExportsCopilotUsageAndProvider() async throws {
        let now = Date(timeIntervalSince1970: 1_784_200_000)
        let fixture = try AgentSnapshotFixture()
        defer { fixture.remove() }
        let otelDirectory = fixture.root.appendingPathComponent(".copilot/otel")
        try FileManager.default.createDirectory(at: otelDirectory, withIntermediateDirectories: true)
        let line = copilotAgentJSONLLine("""
        {
          "type":"span",
          "traceId":"trace-agent",
          "spanId":"span-agent",
          "name":"chat sentinel",
          "startTime":[1784199940,0],
          "attributes":{
            "gen_ai.operation.name":"chat",
            "gen_ai.response.id":"response-agent",
            "gen_ai.response.model":"claude-sonnet-4.6",
            "gen_ai.provider.name":"github",
            "gen_ai.usage.input_tokens":21,
            "gen_ai.usage.output_tokens":8
          }
        }
        """)
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
        let defaultDirectory = fixture.root.appendingPathComponent(".copilot/otel")
        let oldDate = fixture.now.addingTimeInterval(-30 * 24 * 60 * 60)
        try FileManager.default.createDirectory(
            at: defaultDirectory,
            withIntermediateDirectories: true)
        try FileManager.default.setAttributes(
            [.modificationDate: oldDate],
            ofItemAtPath: defaultDirectory.path)
        let initial = try await builder.sourceSignature(
            configuration: fixture.configuration,
            now: fixture.now)

        let defaultFile = defaultDirectory.appendingPathComponent("default.jsonl")
        try Data("{}\n".utf8).write(to: defaultFile)
        try FileManager.default.setAttributes(
            [.modificationDate: oldDate],
            ofItemAtPath: defaultFile.path)
        try FileManager.default.setAttributes(
            [.modificationDate: oldDate],
            ofItemAtPath: defaultDirectory.path)
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

    func test_readerRejectsOversizedTelemetryFiles() async throws {
        let fixture = try AgentSnapshotFixture()
        defer { fixture.remove() }
        let otelDirectory = fixture.root.appendingPathComponent(".copilot/otel")
        try FileManager.default.createDirectory(at: otelDirectory, withIntermediateDirectories: true)
        let file = otelDirectory.appendingPathComponent("oversized.jsonl")
        try Data(repeating: 0x20, count: 17).write(to: file)
        let reader = CopilotCLIReader(
            otelDirectoryURLOverride: otelDirectory,
            exporterFileURLOverride: nil,
            readLimits: PiCompatibleReadLimits(
                maximumFileCount: 1,
                maximumFileBytes: 16,
                maximumLineBytes: 16,
                maximumEventCount: 1))

        do {
            _ = try await reader.readUsage(from: .distantPast, to: .distantFuture)
            XCTFail("Expected oversized telemetry to fail closed")
        } catch {
            XCTAssertEqual(error as? PiCompatibleReaderError, .fileTooLarge(file))
        }
    }

    func test_readerPropagatesTelemetryDirectoryReadFailures() async throws {
        let fixture = try AgentSnapshotFixture()
        defer { fixture.remove() }
        let nonDirectory = fixture.root.appendingPathComponent("copilot-otel.jsonl")
        try Data("not a directory".utf8).write(to: nonDirectory)
        let reader = CopilotCLIReader(otelDirectoryURLOverride: nonDirectory)

        do {
            _ = try await reader.readUsage(from: .distantPast, to: .distantFuture)
            XCTFail("Expected unreadable telemetry source to fail closed")
        } catch {
            XCTAssertEqual(error as? PiCompatibleReaderError, .unreadableFile(nonDirectory))
        }
    }

    func test_readerBoundsExtremeTelemetryTokenCounters() {
        let line = copilotAgentJSONLLine("""
        {
          "type":"span",
          "traceId":"trace-extreme",
          "spanId":"span-extreme",
          "name":"chat sentinel",
          "startTime":[1784199940,0],
          "attributes":{
            "gen_ai.operation.name":"chat",
            "gen_ai.usage.input_tokens":\(Int.max),
            "gen_ai.usage.output_tokens":1
          }
        }
        """)

        let usage = CopilotCLIReader.usage(
            fromJSONLLines: [line],
            streamID: "fixture.jsonl",
            from: .distantPast,
            to: .distantFuture)

        XCTAssertEqual(usage.inputTokens, RemoteUsageSnapshotValidator.maximumTokenCountPerBucket)
        XCTAssertEqual(usage.outputTokens, 1)
    }
}

private func copilotAgentJSONLLine(_ value: String) -> String {
    value.components(separatedBy: .newlines)
        .map { $0.trimmingCharacters(in: .whitespaces) }
        .joined()
}
