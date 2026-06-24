import AppKit
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var popover: NSPopover!
    private let tokenVelocityMonitor = TokenVelocityMonitor()
    private let tokenVelocityState = TokenVelocityState()

    private var runFrames: [NSImage] = []
    private var staticIcon: NSImage?
    private var currentFrame = 0
    private var animationTimer: Timer?
    private var animationFrameInterval = RabbitRunAnimationSpeed.defaultFrameInterval
    private var activityCheckTimer: Timer?
    private var isActivityCheckInFlight = false

    private var isAnimating: Bool {
        animationTimer != nil
    }

    private enum Timing {
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

    private func startAnimation(frameInterval: TimeInterval) {
        guard !runFrames.isEmpty else { return }
        animationFrameInterval = frameInterval
        let timer = Timer(
            timeInterval: frameInterval,
            repeats: true) { [weak self] _ in
                Task { @MainActor [weak self] in
                    guard let self, let button = statusItem.button else { return }
                    button.image = runFrames[currentFrame % runFrames.count]
                    currentFrame &+= 1
                }
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

    private func updateAnimationSpeed(frameInterval: TimeInterval) {
        guard isAnimating,
              abs(animationFrameInterval - frameInterval) >= RabbitRunAnimationSpeed.changeThreshold else {
            return
        }

        animationTimer?.invalidate()
        animationTimer = nil
        startAnimation(frameInterval: frameInterval)
    }

    // MARK: - Activity Detection

    private func startActivityChecks() {
        checkActivityInBackground()
        let checkTimer = Timer(
            timeInterval: Timing.activityCheck,
            repeats: true) { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.checkActivityInBackground()
                }
            }
        checkTimer.tolerance = 1.0
        RunLoop.main.add(checkTimer, forMode: .common)
        activityCheckTimer = checkTimer
    }

    private func checkActivityInBackground() {
        guard !isActivityCheckInFlight else { return }
        isActivityCheckInFlight = true
        let tokenVelocityMonitor = tokenVelocityMonitor

        // File I/O on background queue to avoid blocking the main run loop
        DispatchQueue.global(qos: .utility).async {
            let activityState = ActivityMonitor.currentState()

            Task {
                let velocitySample: TokenVelocitySample
                if activityState.isCodexActive {
                    velocitySample = await tokenVelocityMonitor.sample()
                } else {
                    await tokenVelocityMonitor.reset()
                    velocitySample = .zero()
                }

                await MainActor.run { [weak self] in
                    guard let self else { return }
                    isActivityCheckInFlight = false
                    tokenVelocityState.update(velocitySample)
                    applyAnimationState(
                        isActive: activityState.isAnyToolActive,
                        tokenVelocity: velocitySample.tokensPerSecond)
                }
            }
        }
    }

    private func applyAnimationState(isActive: Bool, tokenVelocity: Double) {
        let frameInterval = RabbitRunAnimationSpeed.frameInterval(tokensPerSecond: tokenVelocity)
        let shouldStart = isActive && !isAnimating
        let shouldStop = !isActive && isAnimating

        if shouldStart {
            startAnimation(frameInterval: frameInterval)
        } else if isActive {
            updateAnimationSpeed(frameInterval: frameInterval)
        }
        if shouldStop { stopAnimation() }
    }
}

enum RabbitRunAnimationSpeed {
    static let defaultFrameInterval: TimeInterval = 0.09
    static let changeThreshold: TimeInterval = 0.006

    private static let speedBands: [(tokensPerSecond: Double, frameInterval: TimeInterval)] = [
        (0, 0.09),
        (200, 0.055),
        (1000, 0.035),
        (5000, 0.023),
        (10000, 0.016),
    ]

    static func frameInterval(tokensPerSecond: Double) -> TimeInterval {
        guard tokensPerSecond > 0 else { return defaultFrameInterval }
        guard let firstBand = speedBands.first,
              let lastBand = speedBands.last else { return defaultFrameInterval }
        guard tokensPerSecond < lastBand.tokensPerSecond else { return lastBand.frameInterval }

        var lowerBand = firstBand
        for upperBand in speedBands.dropFirst() {
            if tokensPerSecond <= upperBand.tokensPerSecond {
                let normalizedVelocity = (tokensPerSecond - lowerBand.tokensPerSecond)
                    / (upperBand.tokensPerSecond - lowerBand.tokensPerSecond)
                return lowerBand.frameInterval
                    + (upperBand.frameInterval - lowerBand.frameInterval) * normalizedVelocity
            }
            lowerBand = upperBand
        }

        return lastBand.frameInterval
    }
}

private extension AppDelegate {
    // MARK: - Popover

    func setupPopover() {
        popover = NSPopover()
        popover.contentSize = NSSize(
            width: UsagePanelLayout.width,
            height: UsagePanelLayout.height)
        popover.behavior = .transient
        popover.contentViewController = NSHostingController(
            rootView: UsagePanelView(tokenVelocityState: tokenVelocityState))
    }

    @objc func togglePopover() {
        guard let button = statusItem.button else { return }
        if popover.isShown {
            popover.performClose(nil)
        } else {
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            NSApp.activate(ignoringOtherApps: true)
        }
    }
}
