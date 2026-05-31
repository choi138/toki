import SwiftUI

struct PanelTabBarView: View {
    @Binding var activeTab: PanelTab

    var body: some View {
        Menu {
            ForEach(PanelTab.allCases) { tab in
                Button {
                    activeTab = tab
                } label: {
                    Label(
                        tab.title,
                        systemImage: tab == activeTab ? "checkmark.circle.fill" : tab.systemImage)
                }
            }
        } label: {
            HStack(spacing: 10) {
                ZStack {
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .fill(activeTab.accentColor.opacity(0.16))
                    Image(systemName: activeTab.systemImage)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(activeTab.accentColor)
                        .accessibilityHidden(true)
                }
                .frame(width: 24, height: 24)

                VStack(alignment: .leading, spacing: 1) {
                    Text("View")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundColor(Color.white.opacity(0.28))
                    Text(activeTab.title)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(.white)
                }

                Spacer(minLength: 8)

                Image(systemName: "chevron.down")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundColor(Color.white.opacity(0.34))
                    .accessibilityHidden(true)
            }
            .frame(height: 30)
            .padding(.horizontal, 10)
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(Color.white.opacity(0.055)))
            .overlay(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .stroke(Color.white.opacity(0.08), lineWidth: 0.5))
            .contentShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 16)
        .padding(.vertical, 6)
        .frame(height: 44)
        .accessibilityLabel(Text("Usage view"))
        .accessibilityValue(Text(activeTab.title))
    }
}
