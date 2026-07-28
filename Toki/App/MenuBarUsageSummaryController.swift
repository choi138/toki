import AppKit
import Foundation

struct MenuBarUsageSummary: Equatable {
    let totalTokens: Int
    let cost: Double
    let hasUnpricedUsage: Bool
}

func menuBarUsageSummaryTitle(for summary: MenuBarUsageSummary) -> String {
    let cost = summary.cost.formattedCost()
    return summary.hasUnpricedUsage ? "~\(cost)" : cost
}

func menuBarUsageToolTip(for summary: MenuBarUsageSummary) -> String {
    let estimate = "Estimated cost \(menuBarUsageSummaryTitle(for: summary))"
    let unpricedNote = summary.hasUnpricedUsage ? " (excludes unpriced usage)" : ""
    return "Toki — Today: \(summary.totalTokens.formattedTokens()) tokens · \(estimate)\(unpricedNote)"
}

func menuBarUsageContainsUnpricedModels(_ models: [ModelStat]) -> Bool {
    models.contains { !$0.isPriceKnown && $0.totalTokens > 0 }
}

/// Keeps the status item's compact cost readout fresh while the panel is
/// closed. The loop only aggregates when the menu bar cost setting is on.
@MainActor
final class MenuBarUsageSummaryController {
    private let statusItemController: MenuBarStatusItemController
    private let fetchSummary: () async -> MenuBarUsageSummary?
    private var loopTask: Task<Void, Never>?
    private var settingObserver: NSObjectProtocol?

    init(
        statusItemController: MenuBarStatusItemController,
        fetchSummary: (() async -> MenuBarUsageSummary?)? = nil) {
        self.statusItemController = statusItemController
        self.fetchSummary = fetchSummary ?? Self.makeDefaultFetchSummary()
    }

    func start() {
        restartLoop()
        settingObserver = NotificationCenter.default.addObserver(
            forName: .usagePanelMenuBarCostSettingDidChange,
            object: nil,
            queue: .main) { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.restartLoop()
                }
            }
    }

    func stop() {
        loopTask?.cancel()
        loopTask = nil
        if let settingObserver {
            NotificationCenter.default.removeObserver(settingObserver)
            self.settingObserver = nil
        }
    }

    private func restartLoop() {
        loopTask?.cancel()
        loopTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                await self?.tick()
                let intervalSeconds = UsagePanelSettings().refreshIntervalSeconds
                try? await Task.sleep(for: .seconds(intervalSeconds))
            }
        }
    }

    private func tick() async {
        guard UsagePanelSettings.isMenuBarCostEnabled() else {
            statusItemController.applySummary(title: nil, toolTip: nil)
            return
        }
        guard let summary = await fetchSummary() else { return }
        statusItemController.applySummary(
            title: menuBarUsageSummaryTitle(for: summary),
            toolTip: menuBarUsageToolTip(for: summary))
    }

    private static func makeDefaultFetchSummary() -> () async -> MenuBarUsageSummary? {
        let aggregator = UsageAggregator(readers: UsageAggregator.defaultReaders)
        return { @MainActor in
            let settings = UsagePanelSettings()
            let calendar = Calendar.autoupdatingCurrent
            let start = calendar.startOfDay(for: Date())
            guard let end = calendar.date(byAdding: .day, value: 1, to: start) else { return nil }
            let request = UsageAggregationRequest(
                start: start,
                end: end,
                enabledReaderNames: settings.normalizedReaderSettings(for: aggregator.readerNames),
                includesEmptySourceRows: false)
            let result = await aggregator.aggregateUsage(for: request)
            return MenuBarUsageSummary(
                totalTokens: result.usageData.totalTokens,
                cost: result.usageData.cost,
                hasUnpricedUsage: menuBarUsageContainsUnpricedModels(result.usageData.perModel))
        }
    }
}
