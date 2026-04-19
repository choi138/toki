import Foundation
import SwiftUI

struct PanelHeaderView: View {
    let isLoading: Bool
    let lastFetchedAt: Date?
    let onRefresh: () -> Void

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return formatter
    }()

    var body: some View {
        HStack(alignment: .center) {
            HStack(spacing: 6) {
                Image("MenuBarIcon")
                    .renderingMode(.template)
                    .resizable()
                    .scaledToFit()
                    .frame(width: 14, height: 14)
                    .foregroundColor(Color(red: 0.55, green: 0.45, blue: 1.0))
                Text("Toki")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(.white)
            }
            Spacer()
            if let fetchedAt = lastFetchedAt {
                Text(Self.timeFormatter.string(from: fetchedAt))
                    .font(.system(size: 10))
                    .foregroundColor(Color.white.opacity(0.25))
            }
            Button(action: onRefresh) {
                Group {
                    if isLoading {
                        ProgressView()
                            .scaleEffect(0.5)
                            .frame(width: 14, height: 14)
                            .accessibilityHidden(true)
                    } else {
                        Image(systemName: "arrow.clockwise")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundColor(Color.white.opacity(0.4))
                            .accessibilityHidden(true)
                    }
                }
            }
            .buttonStyle(.plain)
            .padding(.leading, 6)
            .disabled(isLoading)
            .accessibilityLabel(isLoading ? Text("Refreshing") : Text("Refresh"))
            .accessibilityValue(isLoading ? Text("In progress") : Text("Idle"))
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 11)
    }
}
