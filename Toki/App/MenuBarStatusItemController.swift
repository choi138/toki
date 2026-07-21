import AppKit

@MainActor
final class MenuBarStatusItemController {
    private(set) var statusItem: NSStatusItem?

    private var runFrames: [NSImage] = []
    private var staticIcon: NSImage?
    private var currentFrame = 0
    private var animationTimer: Timer?
    private var animationFrameInterval = RabbitRunAnimationSpeed.defaultFrameInterval

    var button: NSStatusBarButton? {
        statusItem?.button
    }

    private var isAnimating: Bool {
        animationTimer != nil
    }

    func setup(target: AnyObject, action: Selector) {
        guard statusItem == nil else { return }
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem = item
        staticIcon = NSImage(named: "MenuBarIcon")
        staticIcon?.isTemplate = true
        item.button?.image = staticIcon
        item.button?.action = action
        item.button?.target = target
        loadRunFrames()
    }

    func applyActivityState(isActive: Bool, tokenVelocity: Double) {
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

    func stop() {
        stopAnimation()
    }
}

private extension MenuBarStatusItemController {
    func loadRunFrames() {
        runFrames = (0...).lazy
            .map { String(format: "rabbit_run_%02d", $0) }
            .prefix(while: { Bundle.main.url(forResource: $0, withExtension: "png") != nil })
            .compactMap { name -> NSImage? in
                guard let url = Bundle.main.url(forResource: name, withExtension: "png"),
                      let image = NSImage(contentsOf: url) else { return nil }
                image.isTemplate = true
                return image
            }
    }

    func startAnimation(frameInterval: TimeInterval) {
        guard !runFrames.isEmpty else { return }
        animationFrameInterval = frameInterval
        let timer = Timer(
            timeInterval: frameInterval,
            repeats: true) { [weak self] _ in
                Task { @MainActor [weak self] in
                    guard let self, let button else { return }
                    button.image = runFrames[currentFrame % runFrames.count]
                    currentFrame &+= 1
                }
            }
        RunLoop.main.add(timer, forMode: .common)
        animationTimer = timer
    }

    func stopAnimation() {
        animationTimer?.invalidate()
        animationTimer = nil
        currentFrame = 0
        button?.image = staticIcon
    }

    func updateAnimationSpeed(frameInterval: TimeInterval) {
        guard isAnimating,
              abs(animationFrameInterval - frameInterval) >= RabbitRunAnimationSpeed.changeThreshold else {
            return
        }

        animationTimer?.invalidate()
        animationTimer = nil
        startAnimation(frameInterval: frameInterval)
    }
}

enum RabbitRunAnimationSpeed {
    static let defaultFrameInterval: TimeInterval = 0.09
    static let changeThreshold: TimeInterval = 0.006

    private static let speedBands: [(tokensPerSecond: Double, frameInterval: TimeInterval)] = [
        (0, 0.09),
        (20, 0.055),
        (40, 0.035),
        (60, 0.023),
        (80, 0.016),
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
