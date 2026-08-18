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

    static func action(
        for event: NSEvent,
        hasAttachedSheet: Bool = false) -> MenuBarPanelLocalEventAction {
        switch event.type {
        case .keyDown:
            guard event.keyCode == escapeKeyCode else { return .forward }
            return hasAttachedSheet ? .forward : .dismissAndConsume
        case .leftMouseDown, .rightMouseDown:
            return .dismissIfOutside
        default:
            return .forward
        }
    }
}

enum MenuBarPanelWindowPolicy {
    static func isRelatedTransientWindow(level: NSWindow.Level) -> Bool {
        level == .popUpMenu || level == .modalPanel
    }

    static func isRelated(_ window: NSWindow, to panel: NSWindow) -> Bool {
        isDescendant(window, of: panel)
            || isRelatedTransientWindow(level: window.level)
    }

    static func hasAttachedSheet(in window: NSWindow) -> Bool {
        var pendingWindows = [window]
        var visitedWindows = Set<ObjectIdentifier>()

        while let currentWindow = pendingWindows.popLast() {
            guard visitedWindows.insert(ObjectIdentifier(currentWindow)).inserted else { continue }
            if currentWindow.attachedSheet != nil {
                return true
            }
            pendingWindows.append(contentsOf: currentWindow.childWindows ?? [])
        }
        return false
    }

    private static func isDescendant(_ window: NSWindow, of panel: NSWindow) -> Bool {
        var pendingWindows = [window]
        var visitedWindows = Set<ObjectIdentifier>()

        while let currentWindow = pendingWindows.popLast() {
            guard visitedWindows.insert(ObjectIdentifier(currentWindow)).inserted else { continue }
            if currentWindow === panel {
                return true
            }
            if let parent = currentWindow.parent {
                pendingWindows.append(parent)
            }
            if let sheetParent = currentWindow.sheetParent {
                pendingWindows.append(sheetParent)
            }
        }
        return false
    }
}

enum MenuBarPanelDismissalPolicy {
    static func shouldDismiss(
        hasAttachedSheet: Bool,
        isEventWindowRelated: Bool,
        isLocationInsidePanel: Bool,
        isLocationInsideStatusItem: Bool) -> Bool {
        !hasAttachedSheet
            && !isEventWindowRelated
            && !isLocationInsidePanel
            && !isLocationInsideStatusItem
    }
}

enum MenuBarPanelPresentationPolicy {
    static func shouldShowPanel(isVisible: Bool) -> Bool {
        !isVisible
    }

    /// Whether a status-item toggle may close the panel.
    ///
    /// AppKit keeps an attached sheet visible and attached when only its parent is ordered out, so
    /// closing here would strand the sheet as an orphaned window while the controller reports the
    /// panel hidden and tears down its event monitors.
    static func shouldClosePanel(isVisible: Bool, hasAttachedSheet: Bool) -> Bool {
        isVisible && !hasAttachedSheet
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
        guard panel.isVisible else {
            show(relativeTo: view)
            return
        }
        guard MenuBarPanelPresentationPolicy.shouldClosePanel(
            isVisible: true,
            hasAttachedSheet: MenuBarPanelWindowPolicy.hasAttachedSheet(in: panel)) else {
            // Keep the panel and its sheet together; the sheet owns dismissal.
            panel.makeKeyAndOrderFront(nil)
            return
        }
        closePanel()
    }

    func show(relativeTo view: NSStatusBarButton) {
        guard let panel,
              MenuBarPanelPresentationPolicy.shouldShowPanel(isVisible: panel.isVisible) else { return }
        statusItemButton = view
        showPanel(relativeTo: view)
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
                let hasAttachedSheet = panel.map {
                    MenuBarPanelWindowPolicy.hasAttachedSheet(in: $0)
                } ?? false
                switch MenuBarPanelLocalEventPolicy.action(
                    for: event,
                    hasAttachedSheet: hasAttachedSheet) {
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
        let isEventWindowRelated = event.window.map {
            MenuBarPanelWindowPolicy.isRelated($0, to: panel)
        } ?? false
        let location = eventLocationInScreen(event)
        return MenuBarPanelDismissalPolicy.shouldDismiss(
            hasAttachedSheet: MenuBarPanelWindowPolicy.hasAttachedSheet(in: panel),
            isEventWindowRelated: isEventWindowRelated,
            isLocationInsidePanel: panel.frame.contains(location),
            isLocationInsideStatusItem: statusItemButton
                .flatMap(statusItemFrame(for:))?
                .contains(location) == true)
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
