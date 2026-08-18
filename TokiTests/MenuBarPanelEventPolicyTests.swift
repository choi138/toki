import AppKit
import XCTest
@testable import Toki

final class MenuBarPanelEventPolicyTests: XCTestCase {
    func test_characterKeyDownIsForwarded() throws {
        let event = try XCTUnwrap(keyDownEvent(keyCode: 9))
        let action = MenuBarPanelLocalEventPolicy.action(for: event)

        XCTAssertEqual(action, .forward)
    }

    func test_escapeKeyDownDismissesAndConsumesEvent() throws {
        let event = try XCTUnwrap(keyDownEvent(keyCode: 53))
        let action = MenuBarPanelLocalEventPolicy.action(for: event)

        XCTAssertEqual(action, .dismissAndConsume)
    }

    func test_escapeKeyDownIsForwardedWhileSheetIsAttached() throws {
        let event = try XCTUnwrap(keyDownEvent(keyCode: 53))
        let action = MenuBarPanelLocalEventPolicy.action(
            for: event,
            hasAttachedSheet: true)

        XCTAssertEqual(action, .forward)
    }

    func test_mouseDownRequestsOutsideHitTestingWithoutReadingKeyCode() throws {
        let leftMouseDown = try XCTUnwrap(mouseDownEvent(type: .leftMouseDown))
        let rightMouseDown = try XCTUnwrap(mouseDownEvent(type: .rightMouseDown))

        XCTAssertEqual(
            MenuBarPanelLocalEventPolicy.action(for: leftMouseDown),
            .dismissIfOutside)
        XCTAssertEqual(
            MenuBarPanelLocalEventPolicy.action(for: rightMouseDown),
            .dismissIfOutside)
    }

    func test_popupMenuWindowIsTreatedAsPanelRelatedTransientContent() {
        XCTAssertTrue(
            MenuBarPanelWindowPolicy.isRelatedTransientWindow(level: .popUpMenu))
        XCTAssertFalse(
            MenuBarPanelWindowPolicy.isRelatedTransientWindow(level: .normal))
    }

    func test_modalPanelWindowIsTreatedAsPanelRelatedTransientContent() {
        XCTAssertTrue(
            MenuBarPanelWindowPolicy.isRelatedTransientWindow(level: .modalPanel))
        XCTAssertFalse(
            MenuBarPanelWindowPolicy.isRelatedTransientWindow(level: .normal))
    }

    func test_nestedChildWindowIsRelatedToPanel() {
        let panel = makePanel()
        let childWindow = makeWindow()
        let nestedChildWindow = makeWindow()
        panel.addChildWindow(childWindow, ordered: .above)
        childWindow.addChildWindow(nestedChildWindow, ordered: .above)
        defer {
            childWindow.removeChildWindow(nestedChildWindow)
            panel.removeChildWindow(childWindow)
        }

        XCTAssertTrue(
            MenuBarPanelWindowPolicy.isRelated(nestedChildWindow, to: panel))
    }

    func test_sheetWindowIsRelatedToPanelThroughSheetParent() {
        let panel = makePanel()
        let sheet = makeWindow()
        panel.beginSheet(sheet)
        defer { panel.endSheet(sheet) }

        XCTAssertTrue(MenuBarPanelWindowPolicy.isRelated(sheet, to: panel))
    }

    func test_panelHierarchyReportsAttachedSheet() {
        let panel = makePanel()
        let childWindow = makeWindow()
        let sheet = makeWindow()
        panel.addChildWindow(childWindow, ordered: .above)
        childWindow.beginSheet(sheet)
        defer {
            childWindow.endSheet(sheet)
            panel.removeChildWindow(childWindow)
        }

        XCTAssertTrue(MenuBarPanelWindowPolicy.hasAttachedSheet(in: panel))
    }

    func test_attachedSheetSuppressesOutsidePanelDismissal() {
        XCTAssertFalse(
            MenuBarPanelDismissalPolicy.shouldDismiss(
                hasAttachedSheet: true,
                isEventWindowRelated: false,
                isLocationInsidePanel: false,
                isLocationInsideStatusItem: false))
    }

    func test_openActionShowsOnlyWhenPanelIsHidden() {
        XCTAssertTrue(MenuBarPanelPresentationPolicy.shouldShowPanel(isVisible: false))
        XCTAssertFalse(MenuBarPanelPresentationPolicy.shouldShowPanel(isVisible: true))
    }

    /// Ordering out a panel that owns an attached sheet leaves the sheet on screen while the
    /// controller reports the panel hidden, so the status-item toggle must not close it.
    func test_statusItemToggleDoesNotClosePanelWithAttachedSheet() {
        XCTAssertTrue(MenuBarPanelPresentationPolicy.shouldClosePanel(
            isVisible: true,
            hasAttachedSheet: false))
        XCTAssertFalse(MenuBarPanelPresentationPolicy.shouldClosePanel(
            isVisible: true,
            hasAttachedSheet: true))
        XCTAssertFalse(MenuBarPanelPresentationPolicy.shouldClosePanel(
            isVisible: false,
            hasAttachedSheet: false))
    }

    private func keyDownEvent(keyCode: UInt16) -> NSEvent? {
        NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: [],
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            characters: "v",
            charactersIgnoringModifiers: "v",
            isARepeat: false,
            keyCode: keyCode)
    }

    private func mouseDownEvent(type: NSEvent.EventType) -> NSEvent? {
        NSEvent.mouseEvent(
            with: type,
            location: .zero,
            modifierFlags: [],
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            eventNumber: 0,
            clickCount: 1,
            pressure: 1)
    }

    private func makePanel() -> NSPanel {
        NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 100, height: 100),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false)
    }

    private func makeWindow() -> NSWindow {
        NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 100, height: 100),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false)
    }
}
