import Foundation
import TokiUsageCore
import XCTest
@testable import Toki

@MainActor
final class PanelModelDetailPresentationTests: XCTestCase {
    func test_matchingUsageAndContextRowsCombineIntoOnePresentation() throws {
        let usage = makeModelDetailUsage(inputTokens: 40, outputTokens: 10)
        let report = makeModelDetailReport(modelID: "model-a", usage: usage)
        let contextRows = [
            makeContextRow(id: "other", model: "model-b", source: "Cursor", tokens: 500),
            makeContextRow(id: "small", model: "model-a", source: "Other", tokens: 100),
            makeContextRow(id: "large", model: "model-a", source: "Cursor", tokens: 200),
        ]

        let presentation = try XCTUnwrap(panelModelDetailPresentation(
            modelID: "model-a",
            scopeTitle: "All Devices",
            fallbackStartDate: modelDetailStart,
            fallbackEndDate: modelDetailEnd,
            modelReports: [report],
            contextOnlyModels: contextRows))

        XCTAssertEqual(presentation.report, report)
        XCTAssertEqual(presentation.scopeTitle, "All Devices")
        XCTAssertEqual(presentation.startDate, usage.date)
        XCTAssertEqual(presentation.endDate, usage.endDate)
        XCTAssertEqual(presentation.contextOnlyStats.map(\.id), ["large", "small"])
        XCTAssertFalse(presentation.isContextOnly)
    }

    func test_contextOnlyModelProducesLimitedPresentation() throws {
        let context = makeContextRow(
            id: "context",
            model: "context-model",
            source: "Cursor",
            tokens: 200_000)

        let presentation = try XCTUnwrap(panelModelDetailPresentation(
            modelID: "context-model",
            scopeTitle: "This Mac",
            fallbackStartDate: modelDetailStart,
            fallbackEndDate: modelDetailEnd,
            modelReports: [],
            contextOnlyModels: [context]))

        XCTAssertTrue(presentation.isContextOnly)
        XCTAssertNil(presentation.report)
        XCTAssertEqual(presentation.contextOnlyStats, [context])
        XCTAssertEqual(presentation.startDate, modelDetailStart)
        XCTAssertEqual(presentation.endDate, modelDetailEnd)
        XCTAssertTrue(presentation.projects.isEmpty)
        XCTAssertTrue(presentation.sources.isEmpty)
        XCTAssertTrue(presentation.sessions.isEmpty)
        XCTAssertTrue(presentation.activeBuckets.isEmpty)
        XCTAssertTrue(presentation.tokenComponents.isEmpty)
    }

    func test_detailRowsAreFilteredAndSortedDeterministically() throws {
        let newest = modelDetailStart.addingTimeInterval(300)
        let usage = makeModelDetailUsage(
            inputTokens: 30,
            outputTokens: 20,
            unclassifiedTokens: 10,
            projects: [
                makeProject(id: "zero", name: "Zero", tokens: 0, cost: 0),
                makeProject(id: "a", name: "A", tokens: 30, cost: 1),
                makeProject(id: "b", name: "B", tokens: 30, cost: 2),
                makeProject(id: "c", name: "C", tokens: 10, cost: 3),
            ],
            sources: [
                makeSource(name: "Zero", tokens: 0, cost: 0),
                makeSource(name: "B", tokens: 40, cost: 1),
                makeSource(name: "A", tokens: 40, cost: 2),
            ],
            sessions: [
                makeSession(id: "old", lastActivityAt: newest.addingTimeInterval(-100), tokens: 40),
                makeSession(id: "new-b", lastActivityAt: newest, tokens: 10),
                makeSession(id: "new-a", lastActivityAt: newest, tokens: 20),
            ],
            buckets: [
                makeBucket(offset: 0, tokens: 10, cost: 3),
                makeBucket(offset: 3600, tokens: 20, cost: 1),
                makeBucket(offset: 7200, tokens: 20, cost: 2),
                makeBucket(offset: 10800, tokens: 0, cost: 0),
            ])
        let report = makeModelDetailReport(modelID: "model-a", usage: usage)

        let presentation = try XCTUnwrap(panelModelDetailPresentation(
            modelID: "model-a",
            scopeTitle: "All Devices",
            fallbackStartDate: modelDetailStart,
            fallbackEndDate: modelDetailEnd,
            modelReports: [report],
            contextOnlyModels: []))

        XCTAssertEqual(presentation.projects.map(\.id), ["b", "a", "c"])
        XCTAssertEqual(presentation.sources.map(\.source), ["A", "B"])
        XCTAssertEqual(presentation.sessions.map(\.id), ["new-a", "new-b", "old"])
        XCTAssertEqual(presentation.activeBuckets.map(\.cost), [2, 1, 3])
        XCTAssertEqual(
            presentation.tokenComponents.map(\.kind),
            [.input, .output, .unclassified])
    }

