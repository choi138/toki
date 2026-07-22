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

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItemController.setup(target: self, action: #selector(togglePanel))
        panelController.setup()
        activityController.start()
    }

    func applicationWillTerminate(_ notification: Notification) {
        panelController.stop()
        activityController.stop()
        statusItemController.stop()
    }

    @objc private func togglePanel() {
        guard let button = statusItemController.button else { return }
        panelController.toggle(relativeTo: button)
    }
}
