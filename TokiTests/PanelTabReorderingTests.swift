import XCTest
@testable import Toki

final class PanelTabReorderingTests: XCTestCase {
    private let order: [PanelTab] = [.overview, .projects, .byModel, .sources]

    /// Slots 40pt wide laid out left to right, so midX values are 20/60/100/140.
    private func frames(for tabs: [PanelTab]) -> [PanelTab: CGRect] {
        Dictionary(uniqueKeysWithValues: tabs.enumerated().map { index, tab in
            (tab, CGRect(x: CGFloat(index) * 40, y: 0, width: 40, height: 26))
        })
    }

    func test_movingRightPastNeighborCenterSwapsWithThatNeighbor() {
        let reordered = PanelTabReordering.reordered(
            order,
            moving: .overview,
            toCenterX: 65,
            frames: frames(for: order))

        XCTAssertEqual(reordered, [.projects, .overview, .byModel, .sources])
    }

    func test_movingLeftPastNeighborCenterSwapsWithThatNeighbor() {
        let reordered = PanelTabReordering.reordered(
            order,
            moving: .sources,
            toCenterX: 95,
            frames: frames(for: order))

        XCTAssertEqual(reordered, [.overview, .projects, .sources, .byModel])
    }

    func test_stayingWithinOwnSlotKeepsOrderUnchanged() {
        let reordered = PanelTabReordering.reordered(
            order,
            moving: .byModel,
            toCenterX: 105,
            frames: frames(for: order))

        XCTAssertEqual(reordered, order)
    }

    func test_draggingFarLeftClampsToFirstPosition() {
        let reordered = PanelTabReordering.reordered(
            order,
            moving: .sources,
            toCenterX: -400,
            frames: frames(for: order))

        XCTAssertEqual(reordered, [.sources, .overview, .projects, .byModel])
    }

    func test_draggingFarRightClampsToLastPosition() {
        let reordered = PanelTabReordering.reordered(
            order,
            moving: .overview,
            toCenterX: 4000,
            frames: frames(for: order))

        XCTAssertEqual(reordered, [.projects, .byModel, .sources, .overview])
    }

    func test_missingFrameForDraggedTabKeepsOrderUnchanged() {
        var partialFrames = frames(for: order)
        partialFrames[.overview] = nil

        let reordered = PanelTabReordering.reordered(
            order,
            moving: .overview,
            toCenterX: 4000,
            frames: partialFrames)

        XCTAssertEqual(reordered, order)
    }

    func test_missingFrameForAnotherTabKeepsOrderUnchanged() {
        var partialFrames = frames(for: order)
        partialFrames[.sources] = nil

        let reordered = PanelTabReordering.reordered(
            order,
            moving: .overview,
            toCenterX: 4000,
            frames: partialFrames)

        XCTAssertEqual(reordered, order)
    }

    func test_tabOutsideOrderKeepsOrderUnchanged() {
        let reordered = PanelTabReordering.reordered(
            order,
            moving: .hourly,
            toCenterX: 20,
            frames: frames(for: order + [.hourly]))

        XCTAssertEqual(reordered, order)
    }

    func test_slotMidXMatchesMeasuredPositionForUnchangedOrder() {
        let measured = frames(for: order)

        for tab in order {
            XCTAssertEqual(
                PanelTabReordering.slotMidX(for: tab, in: order, frames: measured, spacing: 0),
                measured[tab]?.midX)
        }
    }

    func test_slotMidXFollowsTabIntoItsNewSlot() {
        let measured = frames(for: order)
        let moved: [PanelTab] = [.projects, .overview, .byModel, .sources]

        XCTAssertEqual(
            PanelTabReordering.slotMidX(for: .overview, in: moved, frames: measured, spacing: 0),
            60)
        XCTAssertEqual(
            PanelTabReordering.slotMidX(for: .projects, in: moved, frames: measured, spacing: 0),
            20)
    }

