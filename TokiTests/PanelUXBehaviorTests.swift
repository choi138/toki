import AppKit
import XCTest
@testable import Toki

private final class StatusItemActionTarget: NSObject {
    @objc func performAction(_: Any?) {}
}

final class PanelUXBehaviorTests: XCTestCase {
    func test_menuBarUsageSummary_formatsTitleAndToolTip() {
        let summary = MenuBarUsageSummary(
            totalTokens: 1_234_000,
            cost: 4.2,
            hasUnpricedUsage: false,
            hasReaderFailures: false)

        XCTAssertEqual(menuBarUsageSummaryTitle(for: summary), 4.2.formattedCost())
        let toolTip = menuBarUsageToolTip(for: summary)
        XCTAssertTrue(toolTip.hasPrefix("Toki — Today: "))
        XCTAssertTrue(toolTip.contains(1_234_000.formattedTokens()))
        XCTAssertTrue(toolTip.contains(4.2.formattedCost()))
        XCTAssertTrue(toolTip.contains("Estimated cost"))
        XCTAssertFalse(toolTip.contains("excludes unpriced usage"))
    }

    func test_menuBarUsageSummary_marksIncompleteCostWhenUsageIsUnpriced() {
        let summary = MenuBarUsageSummary(
            totalTokens: 1_234_000,
            cost: 4.2,
            hasUnpricedUsage: true,
            hasReaderFailures: false)

        XCTAssertEqual(menuBarUsageSummaryTitle(for: summary), "~\(4.2.formattedCost())")
        XCTAssertTrue(menuBarUsageToolTip(for: summary).contains("excludes unpriced usage"))
    }

    func test_menuBarUsageSummary_marksIncompleteCostWhenReadersFail() {
        let summary = MenuBarUsageSummary(
            totalTokens: 1_234_000,
            cost: 4.2,
            hasUnpricedUsage: false,
            hasReaderFailures: true)

        XCTAssertEqual(menuBarUsageSummaryTitle(for: summary), "~\(4.2.formattedCost())")
        XCTAssertTrue(menuBarUsageToolTip(for: summary).contains("excludes data from failed readers"))
    }

    func test_menuBarUsageContainsUnpricedModels_ignoresEmptyModelsAndDetectsAttributionGaps() {
        let priced = makeModel(id: "priced", totalTokens: 10, isPriceKnown: true)
        let emptyUnpriced = makeModel(id: "empty", totalTokens: 0, isPriceKnown: false)
        let usedUnpriced = makeModel(id: "unpriced", totalTokens: 10, isPriceKnown: false)

        XCTAssertFalse(menuBarUsageContainsUnpricedModels([priced, emptyUnpriced], totalTokens: 10))
        XCTAssertTrue(menuBarUsageContainsUnpricedModels([priced, usedUnpriced], totalTokens: 20))
        XCTAssertTrue(menuBarUsageContainsUnpricedModels([priced], totalTokens: 100))
    }

    func test_readerFailureNames_returnsOnlyFailedReaders() {
        let statuses = [
            ReaderStatus(
                name: "Claude Code",
                state: .failed,
                message: "boom",
                lastReadAt: nil,
                totalTokens: 0,
                isOriginPartitioned: false),
            ReaderStatus(
                name: "Codex",
                state: .loaded,
                message: nil,
                lastReadAt: nil,
                totalTokens: 10,
                isOriginPartitioned: false),
            ReaderStatus(
                name: "Hermes",
                state: .disabled,
                message: nil,
                lastReadAt: nil,
                totalTokens: 0,
                isOriginPartitioned: false),
            ReaderStatus(
                name: "Cursor",
                state: .failed,
                message: nil,
                lastReadAt: nil,
                totalTokens: 0,
                isOriginPartitioned: false),
        ]

        XCTAssertEqual(readerFailureNames(from: statuses), ["Claude Code", "Cursor"])
        XCTAssertEqual(readerFailureNames(from: []), [])
        XCTAssertTrue(menuBarUsageContainsReaderFailures(statuses))
        XCTAssertFalse(menuBarUsageContainsReaderFailures(statuses.filter { $0.state != .failed }))
    }

