import Foundation
import SwiftUI
import TokiUsageCore
import XCTest
@testable import Toki
@testable import TokiUsageReaders

final class UsageCoverageIntegrationTests: XCTestCase {
    @MainActor
    func test_partialHermesPreservesSelectedModelAndPeriodCacheUntilRecovery() async throws {
        let suiteName = "UsageCoverageIntegrationTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let state = PartialCoverageState()
        let service = UsageService(
            readers: [PartialCoverageReader(state: state)],
            settings: UsagePanelSettings(defaults: defaults, readerNames: ["Hermes"]),
            periodTokenTotalsCache: PeriodTokenTotalsCache(defaults: defaults))
        let day = try XCTUnwrap(Calendar.current.date(byAdding: .day, value: -2, to: Date()))
        service.selectDay(day)
        await service.refresh()
        service.selectModelScope(.model("shared-model"))
        for _ in 0..<200 where service.periodTokenTotals.map(\.totalTokens) != [400, 400, 400] {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertEqual(service.periodTokenTotals.map(\.totalTokens), [400, 400, 400])
        let successfulFetchedAt = service.lastPeriodTokenTotalsFetchedAt
        await state.setPartial(true)
        await service.refresh()
        await service.refreshPeriodTokenTotals()
        XCTAssertEqual(service.readerStatuses.first?.state, .partial)
        XCTAssertEqual(service.presentationSnapshot.combinedUsageData.totalTokens, 300)
        XCTAssertEqual(service.usageData.totalTokens, 400)
        XCTAssertEqual(service.periodTokenTotals.map(\.totalTokens), [400, 400, 400])
        XCTAssertEqual(service.lastPeriodTokenTotalsFetchedAt, successfulFetchedAt)
        service.selectModelScope(.all)
        XCTAssertEqual(service.usageData.totalTokens, 300)
        await state.setPartial(false)
        await service.refresh()
        XCTAssertEqual(service.usageData.totalTokens, 400)
        XCTAssertEqual(service.readerStatuses.first?.state, .loaded)
    }

    func test_realHermesPartialReadPreservesUsageReportsAndWarningStatus() async throws {
        let root = try makeHermesTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let database = root.appendingPathComponent("state.db")
        try createHermesStateDB(at: database, rows: [HermesSessionFixture(
            id: "synthetic-session", startedAt: "2026-04-10T09:00:00Z", model: "fixture-unknown-model",
            inputTokens: 100, outputTokens: 20, cacheReadTokens: 3, cacheWriteTokens: 4, reasoningTokens: 5,
            cwd: nil, gitRepoRoot: nil, estimatedCost: nil, actualCost: 0.25)])
        let broken = root.appendingPathComponent("profiles/broken/state.db")
        try FileManager.default.createDirectory(
            at: broken.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("synthetic-invalid-sqlite".utf8).write(to: broken)
        let ledger = HermesUsageLedger(fileURL: root.appendingPathComponent("cache/ledger.json"))
        try await ledger.refresh(observations: [], observedAt: tokiTestISODate("2026-04-10T08:00:00Z"))
        let reader = HermesReader(
            hermesHomeURL: root, includesProfiles: true, usesLegacyDefaultLedger: true,
            usageLedger: ledger, profileLedgerDirectory: root.appendingPathComponent("cache/profiles"),
            now: { tokiTestISODate("2026-04-10T12:00:00Z") })
        let request = UsageAggregationRequest(
            start: tokiTestISODate("2026-04-10T00:00:00Z"), end: tokiTestISODate("2026-04-11T00:00:00Z"),
            enabledReaderNames: [:], includesEmptySourceRows: false)
        let raw = try await reader.readUsage(from: request.start, to: request.end)
        XCTAssertEqual(raw.supplemental.first { $0.id == "hermes-profile-read-errors" }?.value, 1)
        let result = await UsageAggregator(readers: [reader]).aggregateUsage(for: request)
        let status = try XCTUnwrap(result.readerStatuses.first)
        XCTAssertEqual(status.state.rawValue, "partial")
        XCTAssertTrue(status.message?.contains("1 profile") == true)
        XCTAssertEqual(status.totalTokens, 132)
        XCTAssertEqual(result.usageData.totalTokens, 132)
        XCTAssertEqual(result.usageData.cost, 0.25, accuracy: 0.000001)
        XCTAssertEqual(result.usageData.activeSeconds, raw.activeSeconds, accuracy: 0.000001)
        XCTAssertEqual(result.modelReports["fixture-unknown-model"]?.usageData.totalTokens, 132)
        XCTAssertEqual(result.modelReports.values.reduce(0) { $0 + $1.summary.totalTokens }, 132)
        XCTAssertEqual(
            result.modelReports.values.reduce(0) { $0 + $1.summary.activeSeconds },
            raw.activeSeconds,
            accuracy: 0.000001)
        XCTAssertEqual(readerFailureNames(from: result.readerStatuses), ["Hermes"])
        XCTAssertTrue(menuBarUsageContainsReaderFailures(result.readerStatuses))
        XCTAssertFalse(panelUsageSelectionRequiresFallback(
            readerStatuses: result.readerStatuses, scope: .all, modelScope: .all))
        XCTAssertFalse(status.message?.contains(root.path) == true)
        let totals = await UsageAggregator(readers: [reader]).aggregateTotalTokenResult(for: request)
        XCTAssertEqual(totals.totalTokens, 132)
        XCTAssertTrue(totals.hasReaderFailures)
        XCTAssertEqual(totals.readerStatuses.first?.state.rawValue, "partial")
        XCTAssertEqual(totals.readerStatuses.first?.message, status.message)
        await attachPartialSourceRendering(result)
    }

    func test_realOpenClawUnknownPriceReachesModelReportWithoutBecomingFree() async throws {
        let root = try makeHermesTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("main/sessions/fixture.jsonl.deleted.custom")
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        let line = [
            #"{"type":"message","id":"m1","message":{"role":"assistant","model":"fixture-unknown-model","#,
            #""timestamp":"2026-04-10T09:00:00Z","usage":{"input":100,"output":20}}}"#,
        ].joined()
        XCTAssertNoThrow(try JSONSerialization.jsonObject(with: Data(line.utf8)))
        try Data(line.utf8).write(to: file)
        let request = UsageAggregationRequest(
            start: tokiTestISODate("2026-04-10T00:00:00Z"), end: tokiTestISODate("2026-04-11T00:00:00Z"),
            enabledReaderNames: [:], includesEmptySourceRows: false)
        let result = await UsageAggregator(readers: [OpenClawReader(agentsURLOverride: root)])
            .aggregateUsage(for: request)
        let model = try XCTUnwrap(result.modelReports["fixture-unknown-model"])
        XCTAssertEqual(model.usageData.totalTokens, 120)
        XCTAssertFalse(model.summary.isPriceKnown)
        XCTAssertEqual(model.usageData.cost, 0)
        XCTAssertEqual(result.usageData.totalTokens, model.usageData.totalTokens)
        XCTAssertEqual(result.usageData.activeSeconds, model.summary.activeSeconds, accuracy: 0.000001)
        XCTAssertEqual(result.readerStatuses.first?.state, .loaded)
    }

    @MainActor
    private func attachPartialSourceRendering(_ result: UsageAggregationResult) {
        let content = PanelSourceView(
            usage: result.usageData, originReports: [], selectedScope: .all, scopeTitle: "All Devices",
            readerStatuses: result.readerStatuses, isLoading: false, isRefreshing: false,
            onSelectOrigin: { _ in })
            .frame(width: 420)
            .background(Color(red: 0.08, green: 0.08, blue: 0.09))
        let renderer = ImageRenderer(content: content)
        renderer.scale = 2
        guard let image = renderer.nsImage else {
            XCTFail("Partial usage source view must render")
            return
        }
        let attachment = XCTAttachment(image: image)
        attachment.name = "Hermes partial usage and warning"
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}

private actor PartialCoverageState {
    var partial = false

    func setPartial(_ value: Bool) {
        partial = value
    }
}

private struct PartialCoverageReader: TokenReader {
    let name = "Hermes"
    let state: PartialCoverageState

    func readUsage(from _: Date, to _: Date) async throws -> RawTokenUsage {
        let partial = await state.partial
        let total = partial ? 300 : 400
        var usage = mockUsage(totalTokens: total)
        usage.perModel["shared-model"] = PerModelUsage(totalTokens: total, sources: [name])
        if partial {
            usage.supplemental.append(SupplementalUsage(
                id: "hermes-profile-read-errors", label: "Hermes profile read errors", value: 1,
                unit: .count, source: name, model: nil, includedInTotals: false, quality: .exact))
        }
        return usage
    }
}
