import Foundation
import TokiSyncProtocol
import TokiUsageCore
import XCTest
@testable import Toki
@testable import TokiUsageReaders

final class DroidAmpIntegrationTests: XCTestCase {
    func test_registryReadersPreserveSourceModelProjectSessionAndUnpricedExport() async throws {
        let fixture = try DroidAmpIntegrationFixture()
        defer { fixture.remove() }
        try fixture.writeDroid()
        try fixture.writeAmp()
        let readers = LocalUsageReaderRegistry.readers(
            home: fixture.root,
            environment: ["XDG_DATA_HOME": fixture.root.appendingPathComponent(".local/share").path])
            .filter { [FactoryDroidReader.sourceName, AmpReader.sourceName].contains($0.name) }
        let aggregator = UsageAggregator(readers: readers)

        let result = await aggregator.aggregateUsage(for: fixture.request)

        XCTAssertEqual(result.usageData.totalTokens, 60)
        XCTAssertEqual(result.usageData.sourceStats.map(\.source).sorted(), ["Amp", "Factory Droid"])
        XCTAssertEqual(result.usageData.perModel.count, 2)
        XCTAssertEqual(
            Set(result.usageData.perModel.flatMap(\.sources)),
            ["Amp", "Factory Droid"])
        XCTAssertEqual(
            Set(result.usageData.perModel.flatMap(\.providers)),
            ["anthropic", "openai"])
        XCTAssertTrue(result.usageData.perModel.allSatisfy { !$0.isPriceKnown })
        XCTAssertEqual(
            Set(result.usageData.projectStats.map(\.name)),
            ["AmpProject", "DroidProject"])
        XCTAssertEqual(
            Set(result.usageData.sessionStats.map(\.source)),
            ["Amp", "Factory Droid"])
        XCTAssertEqual(
            Set(result.usageData.sessionStats.compactMap(\.sessionID)),
            ["T-integration", "droid-integration"])

        let jsonData = try XCTUnwrap(
            UsageExport.jsonString(for: result.usageData).data(using: .utf8))
        let json = try XCTUnwrap(
            JSONSerialization.jsonObject(with: jsonData) as? [String: Any])
        let sources = try XCTUnwrap(json["sources"] as? [[String: Any]])
        let models = try XCTUnwrap(json["models"] as? [[String: Any]])
        let sessions = try XCTUnwrap(json["sessions"] as? [[String: Any]])

        XCTAssertEqual(
            Set(sources.compactMap { $0["source"] as? String }),
            ["Amp", "Factory Droid"])
        XCTAssertEqual(
            Set(sessions.compactMap { $0["source"] as? String }),
            ["Amp", "Factory Droid"])
        XCTAssertTrue(models.allSatisfy { $0["isPriceKnown"] as? Bool == false })
        XCTAssertEqual(
            Set(models.flatMap { $0["providers"] as? [String] ?? [] }),
            ["anthropic", "openai"])

        let modelRows = UsageExport.csvString(for: result.usageData)
            .split(separator: "\n")
            .filter { $0.hasPrefix("model,") }
        XCTAssertEqual(modelRows.count, 2)
        XCTAssertTrue(UsageExport.csvString(for: result.usageData).contains("providers"))
        XCTAssertTrue(modelRows.contains { $0.contains("anthropic") })
        XCTAssertTrue(modelRows.contains { $0.contains("openai") })
        XCTAssertTrue(modelRows.allSatisfy {
            $0.split(separator: ",", omittingEmptySubsequences: false)[11].isEmpty
        })
    }

    func test_ampDecodeDiagnosticNamesSourceAndStageWithoutPayload() async throws {
        let fixture = try DroidAmpIntegrationFixture()
        defer { fixture.remove() }
        try FileManager.default.createDirectory(
            at: fixture.ampRoot,
            withIntermediateDirectories: true)
        try Data("{".utf8).write(
            to: fixture.ampRoot.appendingPathComponent("broken.json"))
        let aggregator = UsageAggregator(readers: [
            AmpReader(threadsURLOverride: fixture.ampRoot),
        ])

        let result = await aggregator.aggregateUsage(for: fixture.request)

        XCTAssertEqual(result.readerStatuses.count, 1)
        XCTAssertEqual(result.readerStatuses.first?.name, "Amp")
        XCTAssertEqual(result.readerStatuses.first?.state, .failed)
        XCTAssertEqual(result.readerStatuses.first?.message, "Amp thread decode failed")
    }

