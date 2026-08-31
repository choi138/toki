import Foundation
import TokiUsageCore
import XCTest
@testable import Toki
@testable import TokiUsageReaders

final class CopilotCLIReaderTests: XCTestCase {
    func test_chatSpanMapsConfirmedUsageAttributesAndAttribution() {
        let usage = CopilotCLIReader.usage(
            fromJSONLLines: [
                copilotSpan(
                    operation: "invoke_agent",
                    traceID: "trace-1",
                    spanID: "invoke-1",
                    timestamp: 1_765_756_799,
                    attributes: """
                    "gen_ai.request.model":"claude-sonnet-4.6",
                    "gen_ai.provider.name":"github",
                    "gen_ai.conversation.id":"conversation-1"
                    """),
                copilotSpan(
                    traceID: "trace-1",
                    spanID: "span-1",
                    timestamp: 1_765_756_800,
                    attributes: """
                    "gen_ai.response.id":"response-1",
                    "gen_ai.usage.input_tokens":120,
                    "gen_ai.usage.output_tokens":30,
                    "gen_ai.usage.cache_read.input_tokens":20,
                    "gen_ai.usage.cache_write.input_tokens":5,
                    "gen_ai.usage.reasoning.output_tokens":7
                    """),
            ],
            streamID: "fixture.jsonl",
            from: Date(timeIntervalSince1970: 1_765_756_700),
            to: Date(timeIntervalSince1970: 1_765_756_900))

        XCTAssertEqual(usage.inputTokens, 100)
        XCTAssertEqual(usage.outputTokens, 30)
        XCTAssertEqual(usage.cacheReadTokens, 20)
        XCTAssertEqual(usage.cacheWriteTokens, 5)
        XCTAssertEqual(usage.reasoningTokens, 7)
        XCTAssertEqual(usage.cost, 0)
        XCTAssertEqual(usage.tokenEvents.first?.source, "GitHub Copilot CLI")
        XCTAssertEqual(usage.tokenEvents.first?.model, "claude-sonnet-4.6")
        XCTAssertEqual(usage.tokenEvents.first?.provider, "github")
        XCTAssertEqual(usage.tokenEvents.first?.costIsKnown, false)
        XCTAssertEqual(usage.tokenEvents.first?.attribution?.sessionID, "conversation-1")
        XCTAssertEqual(usage.tokenEvents.first?.attribution?.quality, .unknown)
    }

    func test_cliUnderscoreCacheVariantAndInferenceLogAreSupported() {
        let usage = CopilotCLIReader.usage(
            fromJSONLLines: [
                """
                {
                  "type":"log",
                  "traceId":"trace-2",
                  "spanId":"span-2",
                  "timeUnixNano":"1765756800000000000",
                  "body":"GenAI inference: sentinel",
                  "attributes":{
                    "gen_ai.response.id":"response-2",
                    "gen_ai.request.model":"gpt-5.4-mini",
                    "gen_ai.usage.input_tokens":90,
                    "gen_ai.usage.output_tokens":11,
                    "gen_ai.usage.cache_read_input_tokens":40,
                    "gen_ai.usage.cache_creation_input_tokens":3,
                    "gen_ai.usage.reasoning_tokens":2
                  }
                }
                """,
            ],
            streamID: "fixture.jsonl",
            from: Date(timeIntervalSince1970: 1_765_756_700),
            to: Date(timeIntervalSince1970: 1_765_756_900))

        XCTAssertEqual(usage.inputTokens, 50)
        XCTAssertEqual(usage.outputTokens, 11)
        XCTAssertEqual(usage.cacheReadTokens, 40)
        XCTAssertEqual(usage.cacheWriteTokens, 3)
        XCTAssertEqual(usage.reasoningTokens, 2)
        XCTAssertEqual(usage.tokenEvents.first?.model, "gpt-5.4-mini")
        XCTAssertEqual(usage.tokenEvents.first?.provider, "openai")
    }

