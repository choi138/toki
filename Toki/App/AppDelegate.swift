import AppKit
import SwiftUI

private enum PanelWindow {
    static let cornerRadius: CGFloat = 8
    static let gap: CGFloat = 6
    static let screenInset: CGFloat = 8

    static var size: NSSize {
        NSSize(width: UsagePanelLayout.width, height: UsagePanelLayout.height)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var panel: NSPanel!

    private var runFrames: [NSImage] = []
    private var staticIcon: NSImage?
    private var currentFrame = 0
    private var animationTimer: Timer?
    private var activityCheckTimer: Timer?
    private var localEventMonitor: Any?
    private var globalEventMonitor: Any?
    private var isActivityCheckInFlight = false

    private var isAnimating: Bool {
        animationTimer != nil
    }

    private enum Timing {
        static let frameInterval: TimeInterval = 0.09 // ~11fps
        static let activityCheck: TimeInterval = 5.0
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        setupStatusItem()
        setupPanel()
        loadRunFrames()
        startActivityChecks()
    }

    func applicationWillTerminate(_ notification: Notification) {
        stopPanelEventMonitoring()
    }

    // MARK: - Status Item

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        staticIcon = NSImage(named: "MenuBarIcon")
        staticIcon?.isTemplate = true

        guard let button = statusItem.button else { return }
        button.image = staticIcon
        button.action = #selector(togglePanel)
        button.target = self
    }

    // MARK: - Run Animation

    private func loadRunFrames() {
        runFrames = (0...).lazy
            .map { String(format: "rabbit_run_%02d", $0) }
            .prefix(while: { Bundle.main.url(forResource: $0, withExtension: "png") != nil })
            .compactMap { name -> NSImage? in
                guard let url = Bundle.main.url(forResource: name, withExtension: "png"),
                      let img = NSImage(contentsOf: url) else { return nil }
                img.isTemplate = true
                return img
            }
    }

    private func startAnimation() {
        guard !runFrames.isEmpty else { return }
        currentFrame = 0
        let timer = Timer(
            timeInterval: Timing.frameInterval,
            repeats: true) { [weak self] _ in
                guard let self, let button = statusItem.button else { return }
                button.image = runFrames[currentFrame % runFrames.count]
                currentFrame &+= 1
            }
        RunLoop.main.add(timer, forMode: .common)
        animationTimer = timer
    }

    private func stopAnimation() {
        animationTimer?.invalidate()
        animationTimer = nil
        currentFrame = 0
        statusItem.button?.image = staticIcon
    }

    // MARK: - Activity Detection

    private func startActivityChecks() {
        checkActivityInBackground()
        let checkTimer = Timer(
            timeInterval: Timing.activityCheck,
            repeats: true) { [weak self] _ in
                self?.checkActivityInBackground()
            }
        checkTimer.tolerance = 1.0
        RunLoop.main.add(checkTimer, forMode: .common)
        activityCheckTimer = checkTimer
    }

    private func checkActivityInBackground() {
        guard !isActivityCheckInFlight else { return }
        isActivityCheckInFlight = true

        // File I/O on background queue to avoid blocking the main run loop
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let isActive = ActivityMonitor.isAnyToolActive()
            DispatchQueue.main.async {
                guard let self else { return }
                self.isActivityCheckInFlight = false
                self.applyAnimationState(isActive: isActive)
            }
        }
    }

    private func applyAnimationState(isActive: Bool) {
        let shouldStart = isActive && !isAnimating
        let shouldStop = !isActive && isAnimating

        if shouldStart { startAnimation() }
        if shouldStop { stopAnimation() }
    }
}

// MARK: - Panel

