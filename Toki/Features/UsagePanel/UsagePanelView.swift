import Combine
import SwiftUI

enum UsagePanelLayout {
    static let width: CGFloat = 320
    static let height: CGFloat = 420
}

enum PanelTab: CaseIterable, Hashable, Identifiable {
    case overview
    case projects
    case byModel
    case sources
    case workTime
    case hourly

    var id: Self {
        self
    }

    var title: String {
        switch self {
        case .overview:
            "Overview"
        case .projects:
            "Projects"
        case .byModel:
            "Models"
        case .sources:
            "Sources"
        case .workTime:
            "Time"
        case .hourly:
            "Hourly"
        }
    }

    var systemImage: String {
        switch self {
        case .overview:
            "chart.pie.fill"
        case .projects:
            "folder.fill"
        case .byModel:
            "cpu"
        case .sources:
            "tray.full.fill"
        case .workTime:
            "clock.fill"
        case .hourly:
            "chart.bar.fill"
        }
    }

    var accentColor: Color {
        switch self {
        case .overview:
            Color(red: 0.55, green: 0.45, blue: 1.0)
        case .projects:
            Color(red: 0.40, green: 0.68, blue: 1.0)
        case .byModel:
            Color(red: 0.42, green: 0.84, blue: 0.70)
        case .sources:
            Color(red: 1.0, green: 0.66, blue: 0.36)
        case .workTime:
            Color(red: 0.95, green: 0.52, blue: 0.70)
        case .hourly:
            Color(red: 0.75, green: 0.70, blue: 1.0)
        }
    }
}

struct UsagePanelView: View {
    @StateObject private var viewModel = UsagePanelViewModel()
    @ObservedObject private var tokenVelocityState: TokenVelocityState
    @State private var activeTab: PanelTab = .overview
    @State private var isShowingSecurityAudit = false
    @State private var isShowingSettings = false
    @State private var refreshCoordinator = UsagePanelRefreshCoordinator()

    @MainActor
    init() {
        tokenVelocityState = TokenVelocityState()
    }

    init(tokenVelocityState: TokenVelocityState) {
        self.tokenVelocityState = tokenVelocityState
    }

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
            PanelUsageScopePickerView(
                selectedScope: viewModel.selectedUsageScope,
                originReports: viewModel.originReports,
                onSelect: viewModel.selectUsageScope)
            panelDivider
            PanelTabBarView(activeTab: $activeTab)
            panelDivider
            ScrollView(.vertical) {
                tabContent
                    .frame(maxWidth: .infinity, alignment: .top)
            }
            .usagePanelScrollIndicators()
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
            PanelSettingsView(
                settings: viewModel.settings,
                readerNames: viewModel.readerNames,
                onRemoteSyncChange: refresh)
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
                .task {
                    await viewModel.refreshPeriodTokenTotalsIfNeeded()
                }
            if showsDeviceBreakdown {
                panelDivider
                PanelDeviceBreakdownView(
                    reports: viewModel.originReports,
                    onSelect: { viewModel.selectUsageScope(.origin($0)) })
            }
            panelDivider
            PanelTokenTotalsView(
                summaries: viewModel.periodTokenTotals,
                isLoading: viewModel.isLoadingPeriodTokenTotals)
            panelDivider
            PanelTokenBreakdownView(
                usage: viewModel.usageData,
                liveTokensPerSecond: scopedLiveTokensPerSecond,
                liveTokenLabel: liveTokenLabel,
                isLoading: viewModel.isLoading)
        case .projects:
            PanelProjectTimelineView(usage: viewModel.usageData, isLoading: viewModel.isLoading)
        case .hourly:
            PanelHourlyUsageView(usage: viewModel.usageData, isLoading: viewModel.isLoading)
        case .byModel:
            PanelByModelView(usage: viewModel.usageData, isLoading: viewModel.isLoading)
        case .sources:
            PanelSourceView(
                usage: viewModel.usageData,
                originReports: viewModel.originReports,
                selectedScope: viewModel.selectedUsageScope,
                scopeTitle: viewModel.usageScopeTitle,
                readerStatuses: viewModel.readerStatuses,
                isLoading: viewModel.isLoading,
                onSelectOrigin: { viewModel.selectUsageScope(.origin($0)) })
        case .workTime:
            PanelWorkTimeView(usage: viewModel.usageData, isLoading: viewModel.isLoading)
        }
    }

    private var panelDivider: some View {
        Rectangle()
            .fill(Color.white.opacity(0.07))
            .frame(height: 0.5)
    }

    private var showsDeviceBreakdown: Bool {
        viewModel.selectedUsageScope == .all && viewModel.originReports.count > 1
    }

    private var scopedLiveTokensPerSecond: Double? {
        switch viewModel.selectedUsageScope {
        case .all, .origin(.local):
            tokenVelocityState.liveTokensPerSecond
        case .origin:
            nil
        }
    }

    private var liveTokenLabel: String {
        viewModel.selectedUsageScope == .all ? "This Mac Live TPS" : "Live TPS"
    }

    private func refresh() {
        Task { await refreshVisibleData() }
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
            refresh: { await refreshVisibleData() })
    }

    private func scheduleSettingsRefresh() {
        refreshCoordinator.scheduleSettingsRefresh {
            await refreshVisibleData()
        }
    }

    private func refreshVisibleData() async {
        await viewModel.refresh()
        if activeTab == .overview {
            await viewModel.refreshPeriodTokenTotalsIfNeeded()
        }
    }
}

