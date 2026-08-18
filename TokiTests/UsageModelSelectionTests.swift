import Foundation
import TokiUsageCore
import XCTest
@testable import Toki

@MainActor
final class UsageModelSelectionTests: XCTestCase {
    func test_modelReportsGroupSourceRowsByCanonicalModelID() throws {
        let interval = modelSelectionInterval
        let usage = modelSelectionMultiSourceUsage(interval: interval)

        let sourceRows = UsageReportBuilder.buildModelStats(
            from: usage,
            startDate: interval.start,
            endDate: interval.end)
        let reports = UsageReportBuilder.buildModelReports(
            from: usage,
            startDate: interval.start,
            endDate: interval.end)
        let report = try XCTUnwrap(reports["shared-model"])

        XCTAssertEqual(sourceRows.filter { $0.modelID == "shared-model" }.count, 2)
        XCTAssertEqual(reports.count, 2)
        XCTAssertEqual(report.modelID, "shared-model")
        XCTAssertEqual(report.summary.id, "shared-model")
        XCTAssertEqual(report.summary.totalTokens, 30)
        XCTAssertEqual(report.summary.sources, ["Claude Code", "Codex"])
        XCTAssertEqual(report.usageData.totalTokens, 30)
        XCTAssertEqual(report.usageData.inputTokens, 30)
        XCTAssertEqual(report.usageData.sourceStats.map(\.totalTokens).reduce(0, +), 30)
        XCTAssertEqual(Set(report.usageData.sourceStats.map(\.source)), ["Claude Code", "Codex"])
        XCTAssertEqual(report.usageData.projectStats.map(\.totalTokens).reduce(0, +), 30)
        XCTAssertEqual(report.usageData.filteredModelID, "shared-model")
        XCTAssertTrue(report.usageData.isModelAttributionComplete)
        XCTAssertEqual(report.usageData.workTime.agentSeconds, 90, accuracy: 0.001)
        XCTAssertEqual(report.usageData.workTime.wallClockSeconds, 60, accuracy: 0.001)
    }

    func test_aggregateOnlyModelUsesUnclassifiedTokensAndPreservesAuthoritativeTime() throws {
        let interval = modelSelectionInterval
        let usage = RawTokenUsage(
            inputTokens: 120,
            cost: 1.2,
            perModel: [
                "aggregate-model": PerModelUsage(
                    totalTokens: 120,
                    cost: 1.2,
                    activeSeconds: 45,
                    wallClockSeconds: 30,
                    sources: ["Legacy"]),
            ])

        let report = try XCTUnwrap(UsageReportBuilder.buildModelReports(
            from: usage,
            startDate: interval.start,
            endDate: interval.end)["aggregate-model"])

        XCTAssertEqual(report.usageData.totalTokens, 120)
        XCTAssertEqual(report.usageData.unclassifiedTokens, 120)
        XCTAssertEqual(report.usageData.inputTokens, 0)
        XCTAssertEqual(report.usageData.cost, 1.2, accuracy: 0.000_001)
        XCTAssertEqual(report.usageData.activeSeconds, 45, accuracy: 0.001)
        XCTAssertEqual(report.usageData.workTime.wallClockSeconds, 30, accuracy: 0.001)
        XCTAssertEqual(report.usageData.sourceStats.first?.unclassifiedTokens, 120)
        XCTAssertTrue(report.usageData.projectStats.isEmpty)
        XCTAssertTrue(report.usageData.timeBuckets.allSatisfy { $0.totalTokens == 0 })
        XCTAssertFalse(report.usageData.isModelAttributionComplete)
    }