private extension AppDelegate {
    func setupPanel() {
        panel = MenuBarPanel(
            contentRect: NSRect(origin: .zero, size: PanelWindow.size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false)
        panel.backgroundColor = .clear
        panel.becomesKeyOnlyIfNeeded = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.contentViewController = NSHostingController(rootView: UsagePanelView())
        panel.hasShadow = true
        panel.isMovable = false
        panel.isOpaque = false
        panel.isReleasedWhenClosed = false
        panel.level = .statusBar

        panel.contentView?.wantsLayer = true
        panel.contentView?.layer?.cornerRadius = PanelWindow.cornerRadius
        panel.contentView?.layer?.masksToBounds = true
    }

    @objc func togglePanel() {
        guard let button = statusItem.button else { return }
        if panel.isVisible {
            closePanel()
        } else {
            showPanel(relativeTo: button)
        }
    }

    private func showPanel(relativeTo view: NSView) {
        guard let frame = panelFrame(relativeTo: view) else { return }
        panel.setFrame(frame, display: true)
        panel.orderFrontRegardless()
        startPanelEventMonitoring()
    }

    private func closePanel() {
        panel.orderOut(nil)
        stopPanelEventMonitoring()
    }

    private func panelFrame(relativeTo view: NSView) -> NSRect? {
        guard let statusItemFrame = statusItemFrame() else { return nil }
        let visibleFrame = (view.window?.screen ?? NSScreen.main)?.visibleFrame ?? .zero

        var origin = NSPoint(
            x: statusItemFrame.midX - PanelWindow.size.width / 2,
            y: statusItemFrame.minY - PanelWindow.size.height - PanelWindow.gap)

        origin.x = min(
            max(origin.x, visibleFrame.minX + PanelWindow.screenInset),
            visibleFrame.maxX - PanelWindow.size.width - PanelWindow.screenInset)

        if origin.y < visibleFrame.minY + PanelWindow.screenInset {
            origin.y = statusItemFrame.maxY + PanelWindow.gap
        }

        if origin.y + PanelWindow.size.height > visibleFrame.maxY - PanelWindow.screenInset {
            origin.y = visibleFrame.maxY - PanelWindow.size.height - PanelWindow.screenInset
        }

        return NSRect(origin: origin, size: PanelWindow.size)
    }

    private func startPanelEventMonitoring() {
        guard localEventMonitor == nil, globalEventMonitor == nil else { return }

        localEventMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [
                .leftMouseDown,
                .rightMouseDown,
                .keyDown,
            ]) { [weak self] event in
                guard let self else { return event }

                if event.type == .keyDown, event.keyCode == 53 {
                    closePanel()
                    return nil
                }

                if shouldClosePanel(for: event) {
                    closePanel()
                }

                return event
            }

        globalEventMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [
                .leftMouseDown,
                .rightMouseDown,
            ]) { [weak self] event in
                guard let self, shouldClosePanel(for: event) else { return }
                closePanel()
            }
    }

    private func stopPanelEventMonitoring() {
        if let localEventMonitor {
            NSEvent.removeMonitor(localEventMonitor)
            self.localEventMonitor = nil
        }

        if let globalEventMonitor {
            NSEvent.removeMonitor(globalEventMonitor)
            self.globalEventMonitor = nil
        }
    }

    private func shouldClosePanel(for event: NSEvent) -> Bool {
        if let window = event.window, isPanelRelatedWindow(window) {
            return false
        }

        let location = eventLocationInScreen(event)
        if panel.frame.contains(location) {
            return false
        }

        if statusItemFrame()?.contains(location) == true {
            return false
        }

        return true
    }

    private func isPanelRelatedWindow(_ window: NSWindow) -> Bool {
        window == panel || window.parent == panel || panel.childWindows?.contains(window) == true
    }

    private func eventLocationInScreen(_ event: NSEvent) -> NSPoint {
        guard let window = event.window else { return event.locationInWindow }
        return window.convertPoint(toScreen: event.locationInWindow)
    }

    private func statusItemFrame() -> NSRect? {
        guard let button = statusItem.button, let statusItemWindow = button.window else { return nil }
        let statusItemRectInWindow = button.convert(button.bounds, to: nil)
        return statusItemWindow.convertToScreen(statusItemRectInWindow)
    }
}

private final class MenuBarPanel: NSPanel {
    override var canBecomeMain: Bool {
        false
    }

    override var canBecomeKey: Bool {
        false
    }
}
