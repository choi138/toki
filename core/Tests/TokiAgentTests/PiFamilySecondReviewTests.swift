import Foundation
import TokiUsageCore
import XCTest
@testable import TokiUsageReaders

final class PiFamilySecondReviewTests: XCTestCase {
    func test_sharedReaderDeduplicatesExactNonUUIDMessageCopies() async throws {
        let root = secondReviewTemporaryRoot("toki-shared-omp-copy")
        defer { try? FileManager.default.removeItem(at: root) }
        let copied = secondReviewMessage(
            messageID: "omp-message-1",
            input: 3,
            output: 2)
        try secondReviewWriteLines(
            [secondReviewSession("session-a"), copied],
            to: root.appendingPathComponent("a.jsonl"))
        try secondReviewWriteLines(
            [secondReviewSession("session-b"), copied],
            to: root.appendingPathComponent("b.jsonl"))

        let usage = try await SharedPiOMPReader(sessionsURL: root).readUsage(
            from: secondReviewDate("2026-08-20T00:00:00Z"),
            to: secondReviewDate("2026-08-21T00:00:00Z"))

        XCTAssertEqual(usage.totalTokens, 5)
        XCTAssertEqual(usage.tokenEvents.count, 1)
    }

    func test_responseCopyFingerprintIncludesIgnoredPayloadContent() async throws {
        let root = secondReviewTemporaryRoot("toki-response-payload")
        defer { try? FileManager.default.removeItem(at: root) }
        try secondReviewWriteLines(
            [
                secondReviewSession("session-a"),
                secondReviewMessage(
                    responseID: "reused-response",
                    input: 3,
                    output: 2,
                    content: "alpha"),
            ],
            to: root.appendingPathComponent("a.jsonl"))
        try secondReviewWriteLines(
            [
                secondReviewSession("session-b"),
                secondReviewMessage(
                    responseID: "reused-response",
                    input: 3,
                    output: 2,
                    content: "beta"),
            ],
            to: root.appendingPathComponent("b.jsonl"))

        let usage = try await PiReader(sessionsURLOverride: root).readUsage(
            from: secondReviewDate("2026-08-20T00:00:00Z"),
            to: secondReviewDate("2026-08-21T00:00:00Z"))

        XCTAssertEqual(usage.totalTokens, 10)
        XCTAssertEqual(usage.tokenEvents.count, 2)
    }

    func test_responseCopiesBridgeProviderAndCostRevisions() async throws {
        let root = secondReviewTemporaryRoot("toki-response-revisions")
        defer { try? FileManager.default.removeItem(at: root) }
        try secondReviewWriteLines(
            [
                secondReviewSession("session-a"),
                secondReviewMessage(
                    responseID: "response-1",
                    provider: nil,
                    input: 3,
                    output: 2),
            ],
            to: root.appendingPathComponent("a.jsonl"))
        try secondReviewWriteLines(
            [
                secondReviewSession("session-b"),
                secondReviewMessage(
                    responseID: "response-1",
                    provider: "azure",
                    input: 3,
                    output: 2,
                    cost: 0.25),
            ],
            to: root.appendingPathComponent("b.jsonl"))

        let usage = try await PiReader(sessionsURLOverride: root).readUsage(
            from: secondReviewDate("2026-08-20T00:00:00Z"),
            to: secondReviewDate("2026-08-21T00:00:00Z"))

        XCTAssertEqual(usage.totalTokens, 5)
        XCTAssertEqual(usage.cost, 0.25, accuracy: 0.000001)
        XCTAssertEqual(usage.tokenEvents.count, 1)
        XCTAssertEqual(usage.tokenEvents.first?.costIsKnown, true)
    }

