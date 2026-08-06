import SwiftUI

struct PanelTabBarView: View {
    let tabs: [PanelTab]
    @Binding var activeTab: PanelTab
    let onReorder: ([PanelTab]) -> Void

    @State private var hoveredTab: PanelTab?
    @State private var draggingTab: PanelTab?
    @State private var dragTranslation: CGFloat = 0
    @State private var measuredFrames: [PanelTab: CGRect] = [:]
    @State private var dragStartFrames: [PanelTab: CGRect] = [:]
    @State private var previewOrder: [PanelTab] = []

    private static let coordinateSpaceName = "panelTabBar"
    private static let tabSpacing: CGFloat = 3

    var body: some View {
        // The row is never re-ordered while a drag is live: moving a child inside
        // the container tears down its gesture, which would chop one drag into
        // several. Rearrangement is expressed purely through offsets instead.
        HStack(spacing: Self.tabSpacing) {
            ForEach(tabs) { tab in
                tabButton(for: tab)
            }
        }
        .coordinateSpace(name: Self.coordinateSpaceName)
        .onPreferenceChange(PanelTabFramePreferenceKey.self) { frames in
            measuredFrames = frames
        }
        .padding(.horizontal, 12)
        .frame(height: 40)
        .animation(.easeOut(duration: 0.15), value: activeTab)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text("Usage views"))
        .onDisappear(perform: resetDragState)
    }

    /// Falls back to the real order unless the preview is a complete rearrangement
    /// of it, so an interrupted drag cannot leave a stale layout on screen.
    private var validatedPreviewOrder: [PanelTab] {
        guard draggingTab != nil,
              previewOrder.count == tabs.count,
              Set(previewOrder) == Set(tabs) else { return tabs }
        return previewOrder
    }

    @ViewBuilder
    private func tabButton(for tab: PanelTab) -> some View {
        let isSelected = tab == activeTab
        let isDragging = draggingTab == tab
        HStack(spacing: 5) {
            Image(systemName: tab.systemImage)
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(iconColor(for: tab, isSelected: isSelected))
                .accessibilityHidden(true)
            if isSelected {
                Text(tab.title)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(Color.white.opacity(0.92))
                    .lineLimit(1)
                    .fixedSize()
            }
        }
        .padding(.horizontal, isSelected ? 10 : 0)
        .frame(maxWidth: isSelected ? nil : .infinity)
        .frame(height: 26)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(backgroundColor(for: tab, isSelected: isSelected)))
        .contentShape(Rectangle())
        .background(frameReader(for: tab))
        // Only the tabs making room animate. Springing the dragged tab as well
        // would leave it lagging behind the cursor.
        .animation(isDragging ? nil : .spring(response: 0.25, dampingFraction: 0.85), value: validatedPreviewOrder)
        .offset(x: dragOffset(for: tab))
        .opacity(isDragging ? 0.9 : 1)
        .zIndex(isDragging ? 1 : 0)
        .gesture(dragGesture(for: tab))
        .onHover { isHovering in
            guard draggingTab == nil else { return }
            hoveredTab = isHovering ? tab : nil
        }
        .help(tab.title)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text(tab.title))
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : [.isButton])
        .accessibilityAction {
            activeTab = tab
        }
    }

    private func frameReader(for tab: PanelTab) -> some View {
        GeometryReader { geometry in
            Color.clear
                .preference(
                    key: PanelTabFramePreferenceKey.self,
                    value: [tab: geometry.frame(in: .named(Self.coordinateSpaceName))])
        }
    }

    /// The dragged tab keeps its slot in the row, so tracking the cursor is just
    /// the raw translation. Every other tab slides to the slot the preview order
    /// gives it, which is what makes room for the drop.
    private func dragOffset(for tab: PanelTab) -> CGFloat {
        guard draggingTab != nil else { return 0 }
        if draggingTab == tab { return dragTranslation }

        guard let originalMidX = dragStartFrames[tab]?.midX,
              let previewMidX = PanelTabReordering.slotMidX(
                  for: tab,
                  in: validatedPreviewOrder,
                  frames: dragStartFrames,
                  spacing: Self.tabSpacing) else { return 0 }
        return previewMidX - originalMidX
    }

    /// A single gesture handles both interactions: travel under the reorder
    /// threshold selects the tab, anything longer moves it. `minimumDistance: 0`
    /// keeps `onEnded` firing for a plain click, while the drag state only
    /// engages past the threshold so clicking does not flicker the tab.
    private func dragGesture(for tab: PanelTab) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                let translationWidth = value.translation.width
                guard PanelTabReordering.isReorderDrag(translationWidth: translationWidth) else {
                    cancelPreview()
                    return
                }
                beginDragIfNeeded(for: tab)
                dragTranslation = translationWidth
                previewOrder = PanelTabReordering.reordered(
                    tabs,
                    moving: tab,
                    toCenterX: (dragStartFrames[tab]?.midX ?? 0) + translationWidth,
                    frames: dragStartFrames)
            }
            .onEnded { value in
                endDrag(for: tab, translationWidth: value.translation.width)
            }
    }

    private func beginDragIfNeeded(for tab: PanelTab) {
        guard draggingTab != tab else { return }
        draggingTab = tab
        dragStartFrames = measuredFrames
        previewOrder = tabs
    }

    /// Returning under the threshold puts the row back where it started while
    /// the gesture is still live, so releasing there reads as a plain click.
    private func cancelPreview() {
        guard draggingTab != nil else { return }
        dragTranslation = 0
        previewOrder = tabs
    }

    private func endDrag(for tab: PanelTab, translationWidth: CGFloat) {
        let reorderedTabs = validatedPreviewOrder
        let isReorderDrag = PanelTabReordering.isReorderDrag(translationWidth: translationWidth)
        resetDragState()

        guard isReorderDrag else {
            activeTab = tab
            return
        }
        guard reorderedTabs != tabs else { return }
        onReorder(reorderedTabs)
    }

    private func resetDragState() {
        draggingTab = nil
        dragTranslation = 0
        dragStartFrames = [:]
        previewOrder = []
    }

    private func iconColor(for tab: PanelTab, isSelected: Bool) -> Color {
        if isSelected { return tab.accentColor }
        return hoveredTab == tab ? Color.white.opacity(0.65) : Color.white.opacity(0.38)
    }

    private func backgroundColor(for tab: PanelTab, isSelected: Bool) -> Color {
        if isSelected { return tab.accentColor.opacity(0.16) }
        return hoveredTab == tab ? Color.white.opacity(0.06) : Color.clear
    }
}

private struct PanelTabFramePreferenceKey: PreferenceKey {
    static var defaultValue: [PanelTab: CGRect] = [:]

    static func reduce(value: inout [PanelTab: CGRect], nextValue: () -> [PanelTab: CGRect]) {
        value.merge(nextValue()) { _, latest in
            latest
        }
    }
}
