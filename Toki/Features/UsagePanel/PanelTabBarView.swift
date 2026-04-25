import SwiftUI

struct PanelTabBarView: View {
    @Binding var activeTab: PanelTab

    var body: some View {
        HStack(spacing: 0) {
            TabButton(title: "Overview", isActive: activeTab == .overview) {
                activeTab = .overview
            }
            Rectangle()
                .fill(Color.white.opacity(0.07))
                .frame(width: 0.5)
            TabButton(title: "By Model", isActive: activeTab == .byModel) {
                activeTab = .byModel
            }
            Rectangle()
                .fill(Color.white.opacity(0.07))
                .frame(width: 0.5)
            TabButton(title: "Work Time", isActive: activeTab == .workTime) {
                activeTab = .workTime
            }
        }
        .frame(height: 32)
    }
}

private struct TabButton: View {
    let title: String
    let isActive: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 0) {
                Spacer()
                Text(title)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(isActive ? .white : Color.white.opacity(0.3))
                Spacer()
                Rectangle()
                    .fill(isActive ? Color(red: 0.55, green: 0.45, blue: 1.0) : Color.clear)
                    .frame(height: 2)
            }
        }
        .buttonStyle(.plain)
        .frame(maxWidth: .infinity)
        .accessibilityLabel(Text(title))
        .accessibilityAddTraits(isActive ? .isSelected : [])
    }
}