    func test_eventsThatExceedAuthoritativeTotalsDoNotOverstateFilteredDetails() throws {
        let interval = modelSelectionInterval
        var usage = RawTokenUsage(
            inputTokens: 50,
            cost: 0.5,
            perModel: [
                "bounded-model": PerModelUsage(
                    totalTokens: 50,
                    cost: 0.5,
                    sources: ["Codex"]),
            ],
            perModelBySource: [
                ModelSourceUsageKey(modelID: "bounded-model", source: "Codex"): PerModelUsage(
                    totalTokens: 50,
                    cost: 0.5,
                    sources: ["Codex"]),
            ])
        usage.recordTokenEvent(
            timestamp: interval.start.addingTimeInterval(60),
            source: "Codex",
            model: "bounded-model",
            inputTokens: 80,
            outputTokens: 0,
            cost: 0.8,
            attribution: UsageAttribution(projectPath: "/tmp/over", quality: .exact))

        let report = try XCTUnwrap(UsageReportBuilder.buildModelReports(
            from: usage,
            startDate: interval.start,
            endDate: interval.end)["bounded-model"])

        XCTAssertEqual(report.usageData.totalTokens, 50)
        XCTAssertEqual(report.usageData.unclassifiedTokens, 50)
        XCTAssertEqual(report.usageData.sourceStats.map(\.totalTokens).reduce(0, +), 50)
        XCTAssertEqual(report.usageData.sourceStats.map(\.cost).reduce(0, +), 0.5, accuracy: 0.000_001)
        XCTAssertTrue(report.usageData.projectStats.isEmpty)
        XCTAssertFalse(report.usageData.isModelAttributionComplete)
    }

    func test_mismatchedEventSourceFallsBackToAuthoritativeSourceTotals() throws {
        let interval = modelSelectionInterval
        var usage = RawTokenUsage(
            inputTokens: 50,
            perModel: [
                "source-model": PerModelUsage(totalTokens: 50, sources: ["Codex"]),
            ],
            perModelBySource: [
                ModelSourceUsageKey(modelID: "source-model", source: "Codex"): PerModelUsage(
                    totalTokens: 50,
                    sources: ["Codex"]),
            ])
        usage.recordTokenEvent(
            timestamp: interval.start.addingTimeInterval(60),
            source: "Claude Code",
            model: "source-model",
            inputTokens: 50,
            outputTokens: 0)

        let report = try XCTUnwrap(UsageReportBuilder.buildModelReports(
            from: usage,
            startDate: interval.start,
            endDate: interval.end)["source-model"])

        XCTAssertEqual(report.usageData.totalTokens, 50)
        XCTAssertEqual(report.usageData.unclassifiedTokens, 50)
        XCTAssertEqual(report.usageData.sourceStats.first?.source, "Codex")
        XCTAssertEqual(report.usageData.sourceStats.first?.totalTokens, 50)
        XCTAssertTrue(report.usageData.projectStats.isEmpty)
        XCTAssertFalse(report.usageData.isModelAttributionComplete)
    }

    func test_mixedAndExplicitSentinelEventsShareOneCanonicalReport() throws {
        let interval = modelSelectionInterval
        let key = UsageModelGrouping.mixedOrUnattributedKey
        var usage = RawTokenUsage(
            inputTokens: 30,
            perModel: [
                key: PerModelUsage(totalTokens: 30, sources: ["Hermes"]),
            ])
        usage.recordTokenEvent(
            timestamp: interval.start.addingTimeInterval(60),
            source: "Hermes",
            model: nil,
            inputTokens: 10,
            outputTokens: 0)
        usage.recordTokenEvent(
            timestamp: interval.start.addingTimeInterval(120),
            source: "Hermes",
            model: key,
            inputTokens: 20,
            outputTokens: 0)

        let reports = UsageReportBuilder.buildModelReports(
            from: usage,
            startDate: interval.start,
            endDate: interval.end)
        let report = try XCTUnwrap(reports[key])

        XCTAssertEqual(reports.count, 1)
        XCTAssertEqual(report.summary.displayModelID, UsageModelGrouping.mixedOrUnattributedLabel)
        XCTAssertEqual(report.usageData.totalTokens, 30)
        XCTAssertEqual(report.usageData.inputTokens, 30)
        XCTAssertTrue(report.usageData.isModelAttributionComplete)
    }

    func test_eventModelIDMatchesTheCanonicalModelStatKey() throws {
        let interval = modelSelectionInterval
        var usage = RawTokenUsage(inputTokens: 12)
        usage.recordTokenEvent(
            timestamp: interval.start.addingTimeInterval(60),
            source: "Mock",
            model: "<synthetic>",
            inputTokens: 12,
            outputTokens: 0)

        let report = try XCTUnwrap(UsageReportBuilder.buildModelReports(
            from: usage,
            startDate: interval.start,
            endDate: interval.end)["<synthetic>"])

        XCTAssertEqual(report.modelID, "<synthetic>")
        XCTAssertEqual(report.usageData.inputTokens, 12)
        XCTAssertTrue(report.usageData.isModelAttributionComplete)
    }
}

