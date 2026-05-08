import SwiftUI

private let skeletonRowWidths: [CGFloat] = [88, 72, 96, 64, 80]

struct PanelByModelView: View {
    let usage: UsageData
    let isLoading: Bool

    var body: some View {
        VStack(spacing: 0) {
            if isLoading {
                VStack(spacing: 0) {
                    ForEach(Array(skeletonRowWidths.enumerated()), id: \.offset) { _, width in
                        skeletonModelRow(labelWidth: width)
                    }
                }
                .padding(.vertical, 6)
            } else if usage.perModel.isEmpty, usage.contextOnlyModels.isEmpty {
                Text("No data")
                    .font(.system(size: 12))
                    .foregroundColor(Color.white.opacity(0.3))
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, 24)
            } else {
                VStack(spacing: 0) {
                    if !usage.perModel.isEmpty {
                        ForEach(usage.perModel, id: \.id) { stat in
                            ModelStatRowView(stat: stat)
                                .equatable()
                        }
                    }

                    if !usage.contextOnlyModels.isEmpty {
                        PanelSectionCaption(title: "Context Only")

                        ForEach(usage.contextOnlyModels, id: \.id) { stat in
                            ContextOnlyModelStatRowView(stat: stat)
                                .equatable()
                        }

                        Text("Excluded from Total Tokens. Cursor stores context-window size for these rows.")
                            .font(.system(size: 10))
                            .foregroundColor(Color.white.opacity(0.28))
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(.horizontal, 16)
                            .padding(.top, 6)
                            .padding(.bottom, 8)
                    }
                }
                .padding(.vertical, 6)
            }
        }
    }

    private func skeletonModelRow(labelWidth: CGFloat) -> some View {
        HStack(alignment: .center, spacing: 6) {
            Circle()
                .fill(Color.white.opacity(0.08))
                .frame(width: 5, height: 5)
            VStack(alignment: .leading, spacing: 4) {
                SkeletonBar(width: labelWidth, height: 10)
                SkeletonBar(width: max(52, labelWidth - 16), height: 8)
            }
            Spacer()
            SkeletonBar(width: 36, height: 10)
            SkeletonBar(width: 32, height: 10)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 7)
    }
}