    func test_remoteMappingPreservesKnownZeroAndUnknownCostProvenance() throws {
        let start = try XCTUnwrap(
            ISO8601DateFormatter().date(from: "2026-08-20T00:00:00Z"))
        let end = try XCTUnwrap(
            ISO8601DateFormatter().date(from: "2026-08-21T00:00:00Z"))
        let snapshot = RemoteUsageSnapshot(
            device: RemoteDeviceDescriptor(
                id: "device-1",
                name: "build-server",
                platform: "linux"),
            generatedAt: end,
            coveredFrom: start,
            coveredTo: end,
            tokenEvents: [
                RemoteTokenEvent(
                    timestamp: start.addingTimeInterval(60),
                    source: FactoryDroidReader.sourceName,
                    model: "known-zero-model",
                    inputTokens: 10,
                    outputTokens: 0,
                    cacheReadTokens: 0,
                    cacheWriteTokens: 0,
                    reasoningTokens: 0,
                    cost: 0,
                    costIsKnown: true),
                RemoteTokenEvent(
                    timestamp: start.addingTimeInterval(120),
                    source: FactoryDroidReader.sourceName,
                    model: "unknown-cost-model",
                    inputTokens: 20,
                    outputTokens: 0,
                    cacheReadTokens: 0,
                    cacheWriteTokens: 0,
                    reasoningTokens: 0,
                    cost: 99,
                    costIsKnown: false),
            ],
            activityEvents: [])

        let slice = try XCTUnwrap(RemoteUsageMapper().usageSlice(
            from: snapshot,
            startDate: start,
            endDate: end))
        let stats = UsageReportBuilder.buildModelStats(
            from: slice.usage,
            startDate: start,
            endDate: end)

        XCTAssertEqual(slice.usage.cost, 0)
        XCTAssertEqual(slice.usage.tokenEvents.map(\.cost), [0, 0])
        XCTAssertEqual(slice.usage.tokenEvents.map(\.costIsKnown), [true, false])
        XCTAssertEqual(stats.first { $0.modelID == "known-zero-model" }?.isPriceKnown, true)
        XCTAssertEqual(stats.first { $0.modelID == "unknown-cost-model" }?.isPriceKnown, false)
    }
}

private struct DroidAmpIntegrationFixture {
    let root: URL
    let droidRoot: URL
    let ampRoot: URL
    let start = ISO8601DateFormatter().date(from: "2026-08-20T00:00:00Z")!
    let end = ISO8601DateFormatter().date(from: "2026-08-21T00:00:00Z")!

    init() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("toki-droid-amp-integration-\(UUID().uuidString)")
        droidRoot = root.appendingPathComponent(".factory/sessions")
        ampRoot = root.appendingPathComponent(".local/share/amp/threads")
        try FileManager.default.createDirectory(at: droidRoot, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: ampRoot, withIntermediateDirectories: true)
    }

    var request: UsageAggregationRequest {
        UsageAggregationRequest(
            start: start,
            end: end,
            enabledReaderNames: [
                FactoryDroidReader.sourceName: true,
                AmpReader.sourceName: true,
            ],
            includesEmptySourceRows: false)
    }

    func writeDroid() throws {
        let settings: [String: Any] = [
            "model": "unpriced-droid-model",
            "providerLock": "openai",
            "tokenUsage": [
                "inputTokens": 20,
                "outputTokens": 5,
            ],
        ]
        let settingsURL = droidRoot.appendingPathComponent("droid-integration.settings.json")
        try JSONSerialization.data(withJSONObject: settings, options: [.sortedKeys])
            .write(to: settingsURL)
        try Data(
            """
            {"type":"session_start","id":"droid-integration","cwd":"/tmp/DroidProject"}
            {"type":"message","id":"droid-assistant","timestamp":"2026-08-20T10:00:00Z","message":{"role":"assistant"}}
            """.utf8)
            .write(to: droidRoot.appendingPathComponent("droid-integration.jsonl"))
        try FileManager.default.setAttributes(
            [.modificationDate: ISO8601DateFormatter().date(from: "2026-08-20T10:01:00Z")!],
            ofItemAtPath: settingsURL.path)
    }

    func writeAmp() throws {
        let thread: [String: Any] = [
            "id": "T-integration",
            "created": Int64(start.timeIntervalSince1970 * 1000),
            "environment": ["workspaceRoot": "/tmp/AmpProject"],
            "messages": [
                [
                    "role": "assistant",
                    "messageId": 1,
                    "createdAt": "2026-08-20T11:00:00Z",
                    "usage": [
                        "model": "claude-unpriced-amp-model",
                        "inputTokens": 30,
                        "outputTokens": 5,
                    ],
                ],
            ],
        ]
        try JSONSerialization.data(withJSONObject: thread, options: [.sortedKeys])
            .write(to: ampRoot.appendingPathComponent("T-integration.json"))
    }

    func remove() {
        try? FileManager.default.removeItem(at: root)
    }
}