extension UsageModelSelectionTests {
    func test_deviceAndModelScopesComposeWithoutLosingSelection() async {
        let localUsage = modelSelectionAggregateUsage(
            models: ["model-a": 10, "model-b": 20],
            source: "Codex")
        let remoteUsage = modelSelectionAggregateUsage(
            models: ["model-a": 30],
            source: "Remote Codex")
        let remoteID = UsageOriginID.remote(deviceID: "remote-a")
        let readers: [any TokenReader] = [
            ModelSelectionFixedReader(name: "Codex", usage: localUsage),
            ModelSelectionOriginReader(
                name: "Remote Devices",
                slices: [modelSelectionRemoteSlice(usage: remoteUsage)]),
        ]
        let aggregator = UsageAggregator(readers: readers)
        let request = UsageAggregationRequest(
            start: modelSelectionInterval.start,
            end: modelSelectionInterval.end,
            enabledReaderNames: [:],
            includesEmptySourceRows: false)

        let result = await aggregator.aggregateUsage(for: request)
        let allModelATokens = await aggregator.aggregateTotalTokens(
            for: request,
            modelScope: .model("model-a"))
        let remoteModelATokens = await aggregator.aggregateTotalTokens(
            for: request,
            scope: .origin(remoteID),
            modelScope: .model("model-a"))

        XCTAssertEqual(result.modelReports["model-a"]?.usageData.totalTokens, 40)
        XCTAssertEqual(
            result.originReports.first { $0.id == .local }?.modelReports["model-a"]?.usageData.totalTokens,
            10)
        XCTAssertEqual(
            result.originReports.first { $0.id == remoteID }?.modelReports["model-a"]?.usageData.totalTokens,
            30)
        XCTAssertEqual(allModelATokens, 40)
        XCTAssertEqual(remoteModelATokens, 30)

        let service = UsageService(readers: readers)
        service.selectDay(modelSelectionInterval.start)
        await service.refresh()
        service.selectModelScope(.model("model-b"))

        XCTAssertEqual(service.usageData.totalTokens, 20)
        XCTAssertEqual(service.selectedModelID, "model-b")
        XCTAssertEqual(service.availableModelReports.map(\.modelID), ["model-a", "model-b"])
        XCTAssertEqual(
            service.originReports.first { $0.id == .local }?.usageData.totalTokens,
            20)
        XCTAssertEqual(
            service.originReports.first { $0.id == remoteID }?.usageData.totalTokens,
            0)

        service.selectUsageScope(.origin(remoteID))
        XCTAssertEqual(service.selectedModelID, "model-b")
        XCTAssertEqual(service.usageData.totalTokens, 0)
        XCTAssertEqual(service.availableModelReports.map(\.modelID), ["model-a"])

        service.selectModelScope(.all)
        XCTAssertNil(service.selectedModelID)
        XCTAssertEqual(service.usageData.totalTokens, 30)
    }

    func test_modelSelectionUpdatesYesterdayPeriodTotalsAndCacheIdentity() async throws {
        let suiteName = "UsageModelSelectionTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        let yesterday = try XCTUnwrap(calendar.date(byAdding: .day, value: -1, to: today))
        let recorder = MockReaderRecorder()
        let reader = MockReader(name: "Mock", recorder: recorder) { startDate, _ in
            let selectedTokens = if startDate == today {
                110
            } else if startDate == yesterday {
                70
            } else {
                30
            }
            return modelSelectionAggregateUsage(
                models: ["selected-model": selectedTokens, "other-model": 500],
                source: "Mock")
        }
        let service = UsageService(
            readers: [reader],
            periodTokenTotalsCache: PeriodTokenTotalsCache(defaults: defaults))

        await service.refresh()
        service.selectModelScope(.model("selected-model"))

        let deadline = Date().addingTimeInterval(3)
        while service.yesterdayTotalTokens != 70
            || service.periodTokenTotals.map(\.totalTokens) != [30, 30, 30],
            Date() < deadline {
            try? await Task.sleep(for: .milliseconds(10))
        }

        XCTAssertEqual(service.usageData.totalTokens, 110)
        XCTAssertEqual(service.yesterdayTotalTokens, 70)
        XCTAssertEqual(service.periodTokenTotals.map(\.totalTokens), [30, 30, 30])

        let allModelsKey = PeriodTokenTotalsCacheKey(
            endDate: modelSelectionInterval.end,
            enabledReaderNames: ["Mock": true],
            scope: .all,
            modelScope: .all)
        let selectedModelKey = PeriodTokenTotalsCacheKey(
            endDate: modelSelectionInterval.end,
            enabledReaderNames: ["Mock": true],
            scope: .all,
            modelScope: .model("selected-model"))
        XCTAssertNotEqual(allModelsKey, selectedModelKey)
    }

