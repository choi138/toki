import AppKit
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var popover: NSPopover!

    private var runFrames: [NSImage] = []
    private var staticIcon: NSImage?
    private var currentFrame = 0
    private var animationTimer: Timer?
    private var activityCheckTimer: Timer?

    private var isAnimating: Bool {
        animationTimer != nil
    }

    private enum Timing {
        static let frameInterval: TimeInterval = 0.09 // ~11fps
        static let activityCheck: TimeInterval = 5.0
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        setupStatusItem()
        setupPopover()
        loadRunFrames()
        startActivityChecks()
    }

    // MARK: - Status Item

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        guard let button = statusItem.button else { return }
        staticIcon = NSImage(named: "MenuBarIcon")
        staticIcon?.isTemplate = true
        button.image = staticIcon
        button.action = #selector(togglePopover)
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
        // File I/O on background queue to avoid blocking the main run loop
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let isActive = ActivityMonitor.isAnyToolActive()
            DispatchQueue.main.async {
                self?.applyAnimationState(isActive: isActive)
            }
        }
    }

    private func applyAnimationState(isActive: Bool) {
        let shouldStart = isActive && !isAnimating
        let shouldStop = !isActive && isAnimating

        if shouldStart { startAnimation() }
        if shouldStop { stopAnimation() }
    }

    // MARK: - Popover

    private func setupPopover() {
        popover = NSPopover()
        popover.contentSize = NSSize(
            width: UsagePanelLayout.width,
            height: UsagePanelLayout.height)
        popover.behavior = .transient
        popover.contentViewController = NSHostingController(rootView: UsagePanelView())
    }

    @objc private func togglePopover() {
        guard let button = statusItem.button else { return }
        if popover.isShown {
            popover.performClose(nil)
        } else {
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            NSApp.activate(ignoringOtherApps: true)
        }
    }
}
