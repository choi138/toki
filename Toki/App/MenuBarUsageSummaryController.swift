import AppKit
import Foundation

struct MenuBarUsageSummary: Equatable {
    let totalTokens: Int
    let cost: Double
    let hasUnpricedUsage: Bool
    let hasReaderFailures: Bool

    var isEstimated: Bool {
        hasUnpricedUsage || hasReaderFailures
    }
}

func menuBarUsageSummaryTitle(for summary: MenuBarUsageSummary) -> String {
    let cost = summary.cost.formattedCost()
    return summary.isEstimated ? "~\(cost)" : cost
}

func menuBarUsageToolTip(for summary: MenuBarUsageSummary) -> String {
    let estimate = "Estimated cost \(menuBarUsageSummaryTitle(for: summary))"
    var exclusions: [String] = []
    if summary.hasUnpricedUsage {
        exclusions.append("unpriced usage")
    }
    if summary.hasReaderFailures {
        exclusions.append("data from failed readers")
    }
    let exclusionNote = exclusions.isEmpty ? "" : " (excludes \(exclusions.joined(separator: " and ")))"
    return "Toki — Today: \(summary.totalTokens.formattedTokens()) tokens · \(estimate)\(exclusionNote)"
}

func menuBarUsageContainsUnpricedModels(_ models: [ModelStat], totalTokens: Int) -> Bool {
    if models.contains(where: { !$0.isPriceKnown && $0.totalTokens > 0 }) {
        return true
    }
    let attributedTokens = models.reduce(0) { $0 + max(0, $1.totalTokens) }
    return attributedTokens < max(0, totalTokens)
}

func menuBarUsageContainsReaderFailures(_ statuses: [ReaderStatus]) -> Bool {
    statuses.contains { $0.state == .failed }
}

enum MenuBarUsageSummaryPresentationPolicy {
    static func shouldApplySummary(isCancelled: Bool, isEnabled: Bool) -> Bool {
        !isCancelled && isEnabled
    }
}

/// Keeps the status item's compact cost readout fresh while the panel is
/// closed. The loop only aggregates when the menu bar cost setting is on.
@MainActor
final class MenuBarUsageSummaryController {
    private let statusItemController: MenuBarStatusItemController
    private let fetchSummary: () async -> MenuBarUsageSummary?
    private var loopTask: Task<Void, Never>?
    private var refreshObservers: [NSObjectProtocol] = []

    init(
        statusItemController: MenuBarStatusItemController,
        fetchSummary: (() async -> MenuBarUsageSummary?)? = nil) {
        self.statusItemController = statusItemController
        self.fetchSummary = fetchSummary ?? Self.makeDefaultFetchSummary()
    }

    func start() {
        restartLoop()
        let notificationNames: [Notification.Name] = [
            .usagePanelMenuBarCostSettingDidChange,
            .usagePanelRefreshIntervalDidChange,
            .usagePanelModelPricingDidChange,
        ]
        refreshObservers = notificationNames.map { name in
            NotificationCenter.default.addObserver(
                forName: name,
                object: nil,
                queue: .main) { [weak self] _ in
                    Task { @MainActor [weak self] in
                        self?.restartLoop()
                    }
                }
        }
    }

    func stop() {
        loopTask?.cancel()
        loopTask = nil
        for observer in refreshObservers {
            NotificationCenter.default.removeObserver(observer)
        }
        refreshObservers.removeAll()
    }

    private func restartLoop() {
        loopTask?.cancel()
        loopTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                await self?.tick()
                let intervalSeconds = UsagePanelSettings.currentRefreshIntervalSeconds()
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
        guard MenuBarUsageSummaryPresentationPolicy.shouldApplySummary(
            isCancelled: Task.isCancelled,
            isEnabled: UsagePanelSettings.isMenuBarCostEnabled()) else { return }
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
                hasUnpricedUsage: menuBarUsageContainsUnpricedModels(
                    result.usageData.perModel,
                    totalTokens: result.usageData.totalTokens),
                hasReaderFailures: menuBarUsageContainsReaderFailures(result.readerStatuses))
        }
    }
}