    func test_filteredExportIncludesAttributionMetadataAndAlignedCSVColumns() throws {
        let usage = RawTokenUsage(
            inputTokens: 120,
            cost: 1.2,
            perModel: [
                "aggregate-model": PerModelUsage(
                    totalTokens: 120,
                    cost: 1.2,
                    sources: ["Legacy"]),
            ])
        let report = try XCTUnwrap(UsageReportBuilder.buildModelReports(
            from: usage,
            startDate: modelSelectionInterval.start,
            endDate: modelSelectionInterval.end)["aggregate-model"])

        let jsonData = try XCTUnwrap(UsageExport.jsonString(for: report.usageData).data(using: .utf8))
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: jsonData) as? [String: Any])
        let totals = try XCTUnwrap(object["totals"] as? [String: Any])
        let csv = UsageExport.csvString(for: report.usageData)
        let rows = csv.split(separator: "\n").map {
            $0.split(separator: ",", omittingEmptySubsequences: false)
        }

        XCTAssertEqual(object["filteredModel"] as? String, "aggregate-model")
        XCTAssertEqual(object["isModelAttributionComplete"] as? Bool, false)
        XCTAssertEqual(totals["unclassifiedTokens"] as? Int, 120)
        XCTAssertTrue(rows.first?.contains("unclassified_tokens") == true)
        XCTAssertEqual(Set(rows.map(\.count)).count, 1)
        XCTAssertTrue(csv.contains("total,All,,,0,0,0,0,0,120,120"))
    }

    func test_modelFilterPresentationUsesFriendlyNamesAndBoundedShares() {
        XCTAssertEqual(panelModelDisplayName("claude-sonnet-4-6"), "sonnet-4-6")
        XCTAssertEqual(
            panelModelDisplayName(UsageModelGrouping.mixedOrUnattributedKey),
            UsageModelGrouping.mixedOrUnattributedLabel)
        XCTAssertEqual(panelModelTokenShare(modelTokens: 30, reportTotalTokens: 120), 0.25)
        XCTAssertEqual(panelModelTokenShare(modelTokens: 150, reportTotalTokens: 120), 1)
        XCTAssertEqual(panelModelTokenShare(modelTokens: 0, reportTotalTokens: 120), 0)
    }

    func test_modelsTabSelectionFiltersOnlyItsModelRowsAndPreservesUnavailableSelection() {
        let reports = ["model-a", "model-b"].map { modelID in
            UsageModelReport(
                modelID: modelID,
                summary: ModelStat(
                    id: modelID,
                    totalTokens: 10,
                    cost: 0.1,
                    activeSeconds: 10,
                    sources: ["Mock"],
                    isPriceKnown: true),
                usageData: .empty)
        }
        let contextOnlyModels = [
            ContextOnlyModelStat(
                id: "model-a|context",
                model: "model-a",
                source: "Cursor",
                contextTokens: 100,
                quality: .contextOnly),
            ContextOnlyModelStat(
                id: "context-model|context",
                model: "context-model",
                source: "Cursor",
                contextTokens: 200,
                quality: .contextOnly),
        ]

        let options = panelModelOptions(
            modelReports: reports,
            contextOnlyModels: contextOnlyModels)

        XCTAssertEqual(
            options,
            [
                PanelModelOption(id: "model-a", isContextOnly: false),
                PanelModelOption(id: "model-b", isContextOnly: false),
                PanelModelOption(id: "context-model", isContextOnly: true),
            ])
        XCTAssertEqual(
            panelFilteredModelReports(reports, selectedModelID: "model-a").map(\.modelID),
            ["model-a"])
        XCTAssertEqual(
            panelFilteredContextOnlyModels(contextOnlyModels, selectedModelID: "model-a").map(\.id),
            ["model-a|context"])
        XCTAssertFalse(panelModelSelectionIsUnavailable(selectedModelID: "context-model", options: options))
        XCTAssertTrue(panelModelSelectionIsUnavailable(selectedModelID: "missing-model", options: options))
        XCTAssertFalse(panelModelSelectionIsUnavailable(selectedModelID: nil, options: options))
    }
}

