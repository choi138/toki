import AppKit

func shouldStartPricingCatalogRefresh(isXCTestLoaded: Bool = NSClassFromString("XCTestCase") != nil) -> Bool {
    !isXCTestLoaded
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let tokenVelocityState = TokenVelocityState()
    private let cpuUsageState = ProcessCPUUsageState()
    private let statusItemController = MenuBarStatusItemController()

    private lazy var cpuUsageMonitor = ProcessCPUUsageMonitor(state: cpuUsageState)

    private lazy var activityController = MenuBarActivityController(
        statusItemController: statusItemController,
        tokenVelocityState: tokenVelocityState)
    private lazy var panelController = MenuBarPanelController(
        tokenVelocityState: tokenVelocityState,
        cpuUsageState: cpuUsageState) { [weak self] isVisible in
            self?.cpuUsageMonitor.setPanelVisible(isVisible)
            self?.activityController.setPanelVisible(isVisible)
            self?.summaryController.setPanelVisible(isVisible)
        }

    private lazy var summaryController = MenuBarUsageSummaryController(
        statusItemController: statusItemController)

    private var pricingCatalogRefreshTask: Task<Void, Never>?

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItemController.setup(target: self, action: #selector(statusItemClicked))
        panelController.setup()
        activityController.start()
        summaryController.start()
        if shouldStartPricingCatalogRefresh() {
            startPricingCatalogRefreshLoop()
        }
    }

    /// Stops app-owned monitors, panel controllers, and pending pricing work during termination.
    func applicationWillTerminate(_ notification: Notification) {
        summaryController.stop()
        panelController.stop()
        cpuUsageMonitor.stop()
        activityController.stop()
        statusItemController.stop()
        pricingCatalogRefreshTask?.cancel()
        pricingCatalogRefreshTask = nil
    }

    private func startPricingCatalogRefreshLoop() {
        pricingCatalogRefreshTask = Task {
            while !Task.isCancelled {
                let didChangePricing = await RemotePricingCatalogUpdater.shared.refreshIfNeeded(
                    isEnabled: UsagePanelSettings.isAutoUpdatePricingEnabled())
                if didChangePricing, !Task.isCancelled {
                    NotificationCenter.default.post(name: .usagePanelModelPricingDidChange, object: nil)
                }
                try? await Task.sleep(for: .seconds(3600))
            }
        }
    }

    @objc private func statusItemClicked() {
        if NSApp.currentEvent?.type == .rightMouseUp {
            statusItemController.showContextMenu(makeStatusItemMenu())
            return
        }
        togglePanel()
    }

    @objc private func togglePanel() {
        guard let button = statusItemController.button else { return }
        panelController.toggle(relativeTo: button)
    }

    @objc private func openPanel() {
        guard let button = statusItemController.button else { return }
        panelController.show(relativeTo: button)
    }

    private func makeStatusItemMenu() -> NSMenu {
        let menu = NSMenu()
        let openItem = NSMenuItem(
            title: "Open Usage Panel",
            action: #selector(openPanel),
            keyEquivalent: "")
        openItem.target = self
        menu.addItem(openItem)
        menu.addItem(.separator())
        let quitItem = NSMenuItem(
            title: "Quit Toki",
            action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: "q")
        menu.addItem(quitItem)
        return menu
    }
}
