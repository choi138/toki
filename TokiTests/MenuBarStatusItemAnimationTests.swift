import AppKit
import XCTest
@testable import Toki

final class MenuBarStatusItemAnimationTests: XCTestCase {
    func test_preparedMenuBarImageNormalizesPointSizeWithoutMutatingSource() {
        let sourceImage = NSImage(size: NSSize(width: 36, height: 36))

        let preparedImage = preparedMenuBarImage(sourceImage)

        XCTAssertEqual(sourceImage.size, NSSize(width: 36, height: 36))
        XCTAssertEqual(preparedImage.size, MenuBarStatusItemMetrics.staticIconPointSize)
        XCTAssertTrue(preparedImage.isTemplate)
    }

    func test_menuBarAnimationCropRectCentersSharedCrop() {
        let cropRect = menuBarAnimationCropRect(
            for: NSSize(width: 36, height: 36))

        XCTAssertEqual(cropRect, NSRect(x: 6, y: 6, width: 24, height: 24))
    }

    func test_menuBarAnimationCropRectUsesAvailablePixelsForSmallSource() {
        let cropRect = menuBarAnimationCropRect(
            for: NSSize(width: 18, height: 12))

        XCTAssertEqual(cropRect, NSRect(x: 0, y: 0, width: 18, height: 12))
    }

    func test_preparedMenuBarAnimationFrameCropsBeforeNormalizingPointSize() throws {
        let sourceImage = try makeMenuBarTestImage(
            pixelSize: NSSize(width: 36, height: 36))

        let preparedImage = preparedMenuBarAnimationFrame(sourceImage)
        var proposedRect = NSRect(origin: .zero, size: preparedImage.size)
        let preparedCGImage = try XCTUnwrap(preparedImage.cgImage(
            forProposedRect: &proposedRect,
            context: nil,
            hints: nil))

        XCTAssertEqual(sourceImage.size, NSSize(width: 36, height: 36))
        XCTAssertEqual(preparedImage.size, MenuBarStatusItemMetrics.animationIconPointSize)
        XCTAssertEqual(preparedCGImage.width, 24)
        XCTAssertEqual(preparedCGImage.height, 24)
        XCTAssertTrue(preparedImage.isTemplate)
    }

    func test_preparedMenuBarAnimationFrameExpandsBundledRabbitContent() throws {
        for frameIndex in 0..<10 {
            let resourceName = String(format: "rabbit_run_%02d", frameIndex)
            let frameURL = try XCTUnwrap(
                Bundle.main.url(forResource: resourceName, withExtension: "png"))
            let sourceImage = try XCTUnwrap(NSImage(contentsOf: frameURL))
            let preparedImage = preparedMenuBarAnimationFrame(sourceImage)

            let sourceMetrics = try menuBarImagePixelMetrics(sourceImage)
            let preparedMetrics = try menuBarImagePixelMetrics(preparedImage)
            let sourceWidthFraction = sourceMetrics.opaqueBounds.width / sourceMetrics.pixelSize.width
            let sourceHeightFraction = sourceMetrics.opaqueBounds.height / sourceMetrics.pixelSize.height
            let preparedWidthFraction = preparedMetrics.opaqueBounds.width / preparedMetrics.pixelSize.width
            let preparedHeightFraction = preparedMetrics.opaqueBounds.height / preparedMetrics.pixelSize.height
            let preparedWidthInPoints = preparedWidthFraction * preparedImage.size.width
            let preparedHeightInPoints = preparedHeightFraction * preparedImage.size.height

            XCTAssertGreaterThan(
                preparedWidthFraction,
                sourceWidthFraction + 0.2,
                "\(resourceName) should use more of the prepared frame width")
            XCTAssertGreaterThan(
                preparedHeightFraction,
                sourceHeightFraction + 0.2,
                "\(resourceName) should use more of the prepared frame height")
            XCTAssertGreaterThanOrEqual(
                preparedWidthInPoints,
                17,
                "\(resourceName) should be visually wide enough in the menu bar")
            XCTAssertGreaterThanOrEqual(
                preparedHeightInPoints,
                16,
                "\(resourceName) should be visually tall enough in the menu bar")
        }
    }