    func test_modelCorrectionRemainsOneSessionResponse() {
        let usage = PiReader.usage(
            fromJSONLLines: [
                secondReviewSession("model-correction"),
                secondReviewMessage(
                    responseID: "response-1",
                    timestamp: "2026-08-20T12:00:00Z",
                    model: "gpt-5-preview",
                    input: 3,
                    output: 2),
                secondReviewMessage(
                    responseID: "response-1",
                    timestamp: "2026-08-20T12:01:00Z",
                    model: "gpt-5",
                    input: 3,
                    output: 2),
            ],
            streamID: "/tmp/model-correction.jsonl",
            from: secondReviewDate("2026-08-20T00:00:00Z"),
            to: secondReviewDate("2026-08-21T00:00:00Z"))

        XCTAssertEqual(usage.totalTokens, 5)
        XCTAssertEqual(usage.tokenEvents.count, 1)
        XCTAssertEqual(usage.tokenEvents.first?.model, "gpt-5")
    }

    func test_messageIDAdditionKeepsResponseIdentity() {
        let usage = PiReader.usage(
            fromJSONLLines: [
                secondReviewSession("message-id-addition"),
                secondReviewMessage(
                    responseID: "response-1",
                    timestamp: "2026-08-20T12:00:00Z",
                    input: 3,
                    output: 2),
                secondReviewMessage(
                    messageID: "message-1",
                    responseID: "response-1",
                    timestamp: "2026-08-20T12:01:00Z",
                    input: 3,
                    output: 2),
            ],
            streamID: "/tmp/message-id-addition.jsonl",
            from: secondReviewDate("2026-08-20T00:00:00Z"),
            to: secondReviewDate("2026-08-21T00:00:00Z"))

        XCTAssertEqual(usage.totalTokens, 5)
        XCTAssertEqual(usage.tokenEvents.count, 1)
    }

    func test_laterKnownZeroCostReplacesEarlierKnownCost() {
        let usage = PiReader.usage(
            fromJSONLLines: [
                secondReviewSession("cost-correction"),
                secondReviewMessage(
                    responseID: "response-1",
                    timestamp: "2026-08-20T12:00:00Z",
                    input: 3,
                    output: 2,
                    cost: 0.25),
                secondReviewMessage(
                    responseID: "response-1",
                    timestamp: "2026-08-20T12:01:00Z",
                    input: 3,
                    output: 2,
                    cost: 0),
            ],
            streamID: "/tmp/cost-correction.jsonl",
            from: secondReviewDate("2026-08-20T00:00:00Z"),
            to: secondReviewDate("2026-08-21T00:00:00Z"))

        XCTAssertEqual(usage.cost, 0)
        XCTAssertEqual(usage.tokenEvents.first?.cost, 0)
        XCTAssertEqual(usage.tokenEvents.first?.costIsKnown, true)
    }

    func test_attributionMergeKeepsSessionLabelEnrichment() {
        let plain = secondReviewRecord(attribution: UsageAttribution(
            projectName: "Toki",
            sessionID: "session-1",
            quality: .exact))
        let enriched = secondReviewRecord(attribution: UsageAttribution(
            projectName: "Toki",
            sessionID: "session-1",
            sessionLabel: "Review fixes",
            quality: .exact))

        for merged in [plain.merged(with: enriched), enriched.merged(with: plain)] {
            XCTAssertEqual(merged.attribution.sessionLabel, "Review fixes")
        }
    }
}

extension PiFamilySecondReviewTests {
    func test_senpiModelCorrectionRemainsOneSessionResponse() {
        let usage = SenpiReader.usage(
            fromJSONLLines: [
                secondReviewSession("senpi-model-correction"),
                secondReviewMessage(
                    responseID: "response-1",
                    timestamp: "2026-08-20T12:00:00Z",
                    model: "gpt-5-preview",
                    input: 3,
                    output: 2),
                secondReviewMessage(
                    responseID: "response-1",
                    timestamp: "2026-08-20T12:01:00Z",
                    model: "gpt-5",
                    input: 3,
                    output: 2),
            ],
            streamID: "/tmp/senpi-model-correction.jsonl",
            from: secondReviewDate("2026-08-20T00:00:00Z"),
            to: secondReviewDate("2026-08-21T00:00:00Z"))

        XCTAssertEqual(usage.totalTokens, 5)
        XCTAssertEqual(usage.tokenEvents.count, 1)
        XCTAssertEqual(usage.tokenEvents.first?.model, "gpt-5")
    }

