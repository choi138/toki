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

enum MenuBarPanelLocalEventAction: Equatable {
    case forward
    case dismissAndConsume
    case dismissIfOutside
}

enum MenuBarPanelLocalEventPolicy {
    private static let escapeKeyCode: UInt16 = 53

    static func action(for event: NSEvent) -> MenuBarPanelLocalEventAction {
        switch event.type {
        case .keyDown:
            event.keyCode == escapeKeyCode ? .dismissAndConsume : .forward
        case .leftMouseDown, .rightMouseDown:
            .dismissIfOutside
        default:
            .forward
        }
    }
}

enum MenuBarPanelWindowPolicy {
    static func isRelatedTransientWindow(level: NSWindow.Level) -> Bool {
        level == .popUpMenu
    }
}

@MainActor
final class MenuBarPanelController {
    private let tokenVelocityState: TokenVelocityState
    private let visibilityDidChange: (Bool) -> Void

    private var panel: NSPanel?
    private weak var statusItemButton: NSStatusBarButton?
    private var localEventMonitor: Any?
    private var globalEventMonitor: Any?

    init(
        tokenVelocityState: TokenVelocityState,
        visibilityDidChange: @escaping (Bool) -> Void) {
        self.tokenVelocityState = tokenVelocityState
        self.visibilityDidChange = visibilityDidChange
    }

    func setup() {
        guard panel == nil else { return }
        let panel = MenuBarPanel(
            contentRect: NSRect(origin: .zero, size: PanelWindow.size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false)
        panel.backgroundColor = .clear
        panel.becomesKeyOnlyIfNeeded = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.contentViewController = NSHostingController(
            rootView: UsagePanelView(tokenVelocityState: tokenVelocityState))
        panel.hasShadow = true
        panel.isMovable = false
        panel.isOpaque = false
        panel.isReleasedWhenClosed = false
        panel.level = .statusBar
        panel.contentView?.wantsLayer = true
        panel.contentView?.layer?.cornerRadius = PanelWindow.cornerRadius
        panel.contentView?.layer?.masksToBounds = true
        self.panel = panel
    }

    func toggle(relativeTo view: NSStatusBarButton) {
        guard let panel else { return }
        statusItemButton = view
        if panel.isVisible {
            closePanel()
        } else {
            showPanel(relativeTo: view)
        }
    }

    func stop() {
        panel?.orderOut(nil)
        visibilityDidChange(false)
        stopEventMonitoring()
    }
}

private extension MenuBarPanelController {
    func showPanel(relativeTo view: NSView) {
        guard let panel,
              let frame = panelFrame(relativeTo: view) else { return }
        panel.setFrame(frame, display: true)
        panel.makeKeyAndOrderFront(nil)
        visibilityDidChange(true)
        startEventMonitoring()
    }

    func closePanel() {
        panel?.orderOut(nil)
        visibilityDidChange(false)
        stopEventMonitoring()
    }

    func panelFrame(relativeTo view: NSView) -> NSRect? {
        guard let statusItemFrame = statusItemFrame(for: view) else { return nil }
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

    func startEventMonitoring() {
        guard localEventMonitor == nil, globalEventMonitor == nil else { return }
        localEventMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown, .keyDown]) { [weak self] event in
                guard let self else { return event }
                switch MenuBarPanelLocalEventPolicy.action(for: event) {
                case .forward:
                    return event
                case .dismissAndConsume:
                    closePanel()
                    return nil
                case .dismissIfOutside:
                    if shouldClosePanel(for: event) {
                        closePanel()
                    }
                    return event
                }
            }

        globalEventMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
                guard let self, shouldClosePanel(for: event) else { return }
                closePanel()
            }
    }

    func stopEventMonitoring() {
        if let localEventMonitor {
            NSEvent.removeMonitor(localEventMonitor)
            self.localEventMonitor = nil
        }
        if let globalEventMonitor {
            NSEvent.removeMonitor(globalEventMonitor)
            self.globalEventMonitor = nil
        }
    }

    func shouldClosePanel(for event: NSEvent) -> Bool {
        guard let panel else { return false }
        if let window = event.window, isPanelRelatedWindow(window, panel: panel) {
            return false
        }
        let location = eventLocationInScreen(event)
        if panel.frame.contains(location) {
            return false
        }
        if statusItemButton.flatMap(statusItemFrame(for:))?.contains(location) == true {
            return false
        }
        return true
    }

    func isPanelRelatedWindow(_ window: NSWindow, panel: NSPanel) -> Bool {
        window == panel
            || window.parent == panel
            || panel.childWindows?.contains(window) == true
            || MenuBarPanelWindowPolicy.isRelatedTransientWindow(level: window.level)
    }

    func eventLocationInScreen(_ event: NSEvent) -> NSPoint {
        guard let window = event.window else { return event.locationInWindow }
        return window.convertPoint(toScreen: event.locationInWindow)
    }

    func statusItemFrame(for view: NSView) -> NSRect? {
        guard let window = view.window else { return nil }
        let rectInWindow = view.convert(view.bounds, to: nil)
        return window.convertToScreen(rectInWindow)
    }
}

private final class MenuBarPanel: NSPanel {
    override var canBecomeMain: Bool {
        false
    }

    override var canBecomeKey: Bool {
        true
    }
}
