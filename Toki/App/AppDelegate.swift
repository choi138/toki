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

    private var pricingCatalogRefreshTask: Task<Void, Never>?

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItemController.setup(target: self, action: #selector(togglePanel))
        panelController.setup()
        activityController.start()
        startPricingCatalogRefreshLoop()
    }

    func applicationWillTerminate(_ notification: Notification) {
        panelController.stop()
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

    @objc private func togglePanel() {
        guard let button = statusItemController.button else { return }
        panelController.toggle(relativeTo: button)
    }
}