    func test_slotMidXAccountsForSpacingAndUnequalWidths() {
        let measured: [PanelTab: CGRect] = [
            .overview: CGRect(x: 0, y: 0, width: 70, height: 26),
            .projects: CGRect(x: 73, y: 0, width: 40, height: 26),
            .byModel: CGRect(x: 116, y: 0, width: 40, height: 26),
        ]
        let moved: [PanelTab] = [.projects, .overview, .byModel]

        // projects keeps the row start, overview follows it, byModel stays last.
        XCTAssertEqual(
            PanelTabReordering.slotMidX(for: .projects, in: moved, frames: measured, spacing: 3),
            20)
        XCTAssertEqual(
            PanelTabReordering.slotMidX(for: .overview, in: moved, frames: measured, spacing: 3),
            78)
        XCTAssertEqual(
            PanelTabReordering.slotMidX(for: .byModel, in: moved, frames: measured, spacing: 3),
            136)
    }

    func test_slotMidXReturnsNilWhenAFrameIsMissing() {
        var partialFrames = frames(for: order)
        partialFrames[.byModel] = nil

        XCTAssertNil(
            PanelTabReordering.slotMidX(for: .overview, in: order, frames: partialFrames, spacing: 0))
    }

    /// The row keeps its committed order during a drag, so the tab being passed
    /// over is the one that slides aside to open a gap.
    func test_passedOverTabShiftsAsideByOneSlot() throws {
        let measured = frames(for: order)
        let startMidX = try XCTUnwrap(measured[.overview]).midX

        let previewOrder = PanelTabReordering.reordered(
            order,
            moving: .overview,
            toCenterX: startMidX + 45,
            frames: measured)
        XCTAssertEqual(previewOrder, [.projects, .overview, .byModel, .sources])

        // projects takes the slot overview vacated; the tabs behind it stay put.
        let projectsMidX = try XCTUnwrap(PanelTabReordering.slotMidX(
            for: .projects,
            in: previewOrder,
            frames: measured,
            spacing: 0))
        let projectsOriginalMidX = try XCTUnwrap(measured[.projects]).midX
        XCTAssertEqual(projectsMidX - projectsOriginalMidX, -40)

        for unmovedTab in [PanelTab.byModel, .sources] {
            let slotMidX = try XCTUnwrap(PanelTabReordering.slotMidX(
                for: unmovedTab,
                in: previewOrder,
                frames: measured,
                spacing: 0))
            let originalMidX = try XCTUnwrap(measured[unmovedTab]).midX
            XCTAssertEqual(slotMidX - originalMidX, 0)
        }
    }

    private let tabSize = CGSize(width: 40, height: 26)

    func test_clickReleasedOverTheTabSelectsIt() {
        XCTAssertTrue(PanelTabReordering.isSelectionTap(
            translation: .zero,
            releaseLocation: CGPoint(x: 20, y: 13),
            tabSize: tabSize))
    }

    /// Dragging off the tab and releasing must not activate it, the way a
    /// Button cancels when the pointer leaves before mouse-up.
    func test_releaseOutsideTheTabDoesNotSelectIt() {
        XCTAssertFalse(PanelTabReordering.isSelectionTap(
            translation: CGSize(width: 1, height: 40),
            releaseLocation: CGPoint(x: 20, y: 66),
            tabSize: tabSize))
        XCTAssertFalse(PanelTabReordering.isSelectionTap(
            translation: CGSize(width: 1, height: -2),
            releaseLocation: CGPoint(x: -5, y: 13),
            tabSize: tabSize))
    }

    func test_verticalTravelBeyondThresholdIsNotASelection() {
        XCTAssertFalse(PanelTabReordering.isSelectionTap(
            translation: CGSize(width: 0, height: 4),
            releaseLocation: CGPoint(x: 20, y: 13),
            tabSize: tabSize))
    }

    func test_unmeasuredTabStaysClickable() {
        XCTAssertTrue(PanelTabReordering.isSelectionTap(
            translation: .zero,
            releaseLocation: CGPoint(x: 20, y: 13),
            tabSize: nil))
    }

    func test_shortTravelIsTreatedAsSelectionRatherThanReorder() {
        XCTAssertFalse(PanelTabReordering.isReorderDrag(translationWidth: 0))
        XCTAssertFalse(PanelTabReordering.isReorderDrag(translationWidth: 3.9))
        XCTAssertFalse(PanelTabReordering.isReorderDrag(translationWidth: -3.9))
        XCTAssertTrue(PanelTabReordering.isReorderDrag(translationWidth: 4))
        XCTAssertTrue(PanelTabReordering.isReorderDrag(translationWidth: -12))
    }
}