private let modelSelectionInterval = DateInterval(
    start: tokiTestISODate("2026-07-01T00:00:00Z"),
    end: tokiTestISODate("2026-07-02T00:00:00Z"))

private func modelSelectionMultiSourceUsage(interval: DateInterval) -> RawTokenUsage {
    var usage = RawTokenUsage(
        inputTokens: 35,
        cost: 0.35,
        perModel: [
            "shared-model": PerModelUsage(
                totalTokens: 30,
                cost: 0.3,
                activeSeconds: 90,
                wallClockSeconds: 60,
                sources: ["Codex", "Claude Code"]),
            "other-model": PerModelUsage(
                totalTokens: 5,
                cost: 0.05,
                sources: ["Codex"]),
        ],
        perModelBySource: [
            ModelSourceUsageKey(modelID: "shared-model", source: "Codex"): PerModelUsage(
                totalTokens: 10,
                cost: 0.1,
                activeSeconds: 30,
                wallClockSeconds: 30,
                sources: ["Codex"]),
            ModelSourceUsageKey(modelID: "shared-model", source: "Claude Code"): PerModelUsage(
                totalTokens: 20,
                cost: 0.2,
                activeSeconds: 60,
                wallClockSeconds: 60,
                sources: ["Claude Code"]),
            ModelSourceUsageKey(modelID: "other-model", source: "Codex"): PerModelUsage(
                totalTokens: 5,
                cost: 0.05,
                sources: ["Codex"]),
        ])
    usage.recordTokenEvent(
        timestamp: interval.start.addingTimeInterval(60),
        source: "Codex",
        model: "shared-model",
        inputTokens: 10,
        outputTokens: 0,
        cost: 0.1,
        attribution: UsageAttribution(
            projectPath: "/tmp/first",
            sessionID: "first",
            quality: .exact))
    usage.recordTokenEvent(
        timestamp: interval.start.addingTimeInterval(120),
        source: "Claude Code",
        model: "shared-model",
        inputTokens: 20,
        outputTokens: 0,
        cost: 0.2,
        attribution: UsageAttribution(
            projectPath: "/tmp/second",
            sessionID: "second",
            quality: .exact))
    usage.recordTokenEvent(
        timestamp: interval.start.addingTimeInterval(180),
        source: "Codex",
        model: "other-model",
        inputTokens: 5,
        outputTokens: 0,
        cost: 0.05)
    return usage
}

private struct ModelSelectionFixedReader: TokenReader {
    let name: String
    let usage: RawTokenUsage

    func readUsage(from _: Date, to _: Date) async throws -> RawTokenUsage {
        usage
    }
}

private struct ModelSelectionOriginReader: OriginPartitionedTokenReader {
    let name: String
    let slices: [UsageOriginSlice]

    func readUsageByOrigin(from _: Date, to _: Date) async throws -> [UsageOriginSlice] {
        slices
    }
}

private func modelSelectionAggregateUsage(
    models: [String: Int],
    source: String) -> RawTokenUsage {
    RawTokenUsage(
        inputTokens: models.values.reduce(0, +),
        perModel: models.mapValues {
            PerModelUsage(totalTokens: $0, sources: [source])
        })
}

private func modelSelectionRemoteSlice(usage: RawTokenUsage) -> UsageOriginSlice {
    UsageOriginSlice(
        origin: .remote(
            deviceID: "remote-a",
            name: "worker",
            platform: "linux",
            lastUpdatedAt: modelSelectionInterval.start),
        usage: usage,
        sourceStats: [
            SourceStat(
                source: "Remote Codex",
                inputTokens: usage.inputTokens,
                outputTokens: usage.outputTokens,
                cacheReadTokens: usage.cacheReadTokens,
                cacheWriteTokens: usage.cacheWriteTokens,
                reasoningTokens: usage.reasoningTokens,
                cost: usage.cost,
                activeSeconds: usage.activeSeconds),
        ])
}