    func test_senpiContentDistinctResponsesKeepSeparateLegacyAliases() {
        let usage = SenpiReader.usage(
            fromJSONLLines: [
                secondReviewSession("senpi-a"),
                secondReviewMessage(
                    responseID: "shared-response",
                    input: 3,
                    output: 2,
                    content: "alpha"),
                secondReviewSession("senpi-b"),
                secondReviewMessage(
                    responseID: "shared-response",
                    input: 3,
                    output: 2,
                    content: "beta"),
            ],
            streamID: "/tmp/senpi-distinct-content.jsonl",
            from: secondReviewDate("2026-08-20T00:00:00Z"),
            to: secondReviewDate("2026-08-21T00:00:00Z"))

        XCTAssertEqual(usage.totalTokens, 10)
        XCTAssertEqual(usage.tokenEvents.count, 2)
    }

    func test_senpiMergeKeepsPreferredRevisionCoherent() {
        let usage = SenpiReader.usage(
            fromJSONLLines: [
                secondReviewSession("senpi-session"),
                secondReviewMessage(
                    messageID: "shared-message",
                    timestamp: "2026-08-20T12:00:00Z",
                    input: 100,
                    output: 0,
                    cost: 0.10),
                secondReviewMessage(
                    messageID: "shared-message",
                    timestamp: "2026-08-20T12:01:00Z",
                    input: 90,
                    output: 0,
                    cost: 0.20),
            ],
            streamID: "/tmp/senpi-coherent.jsonl",
            from: secondReviewDate("2026-08-20T00:00:00Z"),
            to: secondReviewDate("2026-08-21T00:00:00Z"))

        XCTAssertEqual(usage.totalTokens, 100)
        XCTAssertEqual(usage.cost, 0.10, accuracy: 0.000001)
        XCTAssertEqual(usage.tokenEvents.count, 1)
    }

    func test_senpiResponseIDReuseKeepsDistinctSessionRecords() {
        let usage = SenpiReader.usage(
            fromJSONLLines: [
                secondReviewSession("senpi-a"),
                secondReviewMessage(
                    responseID: "shared-response",
                    input: 100,
                    output: 0,
                    cost: 0.10),
                secondReviewSession("senpi-b"),
                secondReviewMessage(
                    responseID: "shared-response",
                    input: 90,
                    output: 0,
                    cost: 0.20),
            ],
            streamID: "/tmp/senpi-response.jsonl",
            from: secondReviewDate("2026-08-20T00:00:00Z"),
            to: secondReviewDate("2026-08-21T00:00:00Z"))

        XCTAssertEqual(usage.totalTokens, 190)
        XCTAssertEqual(usage.cost, 0.30, accuracy: 0.000001)
        XCTAssertEqual(usage.tokenEvents.count, 2)
    }

    func test_senpiResponseCopiesKeepLegacyContentIdentity() {
        let copiedResponse = secondReviewMessage(
            responseID: "shared-response",
            input: 100,
            output: 0,
            cost: 0.10)
        let usage = SenpiReader.usage(
            fromJSONLLines: [
                secondReviewSession("senpi-a"),
                copiedResponse,
                secondReviewSession("senpi-b"),
                copiedResponse,
            ],
            streamID: "/tmp/senpi-response-copy.jsonl",
            from: secondReviewDate("2026-08-20T00:00:00Z"),
            to: secondReviewDate("2026-08-21T00:00:00Z"))

        XCTAssertEqual(usage.totalTokens, 100)
        XCTAssertEqual(usage.cost, 0.10, accuracy: 0.000001)
        XCTAssertEqual(usage.tokenEvents.count, 1)
    }