    func test_menuBarSummaryPresentation_requiresActiveTaskAndEnabledSetting() {
        XCTAssertTrue(MenuBarUsageSummaryPresentationPolicy.shouldApplySummary(
            isCancelled: false,
            isEnabled: true))
        XCTAssertFalse(MenuBarUsageSummaryPresentationPolicy.shouldApplySummary(
            isCancelled: true,
            isEnabled: true))
        XCTAssertFalse(MenuBarUsageSummaryPresentationPolicy.shouldApplySummary(
            isCancelled: false,
            isEnabled: false))
    }

    func test_projectCollapseControl_requiresExpandedHiddenProjects() {
        XCTAssertTrue(PanelProjectExpansionPolicy.shouldShowCollapseControl(
            isExpanded: true,
            collapsedHiddenProjectCount: 3))
        XCTAssertFalse(PanelProjectExpansionPolicy.shouldShowCollapseControl(
            isExpanded: true,
            collapsedHiddenProjectCount: 0))
        XCTAssertFalse(PanelProjectExpansionPolicy.shouldShowCollapseControl(
            isExpanded: false,
            collapsedHiddenProjectCount: 3))
    }

    @MainActor
    func test_menuBarSummaryRestartsAfterReaderSettingsChange() async {
        let notificationCenter = NotificationCenter()
        let firstFetch = expectation(description: "Initial menu bar summary fetch")
        let secondFetch = expectation(description: "Reader change menu bar summary fetch")
        var fetchCount = 0
        let controller = MenuBarUsageSummaryController(
            statusItemController: MenuBarStatusItemController(),
            fetchSummary: {
                fetchCount += 1
                if fetchCount == 1 {
                    firstFetch.fulfill()
                } else if fetchCount == 2 {
                    secondFetch.fulfill()
                }
                return nil
            },
            notificationCenter: notificationCenter,
            isMenuBarCostEnabled: { true },
            refreshIntervalSeconds: { 3600 })
        controller.start()
        defer { controller.stop() }

        await fulfillment(of: [firstFetch], timeout: 1)
        notificationCenter.post(name: .usagePanelReaderSettingsDidChange, object: nil)
        await fulfillment(of: [secondFetch], timeout: 1)

        XCTAssertEqual(fetchCount, 2)
    }

    @MainActor
    func test_menuBarSummaryCancelsAndRestartsAfterRemoteSyncChange() async {
        let notificationCenter = NotificationCenter()
        let firstFetch = expectation(description: "Initial menu bar summary fetch")
        let firstFetchCancelled = expectation(description: "Initial fetch cancelled")
        let replacementFetch = expectation(description: "Remote sync replacement fetch")
        var fetchCount = 0
        let controller = MenuBarUsageSummaryController(
            statusItemController: MenuBarStatusItemController(),
            fetchSummary: {
                fetchCount += 1
                guard fetchCount == 1 else {
                    replacementFetch.fulfill()
                    return nil
                }
                firstFetch.fulfill()
                do {
                    try await Task.sleep(for: .seconds(3600))
                } catch {
                    firstFetchCancelled.fulfill()
                }
                return nil
            },
            notificationCenter: notificationCenter,
            isMenuBarCostEnabled: { true },
            refreshIntervalSeconds: { 3600 })
        controller.start()
        defer { controller.stop() }

        await fulfillment(of: [firstFetch], timeout: 1)
        notificationCenter.post(name: .usagePanelRemoteSyncDidChange, object: nil)
        await fulfillment(of: [firstFetchCancelled, replacementFetch], timeout: 1)

        XCTAssertEqual(fetchCount, 2)
    }

