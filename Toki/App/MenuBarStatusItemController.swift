import AppKit

enum MenuBarStatusItemMetrics {
    static let staticIconPointSize = NSSize(width: 20, height: 20)
    static let animationIconPointSize = NSSize(width: 22, height: 22)
    static let animationCropPixelSize = NSSize(width: 24, height: 24)
}

func preparedMenuBarImage(_ image: NSImage) -> NSImage {
    let preparedImage = (image.copy() as? NSImage) ?? image
    preparedImage.size = MenuBarStatusItemMetrics.staticIconPointSize
    preparedImage.isTemplate = true
    return preparedImage
}

func menuBarAnimationCropRect(for pixelSize: NSSize) -> NSRect {
    let cropSize = NSSize(
        width: min(pixelSize.width, MenuBarStatusItemMetrics.animationCropPixelSize.width),
        height: min(pixelSize.height, MenuBarStatusItemMetrics.animationCropPixelSize.height))
    return NSRect(
        x: ((pixelSize.width - cropSize.width) / 2).rounded(.down),
        y: ((pixelSize.height - cropSize.height) / 2).rounded(.down),
        width: cropSize.width,
        height: cropSize.height)
}

func preparedMenuBarAnimationFrame(_ image: NSImage) -> NSImage {
    var proposedRect = NSRect(origin: .zero, size: image.size)
    guard let sourceImage = image.cgImage(
        forProposedRect: &proposedRect,
        context: nil,
        hints: nil) else {
        return preparedMenuBarImage(image)
    }

    let pixelSize = NSSize(
        width: CGFloat(sourceImage.width),
        height: CGFloat(sourceImage.height))
    guard let croppedImage = sourceImage.cropping(
        to: menuBarAnimationCropRect(for: pixelSize)) else {
        return preparedMenuBarImage(image)
    }

    let preparedImage = NSImage(
        cgImage: croppedImage,
        size: MenuBarStatusItemMetrics.animationIconPointSize)
    preparedImage.isTemplate = true
    return preparedImage
}

@MainActor
final class MenuBarStatusItemController {
    private(set) var statusItem: NSStatusItem?

    private var runFrames: [NSImage] = []
    private var staticIcon: NSImage?
    private var currentFrame = 0
    private var animationTimer: Timer?
    private var animationLifecycle = RabbitRunAnimationLifecycle()
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
        staticIcon = NSImage(named: "MenuBarIcon").map(preparedMenuBarImage)
        item.button?.image = staticIcon
        item.button?.imagePosition = .imageOnly
        item.button?.imageScaling = .scaleNone
        item.button?.action = action
        item.button?.target = target
        item.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])
        item.button?.toolTip = "Toki"
        loadRunFrames()
    }

    /// Renders an optional compact summary (e.g. today's cost) next to the
    /// icon and refreshes the hover tooltip.
    func applySummary(title: String?, toolTip: String?) {
        guard let button else { return }
        if let title, !title.isEmpty {
            button.title = " \(title)"
            button.font = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .medium)
            button.imagePosition = .imageLeading
            statusItem?.length = NSStatusItem.variableLength
        } else {
            button.title = ""
            button.font = nil
            button.imagePosition = .imageOnly
            statusItem?.length = NSStatusItem.squareLength
        }
        button.toolTip = toolTip ?? "Toki"
    }

    /// Presents a context menu anchored to the status item. The menu is
    /// detached immediately afterwards so plain clicks keep toggling the
    /// panel.
    func showContextMenu(_ menu: NSMenu) {
        guard let statusItem else { return }
        statusItem.menu = menu
        statusItem.button?.performClick(nil)
        statusItem.menu = nil
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
                return preparedMenuBarAnimationFrame(image)
            }
    }

    func startAnimation(frameInterval: TimeInterval) {
        guard !runFrames.isEmpty else { return }
        animationFrameInterval = frameInterval
        let animationGeneration = animationLifecycle.start()
        let timer = Timer(
            timeInterval: frameInterval,
            repeats: true) { [weak self] _ in
                Task { @MainActor [weak self] in
                    guard let self,
                          animationLifecycle.shouldApplyFrame(for: animationGeneration),
                          let button else { return }
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
        animationLifecycle.stop()
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

struct RabbitRunAnimationLifecycle {
    private var activeGeneration: UInt?
    private var nextGeneration: UInt = 0

    mutating func start() -> UInt {
        nextGeneration &+= 1
        activeGeneration = nextGeneration
        return nextGeneration
    }

    mutating func stop() {
        activeGeneration = nil
    }

    func shouldApplyFrame(for generation: UInt) -> Bool {
        activeGeneration == generation
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