    @MainActor
    func test_statusItemUsesVariableLengthOnlyWhileShowingSummary() {
        let controller = MenuBarStatusItemController()
        let actionTarget = MenuBarStatusItemAnimationActionTarget()
        controller.setup(
            target: actionTarget,
            action: #selector(MenuBarStatusItemAnimationActionTarget.performAction(_:)))
        defer {
            if let statusItem = controller.statusItem {
                NSStatusBar.system.removeStatusItem(statusItem)
            }
        }

        XCTAssertEqual(controller.statusItem?.length, NSStatusItem.squareLength)
        XCTAssertEqual(controller.button?.imageScaling, .scaleNone)

        controller.applySummary(title: "$4.20", toolTip: "Current cost")

        XCTAssertEqual(controller.statusItem?.length, NSStatusItem.variableLength)

        controller.applySummary(title: nil, toolTip: nil)

        XCTAssertEqual(controller.statusItem?.length, NSStatusItem.squareLength)
    }

    func test_stoppedAnimationRejectsQueuedFrame() {
        var lifecycle = RabbitRunAnimationLifecycle()
        let queuedGeneration = lifecycle.start()

        lifecycle.stop()

        XCTAssertFalse(lifecycle.shouldApplyFrame(for: queuedGeneration))
    }
}

private final class MenuBarStatusItemAnimationActionTarget: NSObject {
    @objc func performAction(_ sender: Any?) {}
}

private func makeMenuBarTestImage(pixelSize: NSSize) throws -> NSImage {
    let representation = try XCTUnwrap(NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: Int(pixelSize.width),
        pixelsHigh: Int(pixelSize.height),
        bitsPerSample: 8,
        samplesPerPixel: 4,
        hasAlpha: true,
        isPlanar: false,
        colorSpaceName: .deviceRGB,
        bytesPerRow: 0,
        bitsPerPixel: 0))
    representation.size = pixelSize

    let image = NSImage(size: pixelSize)
    image.addRepresentation(representation)
    return image
}

private struct MenuBarImagePixelMetrics {
    let pixelSize: NSSize
    let opaqueBounds: NSRect
}

private func menuBarImagePixelMetrics(_ image: NSImage) throws -> MenuBarImagePixelMetrics {
    var proposedRect = NSRect(origin: .zero, size: image.size)
    let cgImage = try XCTUnwrap(image.cgImage(
        forProposedRect: &proposedRect,
        context: nil,
        hints: nil))
    let representation = NSBitmapImageRep(cgImage: cgImage)
    var minX = representation.pixelsWide
    var minY = representation.pixelsHigh
    var maxX = -1
    var maxY = -1

    for y in 0..<representation.pixelsHigh {
        for x in 0..<representation.pixelsWide {
            guard (representation.colorAt(x: x, y: y)?.alphaComponent ?? 0) > 0.01 else {
                continue
            }
            minX = min(minX, x)
            minY = min(minY, y)
            maxX = max(maxX, x)
            maxY = max(maxY, y)
        }
    }

    let opaqueBounds: NSRect? = maxX >= 0
        ? NSRect(
            x: CGFloat(minX),
            y: CGFloat(minY),
            width: CGFloat(maxX - minX + 1),
            height: CGFloat(maxY - minY + 1))
        : nil
    let unwrappedOpaqueBounds = try XCTUnwrap(opaqueBounds)
    return MenuBarImagePixelMetrics(
        pixelSize: NSSize(
            width: CGFloat(representation.pixelsWide),
            height: CGFloat(representation.pixelsHigh)),
        opaqueBounds: unwrappedOpaqueBounds)
}
