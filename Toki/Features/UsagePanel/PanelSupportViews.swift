import AppKit
import SwiftUI

struct SkeletonBar: View {
    var width: CGFloat?
    var height: CGFloat = 12
    var cornerRadius: CGFloat = 4

    @State private var opacity = 0.18

    var body: some View {
        RoundedRectangle(cornerRadius: cornerRadius)
            .fill(Color.white.opacity(opacity))
            .frame(width: width, height: height)
            .onAppear {
                withAnimation(.easeInOut(duration: 0.85).repeatForever(autoreverses: true)) {
                    opacity = 0.06
                }
            }
    }
}

struct StatRowView: View {
    let label: String
    let value: String
    let accent: Color
    var isLoading = false

    private var skeletonWidth: CGFloat {
        let seed = label.unicodeScalars.reduce(0) { partialResult, scalar in
            partialResult + Int(scalar.value)
        }
        return CGFloat(36 + (seed % 21))
    }

    var body: some View {
        HStack(alignment: .center) {
            Circle()
                .fill(accent.opacity(isLoading ? 0.15 : 0.5))
                .frame(width: 5, height: 5)
            Text(label)
                .font(.system(size: 12))
                .foregroundColor(Color.white.opacity(isLoading ? 0.2 : 0.45))
            Spacer()
            if isLoading {
                SkeletonBar(width: skeletonWidth, height: 11)
            } else {
                Text(value)
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                    .foregroundColor(Color.white.opacity(0.85))
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 7)
    }
}

struct PanelFooterView: View {
    var body: some View {
        HStack {
            Spacer()
            Button(action: { NSApplication.shared.terminate(nil) }) {
                Text("Quit")
                    .font(.system(size: 11))
                    .foregroundColor(Color.white.opacity(0.28))
            }
            .buttonStyle(.plain)
            .padding(.trailing, 16)
            .padding(.vertical, 10)
        }
    }
}