    func test_dateRangeIsHalfOpenAndMissingAttributionKeepsUsage() {
        let start = Date(timeIntervalSince1970: 1_765_756_800)
        let end = Date(timeIntervalSince1970: 1_765_843_200)
        let usage = CopilotCLIReader.usage(
            fromJSONLLines: [
                copilotSpan(
                    traceID: nil,
                    spanID: nil,
                    timestamp: 1_765_756_799,
                    attributes: #""gen_ai.usage.input_tokens":1"#),
                copilotSpan(
                    traceID: nil,
                    spanID: nil,
                    timestamp: 1_765_756_800,
                    attributes: #""gen_ai.usage.input_tokens":2"#),
                copilotSpan(
                    traceID: nil,
                    spanID: nil,
                    timestamp: 1_765_843_199,
                    attributes: #""gen_ai.usage.input_tokens":3"#),
                copilotSpan(
                    traceID: nil,
                    spanID: nil,
                    timestamp: 1_765_843_200,
                    attributes: #""gen_ai.usage.input_tokens":4"#),
            ],
            streamID: "fixture.jsonl",
            from: start,
            to: end)

        XCTAssertEqual(usage.inputTokens, 5)
        XCTAssertEqual(usage.tokenEvents.count, 2)
        XCTAssertNil(usage.tokenEvents.first?.model)
        XCTAssertEqual(usage.tokenEvents.first?.attribution?.quality, .unknown)
    }

    func test_repeatedRecordsAndLowerPriorityRecordsAreDeduplicated() {
        let span = copilotSpan(
            traceID: "trace-3",
            spanID: "span-3",
            timestamp: 1_765_756_800,
            attributes: """
            "gen_ai.response.id":"response-3",
            "gen_ai.response.model":"gpt-5.4",
            "gen_ai.usage.input_tokens":10,
            "gen_ai.usage.output_tokens":4
            """)
        let inference = """
        {
          "type":"log",
          "traceId":"trace-3",
          "spanId":"log-3",
          "timeUnixNano":"1765756800000000000",
          "attributes":{
            "event.name":"gen_ai.client.inference.operation.details",
            "gen_ai.response.id":"response-3",
            "gen_ai.response.model":"gpt-5.4",
            "gen_ai.usage.input_tokens":10,
            "gen_ai.usage.output_tokens":4
          }
        }
        """
        let summary = copilotSpan(
            operation: "invoke_agent",
            traceID: "trace-3",
            spanID: "summary-3",
            timestamp: 1_765_756_800,
            attributes: #""gen_ai.usage.input_tokens":100,"gen_ai.usage.output_tokens":40"#)

        let usage = CopilotCLIReader.usage(
            fromJSONLLines: [span, span, inference, summary],
            streamID: "fixture.jsonl",
            from: Date(timeIntervalSince1970: 1_765_756_700),
            to: Date(timeIntervalSince1970: 1_765_756_900))

        XCTAssertEqual(usage.inputTokens, 10)
        XCTAssertEqual(usage.outputTokens, 4)
        XCTAssertEqual(usage.tokenEvents.count, 1)
    }
}

extension CopilotCLIReaderTests {
    func test_distinctResponseIDsWithinOneTraceRemainIndependent() {
        let first = copilotSpan(
            traceID: "shared-trace",
            spanID: "first-span",
            timestamp: 1_765_756_800,
            attributes: """
            "gen_ai.response.id":"first-response",
            "gen_ai.usage.input_tokens":10
            """)
        let second = """
        {
          "type":"log",
          "traceId":"shared-trace",
          "spanId":"second-span",
          "timeUnixNano":"1765756801000000000",
          "attributes":{
            "event.name":"gen_ai.client.inference.operation.details",
            "gen_ai.response.id":"second-response",
            "gen_ai.usage.input_tokens":20
          }
        }
        """

        let usage = CopilotCLIReader.usage(
            fromJSONLLines: [first, second],
            streamID: "fixture.jsonl",
            from: Date(timeIntervalSince1970: 1_765_756_700),
            to: Date(timeIntervalSince1970: 1_765_756_900))

        XCTAssertEqual(usage.inputTokens, 30)
        XCTAssertEqual(usage.tokenEvents.count, 2)
    }

    func test_complementaryRepresentationsMergeBeforePrioritySelection() {
        let span = copilotSpan(
            traceID: "merge-trace",
            spanID: "chat-span",
            timestamp: 1_765_756_800,
            attributes: """
            "gen_ai.response.id":"merge-response",
            "gen_ai.usage.input_tokens":10,
            "gen_ai.usage.output_tokens":4
            """)
        let inference = """
        {
          "type":"log",
          "traceId":"merge-trace",
          "spanId":"inference-log",
          "timeUnixNano":"1765756800000000000",
          "attributes":{
            "event.name":"gen_ai.client.inference.operation.details",
            "gen_ai.response.id":"merge-response",
            "gen_ai.usage.cache_read_input_tokens":3,
            "gen_ai.usage.reasoning_tokens":2
          }
        }
        """

        let usage = CopilotCLIReader.usage(
            fromJSONLLines: [span, inference],
            streamID: "fixture.jsonl",
            from: Date(timeIntervalSince1970: 1_765_756_700),
            to: Date(timeIntervalSince1970: 1_765_756_900))

        XCTAssertEqual(usage.inputTokens, 10)
        XCTAssertEqual(usage.outputTokens, 4)
        XCTAssertEqual(usage.cacheReadTokens, 3)
        XCTAssertEqual(usage.reasoningTokens, 2)
        XCTAssertEqual(usage.tokenEvents.count, 1)
    }

    func test_traceReconciliationPreservesFieldsFromResponseLessInferenceLog() {
        let span = copilotSpan(
            traceID: "response-less-trace",
            spanID: "chat-span",
            timestamp: 1_765_756_800,
            attributes: """
            "gen_ai.response.id":"response-less-response",
            "gen_ai.usage.input_tokens":10,
            "gen_ai.usage.output_tokens":4
            """)
        let inference = """
        {
          "type":"log",
          "traceId":"response-less-trace",
          "spanId":"inference-log",
          "timeUnixNano":"1765756800000000000",
          "attributes":{
            "event.name":"gen_ai.client.inference.operation.details",
            "gen_ai.usage.cache_read_input_tokens":3,
            "gen_ai.usage.reasoning_tokens":2
          }
        }
        """

        let usage = CopilotCLIReader.usage(
            fromJSONLLines: [span, inference],
            streamID: "fixture.jsonl",
            from: Date(timeIntervalSince1970: 1_765_756_700),
            to: Date(timeIntervalSince1970: 1_765_756_900))

        XCTAssertEqual(usage.inputTokens, 10)
        XCTAssertEqual(usage.outputTokens, 4)
        XCTAssertEqual(usage.cacheReadTokens, 3)
        XCTAssertEqual(usage.reasoningTokens, 2)
        XCTAssertEqual(usage.tokenEvents.count, 1)
    }

    func test_preferredNormalizedInputIsNotCombinedWithConflictingReplicaInput() {
        let span = copilotSpan(
            traceID: "normalized-trace",
            spanID: "chat-span",
            timestamp: 1_765_756_800,
            attributes: """
            "gen_ai.response.id":"normalized-response",
            "gen_ai.usage.input_tokens":10,
            "gen_ai.usage.cache_read.input_tokens":3
            """)
        let inference = """
        {
          "type":"log",
          "traceId":"normalized-trace",
          "spanId":"inference-log",
          "timeUnixNano":"1765756800000000000",
          "attributes":{
            "event.name":"gen_ai.client.inference.operation.details",
            "gen_ai.response.id":"normalized-response",
            "gen_ai.usage.input_tokens":10
          }
        }
        """

        let usage = CopilotCLIReader.usage(
            fromJSONLLines: [span, inference],
            streamID: "fixture.jsonl",
            from: Date(timeIntervalSince1970: 1_765_756_700),
            to: Date(timeIntervalSince1970: 1_765_756_900))

        XCTAssertEqual(usage.inputTokens, 7)
        XCTAssertEqual(usage.cacheReadTokens, 3)
        XCTAssertEqual(usage.totalTokens, 10)
        XCTAssertEqual(usage.tokenEvents.count, 1)
    }
}

final class CopilotCLIReaderRobustnessTests: XCTestCase {
    func test_idlessRecordsAreNotDeduplicatedFromSensitivePayloadContent() {
        let line = copilotSpan(
            traceID: nil,
            spanID: nil,
            timestamp: 1_765_756_800,
            attributes: #""gen_ai.usage.input_tokens":6"#)

        let usage = CopilotCLIReader.usage(
            fromJSONLLines: [line, line],
            streamID: "fixture.jsonl",
            from: Date(timeIntervalSince1970: 1_765_756_700),
            to: Date(timeIntervalSince1970: 1_765_756_900))

        XCTAssertEqual(usage.inputTokens, 12)
        XCTAssertEqual(usage.tokenEvents.count, 2)
    }

    func test_malformedBlankCRLFAndTruncatedLinesAreIgnored() {
        let valid = copilotSpan(
            traceID: "trace-4",
            spanID: "span-4",
            timestamp: 1_765_756_800,
            attributes: #""gen_ai.usage.output_tokens":9"#)

        let usage = CopilotCLIReader.usage(
            fromJSONLLines: ["", "not-json", valid + "\r", #"{"type":"span""#],
            streamID: "fixture.jsonl",
            from: Date(timeIntervalSince1970: 1_765_756_700),
            to: Date(timeIntervalSince1970: 1_765_756_900))

        XCTAssertEqual(usage.outputTokens, 9)
        XCTAssertEqual(usage.tokenEvents.count, 1)
    }

    func test_nonUsageTokenlessAndMetricCounterRecordsAreIgnored() {
        let usage = CopilotCLIReader.usage(
            fromJSONLLines: [
                """
                {
                  "type":"span",
                  "traceId":"trace-tool",
                  "spanId":"span-tool",
                  "name":"execute_tool sentinel",
                  "startTime":[1765756800,0],
                  "attributes":{
                    "gen_ai.operation.name":"execute_tool",
                    "gen_ai.usage.input_tokens":100
                  }
                }
                """,
                """
                {
                  "type":"span",
                  "traceId":"trace-empty",
                  "spanId":"span-empty",
                  "name":"chat gpt-5.4",
                  "startTime":[1765756800,0],
                  "attributes":{
                    "gen_ai.operation.name":"chat",
                    "gen_ai.response.model":"gpt-5.4"
                  }
                }
                """,
                """
                {
                  "type":"metric",
                  "name":"gen_ai.client.token.usage",
                  "timestamp":1765756800,
                  "attributes":{"gen_ai.usage.input_tokens":500}
                }
                """,
            ],
            streamID: "fixture.jsonl",
            from: Date(timeIntervalSince1970: 1_765_756_700),
            to: Date(timeIntervalSince1970: 1_765_756_900))

        XCTAssertEqual(usage.totalTokens, 0)
        XCTAssertTrue(usage.tokenEvents.isEmpty)
    }
}

final class CopilotCLIReaderIntegrationTests: XCTestCase {
    func test_defaultDirectoryAndExporterFileAreReadOnlyOnce() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("toki-copilot-\(UUID().uuidString)")
        let directory = root.appendingPathComponent(".copilot/otel")
        let file = directory.appendingPathComponent("usage.jsonl")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let line = jsonlLine(copilotSpan(
            traceID: "trace-5",
            spanID: "span-5",
            timestamp: 1_765_756_800,
            attributes: #""gen_ai.usage.input_tokens":13"#))
        try line.write(to: file, atomically: true, encoding: .utf8)
        try line.write(
            to: directory.appendingPathComponent("retransmitted.jsonl"),
            atomically: true,
            encoding: .utf8)

        let reader = CopilotCLIReader(
            otelDirectoryURLOverride: directory,
            exporterFileURLOverride: file)
        let usage = try await reader.readUsage(
            from: Date(timeIntervalSince1970: 1_765_756_700),
            to: Date(timeIntervalSince1970: 1_765_756_900))

        XCTAssertEqual(usage.inputTokens, 13)
        XCTAssertEqual(usage.tokenEvents.count, 1)
    }

    func test_aggregationDiagnosticsAndExportPreserveCopilotSourceAndModel() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("toki-copilot-\(UUID().uuidString)")
        let directory = root.appendingPathComponent(".copilot/otel")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try jsonlLine(copilotSpan(
            traceID: "trace-6",
            spanID: "span-6",
            timestamp: 1_765_756_800,
            attributes: #""gen_ai.response.model":"gpt-5.4","gen_ai.usage.input_tokens":17"#))
            .write(
                to: directory.appendingPathComponent("usage.jsonl"),
                atomically: true,
                encoding: .utf8)
        let reader = CopilotCLIReader(otelDirectoryURLOverride: directory)
        let result = await UsageAggregator(readers: [reader]).aggregateUsage(
            for: UsageAggregationRequest(
                start: Date(timeIntervalSince1970: 1_765_756_700),
                end: Date(timeIntervalSince1970: 1_765_756_900),
                enabledReaderNames: [:],
                includesEmptySourceRows: false))

        XCTAssertEqual(result.readerStatuses.first?.name, "GitHub Copilot CLI")
        XCTAssertEqual(result.readerStatuses.first?.state, .loaded)
        XCTAssertEqual(result.usageData.sourceStats.first?.source, "GitHub Copilot CLI")
        XCTAssertEqual(result.usageData.perModel.first?.id, "gpt-5.4")
        let export = UsageExport.jsonString(for: result.usageData)
        XCTAssertTrue(export.contains(#""source" : "GitHub Copilot CLI""#))
        XCTAssertTrue(export.contains(#""model" : "gpt-5.4""#))
    }
}

private func copilotSpan(
    operation: String = "chat",
    traceID: String?,
    spanID: String?,
    timestamp: Int,
    attributes: String) -> String {
    let trace = traceID.map { #","traceId":"\#($0)""# } ?? ""
    let span = spanID.map { #","spanId":"\#($0)""# } ?? ""
    return """
    {
      "type":"span"\(trace)\(span),
      "name":"\(operation) sentinel",
      "startTime":[\(timestamp),0],
      "attributes":{"gen_ai.operation.name":"\(operation)",\(attributes)}
    }
    """
}

private func jsonlLine(_ value: String) -> String {
    value.components(separatedBy: .newlines)
        .map { $0.trimmingCharacters(in: .whitespaces) }
        .joined()
}
