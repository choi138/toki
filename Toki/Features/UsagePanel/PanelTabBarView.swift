import SwiftUI

struct PanelTabBarView: View {
    @Binding var activeTab: PanelTab

    @State private var hoveredTab: PanelTab?

    var body: some View {
        HStack(spacing: 3) {
            ForEach(PanelTab.allCases) { tab in
                tabButton(for: tab)
            }
        }
        .padding(.horizontal, 12)
        .frame(height: 40)
        .animation(.easeOut(duration: 0.15), value: activeTab)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text("Usage views"))
    }

    @ViewBuilder
    private func tabButton(for tab: PanelTab) -> some View {
        let isSelected = tab == activeTab
        Button {
            activeTab = tab
        } label: {
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
        }
        .buttonStyle(.plain)
        .onHover { isHovering in
            hoveredTab = isHovering ? tab : nil
        }
        .help(tab.title)
        .accessibilityLabel(Text(tab.title))
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
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