struct PanelUsageScopePickerView: View {
    let selectedScope: UsageScope
    let originReports: [UsageOriginReport]
    let onSelect: (UsageScope) -> Void

    var body: some View {
        HStack(spacing: 8) {
            Text("DEVICE")
                .font(.system(size: 9, weight: .semibold))
                .foregroundColor(Color.white.opacity(0.24))
                .tracking(1.2)
            Spacer(minLength: 8)
            Menu {
                scopeButton(
                    title: "All Devices",
                    subtitle: nil,
                    systemImage: "square.grid.2x2",
                    scope: .all)
                Divider()
                ForEach(originReports) { report in
                    scopeButton(
                        title: report.origin.name,
                        subtitle: panelDevicePlatformLabel(for: report.origin),
                        systemImage: panelDeviceSystemImage(for: report.origin),
                        scope: .origin(report.id))
                }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: selectedSystemImage)
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundColor(Color.white.opacity(0.5))
                    Text(selectedTitle)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(Color.white.opacity(0.76))
                        .lineLimit(1)
                    Image(systemName: "chevron.down")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundColor(Color.white.opacity(0.3))
                }
                .padding(.horizontal, 9)
                .padding(.vertical, 5)
                .background(Color.white.opacity(0.06))
                .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
            }
            .menuStyle(.borderlessButton)
            .frame(maxWidth: 200, alignment: .trailing)
            .accessibilityLabel(Text("Usage device"))
            .accessibilityValue(Text(selectedTitle))
        }
        .padding(.horizontal, 16)
        .frame(height: 34)
    }

    private var selectedOrigin: UsageOrigin? {
        guard case let .origin(originID) = selectedScope else { return nil }
        return originReports.first { $0.id == originID }?.origin
    }

    private var selectedTitle: String {
        selectedOrigin?.name ?? "All Devices"
    }

    private var selectedSystemImage: String {
        selectedOrigin.map(panelDeviceSystemImage) ?? "square.grid.2x2"
    }

    private func scopeButton(
        title: String,
        subtitle: String?,
        systemImage: String,
        scope: UsageScope) -> some View {
        Button {
            onSelect(scope)
        } label: {
            HStack {
                Label(menuTitle(title: title, subtitle: subtitle), systemImage: systemImage)
                if selectedScope == scope {
                    Image(systemName: "checkmark")
                }
            }
        }
    }

    private func menuTitle(title: String, subtitle: String?) -> String {
        guard let subtitle else { return title }
        return "\(title) · \(subtitle)"
    }
}

private extension View {
    @ViewBuilder
    func usagePanelScrollIndicators() -> some View {
        if #available(macOS 14.0, *) {
            scrollIndicators(.visible, axes: .vertical)
                .scrollIndicatorsFlash(onAppear: true)
        } else {
            scrollIndicators(.visible, axes: .vertical)
        }
    }
}
