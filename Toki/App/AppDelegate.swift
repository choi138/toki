import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let tokenVelocityState = TokenVelocityState()
    private let statusItemController = MenuBarStatusItemController()

    private lazy var activityController = MenuBarActivityController(
        statusItemController: statusItemController,
        tokenVelocityState: tokenVelocityState)
    private lazy var panelController = MenuBarPanelController(
        tokenVelocityState: tokenVelocityState) { [weak self] isVisible in
            self?.activityController.setPanelVisible(isVisible)
        }

    private lazy var summaryController = MenuBarUsageSummaryController(
        statusItemController: statusItemController)

    private var pricingCatalogRefreshTask: Task<Void, Never>?

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItemController.setup(target: self, action: #selector(statusItemClicked))
        panelController.setup()
        activityController.start()
        summaryController.start()
        startPricingCatalogRefreshLoop()
    }

    func applicationWillTerminate(_ notification: Notification) {
        panelController.stop()
        activityController.stop()
        summaryController.stop()
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

    private func makeStatusItemMenu() -> NSMenu {
        let menu = NSMenu()
        let openItem = NSMenuItem(
            title: "Open Usage Panel",
            action: #selector(togglePanel),
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