    func test_senpiKnownZeroCostWinsLegacyTieInEitherOrder() {
        let unknown = secondReviewMessage(
            messageID: "shared-message",
            timestamp: "2026-08-20T12:00:00Z",
            input: 3,
            output: 2)
        let knownZero = secondReviewMessage(
            messageID: "shared-message",
            timestamp: "2026-08-20T12:01:00Z",
            input: 3,
            output: 2,
            cost: 0)

        for records in [[unknown, knownZero], [knownZero, unknown]] {
            let usage = SenpiReader.usage(
                fromJSONLLines: [secondReviewSession("senpi-cost")] + records,
                streamID: "/tmp/senpi-known-zero.jsonl",
                from: secondReviewDate("2026-08-20T00:00:00Z"),
                to: secondReviewDate("2026-08-21T00:00:00Z"))

            XCTAssertEqual(usage.cost, 0)
            XCTAssertEqual(usage.tokenEvents.count, 1)
            XCTAssertEqual(usage.tokenEvents.first?.costIsKnown, true)
        }
    }

    func test_senpiFullyIDlessRowsKeepPhysicalIdentity() {
        let row = secondReviewMessage(input: 3, output: 2)
        let usage = SenpiReader.usage(
            fromJSONLLines: [secondReviewSession("senpi-idless"), row, row],
            streamID: "/tmp/senpi-idless.jsonl",
            from: secondReviewDate("2026-08-20T00:00:00Z"),
            to: secondReviewDate("2026-08-21T00:00:00Z"))

        XCTAssertEqual(usage.totalTokens, 10)
        XCTAssertEqual(usage.tokenEvents.count, 2)
    }
}

private func secondReviewRecord(attribution: UsageAttribution) -> PiCompatibleUsageRecord {
    PiCompatibleUsageRecord(
        deduplicationKey: .message("attribution-record"),
        timestamp: secondReviewDate("2026-08-20T12:00:00Z"),
        model: "gpt-5",
        provider: "openai",
        inputTokens: 3,
        outputTokens: 2,
        cacheReadTokens: 0,
        cacheWriteTokens: 0,
        reasoningTokens: 0,
        cost: 0,
        costIsKnown: false,
        attribution: attribution,
        agentKind: .main)
}

private func secondReviewMessage(
    messageID: String? = nil,
    responseID: String? = nil,
    timestamp: String = "2026-08-20T12:00:00Z",
    model: String = "gpt-5",
    provider: String? = "openai",
    input: Int,
    output: Int,
    cost: Double? = nil,
    content: String? = nil) -> String {
    let messageIDField = messageID.map { ",\"id\":\"\($0)\"" } ?? ""
    let responseIDField = responseID.map { ",\"responseId\":\"\($0)\"" } ?? ""
    let providerField = provider.map { ",\"provider\":\"\($0)\"" } ?? ""
    let costField = cost.map { ",\"cost\":{\"total\":\($0)}" } ?? ""
    let contentField = content.map { ",\"content\":\"\($0)\"" } ?? ""
    return """
    {"type":"message"\(messageIDField),"timestamp":"\(timestamp)","message":\
    {"role":"assistant"\(responseIDField),"model":"\(model)"\(providerField)\
    \(contentField),"usage":{"input":\(input),"output":\(output)\(costField)}}}
    """
}

private func secondReviewSession(_ id: String) -> String {
    #"{"type":"session","id":"\#(id)","cwd":"/tmp/toki"}"#
}

private func secondReviewDate(_ value: String) -> Date {
    ISO8601DateFormatter().date(from: value) ?? .distantPast
}

private func secondReviewTemporaryRoot(_ prefix: String) -> URL {
    FileManager.default.temporaryDirectory
        .appendingPathComponent("\(prefix)-\(UUID().uuidString)", isDirectory: true)
}

private func secondReviewWriteLines(_ lines: [String], to url: URL) throws {
    try FileManager.default.createDirectory(
        at: url.deletingLastPathComponent(),
        withIntermediateDirectories: true)
    try Data(lines.joined(separator: "\n").utf8).write(to: url)
}