    func test_incompleteAttributionAndZeroRowsRemainExplicit() throws {
        let usage = makeModelDetailUsage(
            inputTokens: 20,
            unclassifiedTokens: 80,
            isModelAttributionComplete: false)
        let report = makeModelDetailReport(modelID: "partial", usage: usage)

        let presentation = try XCTUnwrap(panelModelDetailPresentation(
            modelID: "partial",
            scopeTitle: "All Devices",
            fallbackStartDate: modelDetailStart,
            fallbackEndDate: modelDetailEnd,
            modelReports: [report],
            contextOnlyModels: [
                makeContextRow(id: "zero", model: "partial", source: "Cursor", tokens: 0),
            ]))

        XCTAssertTrue(presentation.hasIncompleteAttribution)
        XCTAssertEqual(presentation.tokenComponents.map(\.kind), [.input, .unclassified])
        XCTAssertTrue(presentation.contextOnlyStats.isEmpty)
        XCTAssertNil(panelModelDetailPresentation(
            modelID: "missing",
            scopeTitle: "All Devices",
            fallbackStartDate: modelDetailStart,
            fallbackEndDate: modelDetailEnd,
            modelReports: [report],
            contextOnlyModels: []))
    }
}

let modelDetailStart = Date(timeIntervalSince1970: 1_750_000_000)
let modelDetailEnd = modelDetailStart.addingTimeInterval(86400)

func makeModelDetailUsage(
    inputTokens: Int = 0,
    outputTokens: Int = 0,
    unclassifiedTokens: Int = 0,
    projects: [ProjectUsageStat] = [],
    sources: [SourceStat] = [],
    sessions: [SessionUsageStat] = [],
    buckets: [UsageTimeBucket] = [],
    isModelAttributionComplete: Bool = true) -> UsageData {
    UsageData(
        date: modelDetailStart,
        endDate: modelDetailEnd,
        inputTokens: inputTokens,
        outputTokens: outputTokens,
        cacheReadTokens: 0,
        cacheWriteTokens: 0,
        reasoningTokens: 0,
        unclassifiedTokens: unclassifiedTokens,
        cost: 4,
        activeSeconds: 120,
        perModel: [],
        sourceStats: sources,
        timeBuckets: buckets,
        projectStats: projects,
        sessionStats: sessions,
        isModelAttributionComplete: isModelAttributionComplete)
}

func makeModelDetailReport(
    modelID: String,
    usage: UsageData) -> UsageModelReport {
    UsageModelReport(
        modelID: modelID,
        summary: ModelStat(
            id: modelID,
            totalTokens: usage.totalTokens,
            cost: usage.cost,
            activeSeconds: usage.activeSeconds,
            wallClockSeconds: usage.workTime.wallClockSeconds,
            sources: usage.sourceStats.map(\.source),
            isPriceKnown: true),
        usageData: usage)
}

private func makeProject(
    id: String,
    name: String,
    tokens: Int,
    cost: Double) -> ProjectUsageStat {
    ProjectUsageStat(
        id: id,
        name: name,
        path: "/tmp/\(name)",
        quality: .exact,
        sources: ["Codex"],
        sessionCount: tokens > 0 ? 1 : 0,
        inputTokens: tokens,
        outputTokens: 0,
        cacheReadTokens: 0,
        cacheWriteTokens: 0,
        reasoningTokens: 0,
        cost: cost,
        firstActivityAt: modelDetailStart,
        lastActivityAt: modelDetailEnd)
}

private func makeSource(
    name: String,
    tokens: Int,
    cost: Double) -> SourceStat {
    SourceStat(
        source: name,
        inputTokens: tokens,
        outputTokens: 0,
        cacheReadTokens: 0,
        cacheWriteTokens: 0,
        reasoningTokens: 0,
        cost: cost,
        activeSeconds: 0)
}

private func makeSession(
    id: String,
    lastActivityAt: Date,
    tokens: Int) -> SessionUsageStat {
    SessionUsageStat(
        id: id,
        source: "Codex",
        projectName: "Toki",
        projectPath: "/tmp/Toki",
        sessionID: id,
        sessionLabel: id,
        quality: .exact,
        models: ["model-a"],
        inputTokens: tokens,
        outputTokens: 0,
        cacheReadTokens: 0,
        cacheWriteTokens: 0,
        reasoningTokens: 0,
        cost: 1,
        firstActivityAt: lastActivityAt.addingTimeInterval(-60),
        lastActivityAt: lastActivityAt)
}

private func makeBucket(
    offset: TimeInterval,
    tokens: Int,
    cost: Double) -> UsageTimeBucket {
    UsageTimeBucket(
        startDate: modelDetailStart.addingTimeInterval(offset),
        endDate: modelDetailStart.addingTimeInterval(offset + 3600),
        inputTokens: tokens,
        outputTokens: 0,
        cacheReadTokens: 0,
        cacheWriteTokens: 0,
        reasoningTokens: 0,
        cost: cost)
}

func makeContextRow(
    id: String,
    model: String,
    source: String,
    tokens: Int) -> ContextOnlyModelStat {
    ContextOnlyModelStat(
        id: id,
        model: model,
        source: source,
        contextTokens: tokens,
        quality: .contextOnly)
}
