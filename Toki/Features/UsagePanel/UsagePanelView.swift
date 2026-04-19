import SwiftUI

enum PanelTab {
    case overview
    case byModel
}

struct UsagePanelView: View {
    @StateObject private var service = UsageService()
    @State private var activeTab: PanelTab = .overview

    var body: some View {
        VStack(spacing: 0) {
            PanelHeaderView(
                isLoading: service.isLoading,
                lastFetchedAt: service.lastFetchedAt,
                onRefresh: { Task { await service.refresh() } }
            )
            panelDivider
            PanelDatePickerView(service: service)
            panelDivider
            PanelTabBarView(activeTab: $activeTab)
            panelDivider
            Group {
                if activeTab == .overview {
                    PanelHeroView(
                        usage: service.usageData,
                        isLoading: service.isLoading,
                        yesterdayTotal: service.shouldCompareAgainstYesterday
                            ? service.yesterdayTotalTokens
                            : nil
                    )
                    panelDivider
                    PanelTokenBreakdownView(usage: service.usageData, isLoading: service.isLoading)
                } else {
                    PanelByModelView(usage: service.usageData, isLoading: service.isLoading)
                }
            }
            panelDivider
            PanelFooterView()
        }
        .frame(width: 280)
        .background(Color(red: 0.09, green: 0.09, blue: 0.11))
        .preferredColorScheme(.dark)
        .task {
            await service.refresh()
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(180))
                if !Task.isCancelled {
                    await service.refresh()
                }
            }
        }
    }

    private var panelDivider: some View {
        Rectangle()
            .fill(Color.white.opacity(0.07))
            .frame(height: 0.5)
    }
}