    func test_modelTokenShareUsesReportTotalAndClampsInvalidValues() {
        XCTAssertEqual(panelModelTokenShare(modelTokens: 10, reportTotalTokens: 100), 0.1, accuracy: 0.0001)
        XCTAssertEqual(panelModelTokenShare(modelTokens: 10, reportTotalTokens: 10), 1, accuracy: 0.0001)
        XCTAssertEqual(panelModelTokenShare(modelTokens: 20, reportTotalTokens: 10), 1, accuracy: 0.0001)
        XCTAssertEqual(panelModelTokenShare(modelTokens: 10, reportTotalTokens: 0), 0, accuracy: 0.0001)
    }

    private func makeModel(id: String, totalTokens: Int, isPriceKnown: Bool) -> ModelStat {
        ModelStat(
            id: id,
            totalTokens: totalTokens,
            cost: 0,
            activeSeconds: 0,
            sources: ["Test"],
            isPriceKnown: isPriceKnown)
    }
}

final class MenuBarSummaryPanelVisibilityTests: XCTestCase {
    @MainActor
    func test_menuBarSummarySuspendsWhilePanelIsVisibleAndRestartsWhenHidden() async {
        let firstFetch = expectation(description: "Initial menu bar summary fetch")
        let firstFetchCancelled = expectation(description: "Panel visibility cancels summary fetch")
        let replacementFetch = expectation(description: "Panel dismissal restarts summary fetch")
        var fetchCount = 0
        let controller = MenuBarUsageSummaryController(
            statusItemController: MenuBarStatusItemController(),
            fetchSummary: {
                fetchCount += 1
                guard fetchCount == 1 else {
                    replacementFetch.fulfill()
                    return nil
                }
                firstFetch.fulfill()
                do {
                    try await Task.sleep(for: .seconds(3600))
                } catch {
                    firstFetchCancelled.fulfill()
                }
                return nil
            },
            isMenuBarCostEnabled: { true },
            refreshIntervalSeconds: { 3600 })
        controller.start()
        defer { controller.stop() }

        await fulfillment(of: [firstFetch], timeout: 1)
        controller.setPanelVisible(true)
        await fulfillment(of: [firstFetchCancelled], timeout: 1)
        XCTAssertEqual(fetchCount, 1)

        controller.setPanelVisible(false)
        await fulfillment(of: [replacementFetch], timeout: 1)
        XCTAssertEqual(fetchCount, 2)
    }

    @MainActor
    func test_menuBarSummaryClearsDisabledCostWhilePanelIsVisible() async {
        let notificationCenter = NotificationCenter()
        let statusItemController = MenuBarStatusItemController()
        let actionTarget = StatusItemActionTarget()
        statusItemController.setup(
            target: actionTarget,
            action: #selector(StatusItemActionTarget.performAction(_:)))
        defer {
            if let statusItem = statusItemController.statusItem {
                NSStatusBar.system.removeStatusItem(statusItem)
            }
        }
        statusItemController.applySummary(title: "$4.20", toolTip: "Current cost")

        let disabledSettingRead = expectation(description: "Disabled menu bar setting read")
        var isMenuBarCostEnabled = true
        let controller = MenuBarUsageSummaryController(
            statusItemController: statusItemController,
            fetchSummary: { nil },
            notificationCenter: notificationCenter,
            isMenuBarCostEnabled: {
                if !isMenuBarCostEnabled {
                    disabledSettingRead.fulfill()
                }
                return isMenuBarCostEnabled
            },
            refreshIntervalSeconds: { 3600 })
        controller.start()
        defer { controller.stop() }

        controller.setPanelVisible(true)
        XCTAssertEqual(statusItemController.button?.title, " $4.20")

        isMenuBarCostEnabled = false
        notificationCenter.post(name: .usagePanelMenuBarCostSettingDidChange, object: nil)
        await fulfillment(of: [disabledSettingRead], timeout: 1)

        XCTAssertEqual(statusItemController.button?.title, "")
        XCTAssertEqual(statusItemController.button?.toolTip, "Toki")
    }
}
