import SwiftUI

struct PanelTabBarView: View {
    @Binding var activeTab: PanelTab

    var body: some View {
        HStack(spacing: 2) {
            ForEach(PanelTab.allCases) { tab in
                tabButton(for: tab)
            }
        }
        .padding(.horizontal, 10)
        .frame(height: 44)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text("Usage views"))
    }

    private func tabButton(for tab: PanelTab) -> some View {
        let isSelected = tab == activeTab
        return Button {
            activeTab = tab
        } label: {
            VStack(spacing: 3) {
                Image(systemName: tab.systemImage)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(isSelected ? tab.accentColor : Color.white.opacity(0.35))
                    .accessibilityHidden(true)
                Text(tab.title)
                    .font(.system(size: 9, weight: isSelected ? .semibold : .medium))
                    .foregroundColor(isSelected ? Color.white.opacity(0.9) : Color.white.opacity(0.38))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 5)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(isSelected ? Color.white.opacity(0.07) : Color.clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(tab.title)
        .accessibilityLabel(Text(tab.title))
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
    }
}
