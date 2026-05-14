import Combine
import SwiftUI

enum UsagePanelLayout {
    static let width: CGFloat = 320
    static let height: CGFloat = 420
}

enum PanelTab {
    case overview
    case hourly
    case byModel
    case sources
    case workTime
}

struct UsagePanelView: View {
    @StateObject private var viewModel = UsagePanelViewModel()
    @State private var activeTab: PanelTab = .overview
    @State private var isShowingSecurityAudit = false
    @State private var isShowingSettings = false
    @State private var refreshCoordinator = UsagePanelRefreshCoordinator()

    var body: some View {
        VStack(spacing: 0) {
            PanelHeaderView(
                isLoading: viewModel.isLoading,
                lastFetchedAt: viewModel.lastFetchedAt,
                onRefresh: refresh,
                onSecurityAudit: { isShowingSecurityAudit = true },
                onSettings: { isShowingSettings = true })
            panelDivider
            PanelDatePickerView(
                startDate: viewModel.startDate,
                endDate: viewModel.endDate,
                isRangeMode: $viewModel.isRangeMode,
                isSingleDay: viewModel.isSingleDay,
                selectDay: selectDay,
                selectRangeStart: selectRangeStart,
                selectRangeEnd: selectRangeEnd,
                refresh: refresh)
            panelDivider
            PanelTabBarView(activeTab: $activeTab)
            panelDivider
            ScrollView(.vertical) {
                tabContent
                    .frame(maxWidth: .infinity, alignment: .top)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            panelDivider
            PanelFooterView()
        }
        .frame(
            width: UsagePanelLayout.width,
            height: UsagePanelLayout.height,
            alignment: .top)
        .background(Color(red: 0.09, green: 0.09, blue: 0.11))
        .preferredColorScheme(.dark)
        .sheet(isPresented: $isShowingSettings) {
            PanelSettingsView(settings: viewModel.settings, readerNames: viewModel.readerNames)
        }
        .sheet(isPresented: $isShowingSecurityAudit) {
            SecurityAuditView()
        }
        .onAppear {
            startRefreshLoop(refreshImmediately: true)
        }
        .onDisappear {
            refreshCoordinator.cancel()
        }
        .onReceive(viewModel.settings.$enabledReaderNames.dropFirst()) { _ in
            scheduleSettingsRefresh()
        }
        .onReceive(viewModel.settings.$showsZeroSourceRows.dropFirst()) { _ in
            scheduleSettingsRefresh()
        }
        .onReceive(viewModel.settings.refreshIntervalPublisher.dropFirst()) { _ in
            startRefreshLoop(refreshImmediately: false)
        }
    }

    @ViewBuilder
    private var tabContent: some View {
        switch activeTab {
        case .overview:
            PanelHeroView(
                usage: viewModel.usageData,
                isLoading: viewModel.isLoading,
                yesterdayTotal: viewModel.shouldCompareAgainstYesterday
                    ? viewModel.yesterdayTotalTokens
                    : nil)
            panelDivider
            PanelTokenBreakdownView(usage: viewModel.usageData, isLoading: viewModel.isLoading)
        case .hourly:
            PanelHourlyUsageView(usage: viewModel.usageData, isLoading: viewModel.isLoading)
        case .byModel:
            PanelByModelView(usage: viewModel.usageData, isLoading: viewModel.isLoading)
        case .sources:
            PanelSourceView(
                usage: viewModel.usageData,
                readerStatuses: viewModel.readerStatuses,
                isLoading: viewModel.isLoading)
        case .workTime:
            PanelWorkTimeView(usage: viewModel.usageData, isLoading: viewModel.isLoading)
        }
    }

    private var panelDivider: some View {
        Rectangle()
            .fill(Color.white.opacity(0.07))
            .frame(height: 0.5)
    }

    private func refresh() {
        Task { await viewModel.refresh() }
    }

    private func selectDay(_ date: Date) {
        viewModel.selectDay(date)
        refresh()
    }

    private func selectRangeStart(_ date: Date) {
        viewModel.selectRangeStart(date)
        refresh()
    }

    private func selectRangeEnd(_ date: Date) {
        viewModel.selectRangeEnd(date)
        refresh()
    }

    private func startRefreshLoop(refreshImmediately: Bool) {
        refreshCoordinator.startLoop(
            refreshImmediately: refreshImmediately,
            intervalSeconds: { viewModel.settings.refreshIntervalSeconds },
            refresh: { await viewModel.refresh() })
    }

    private func scheduleSettingsRefresh() {
        refreshCoordinator.scheduleSettingsRefresh {
            await viewModel.refresh()
        }
    }
}
