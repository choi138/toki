import CoreGraphics

/// Pure ordering math for the drag-to-reorder tab bar, kept out of the view so
/// the placement rules can be unit tested.
enum PanelTabReordering {
    /// Horizontal travel below this is treated as a click that selects the tab
    /// rather than a drag that moves it.
    static let minimumReorderDistance: CGFloat = 4

    static func isReorderDrag(translationWidth: CGFloat) -> Bool {
        abs(translationWidth) >= minimumReorderDistance
    }

    /// A press only selects when it stays click-sized in both axes and is
    /// released over the tab, matching how a `Button` cancels when the pointer
    /// is dragged away before mouse-up.
    ///
    /// `releaseLocation` is in the tab's own coordinate space. A nil `tabSize`
    /// means the row has not been measured yet, and the tab stays clickable.
    static func isSelectionTap(
        translation: CGSize,
        releaseLocation: CGPoint,
        tabSize: CGSize?) -> Bool {
        guard abs(translation.width) < minimumReorderDistance,
              abs(translation.height) < minimumReorderDistance else { return false }
        guard let tabSize else { return true }
        return (0...tabSize.width).contains(releaseLocation.x)
            && (0...tabSize.height).contains(releaseLocation.y)
    }

    /// Places `tab` at the slot matching `centerX`, keeping every other tab in
    /// its measured left-to-right position.
    ///
    /// `frames` must be the snapshot taken when the drag began. Recomputing from
    /// the untouched `order` on every change keeps the result stable instead of
    /// oscillating once a tab has already moved. The order is returned unchanged
    /// when any tab is missing a measured frame.
    static func reordered(
        _ order: [PanelTab],
        moving tab: PanelTab,
        toCenterX centerX: CGFloat,
        frames: [PanelTab: CGRect]) -> [PanelTab] {
        guard order.contains(tab), frames[tab] != nil else { return order }

        let others = order.filter { candidate in
            candidate != tab
        }
        let placedOthers = others.compactMap { candidate -> (tab: PanelTab, midX: CGFloat)? in
            guard let frame = frames[candidate] else { return nil }
            return (candidate, frame.midX)
        }
        guard placedOthers.count == others.count else { return order }

        let sortedOthers = placedOthers
            .sorted { lhs, rhs in
                lhs.midX < rhs.midX
            }
            .map(\.tab)
        let insertionIndex = placedOthers.filter { candidate in
            candidate.midX < centerX
        }
        .count

        return Array(sortedOthers[..<insertionIndex]) + [tab] + Array(sortedOthers[insertionIndex...])
    }

    /// Center of the slot `tab` occupies once `order` is laid out left to right.
    ///
    /// Widths come from the drag-start snapshot and selection cannot change
    /// mid-drag, so reordering moves slots around without resizing them. The
    /// row therefore starts where it started and positions can be accumulated.
    static func slotMidX(
        for tab: PanelTab,
        in order: [PanelTab],
        frames: [PanelTab: CGRect],
        spacing: CGFloat) -> CGFloat? {
        let orderedFrames = order.compactMap { candidate in
            frames[candidate]
        }
        guard orderedFrames.count == order.count,
              let rowMinX = orderedFrames.map(\.minX).min() else { return nil }

        return order.reduce(into: (x: rowMinX, midX: CGFloat?.none)) { result, candidate in
            guard let width = frames[candidate]?.width else { return }
            if candidate == tab, result.midX == nil {
                result.midX = result.x + width / 2
            }
            result.x += width + spacing
        }
        .midX
    }
}
