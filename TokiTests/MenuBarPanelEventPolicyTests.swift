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
}
