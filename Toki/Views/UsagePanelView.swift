import SwiftUI

// MARK: - Panel Root

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
                        ? service.yesterdayTotalTokens : nil
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
                if !Task.isCancelled { await service.refresh() }
            }
        }
    }

    private var panelDivider: some View {
        Rectangle()
            .fill(Color.white.opacity(0.07))
            .frame(height: 0.5)
    }
}

// MARK: - Skeleton Bar

private struct SkeletonBar: View {
    var width: CGFloat?
    var height: CGFloat = 12
    var cornerRadius: CGFloat = 4

    @State private var opacity: Double = 0.18

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

// MARK: - Tab

private enum PanelTab {
    case overview
    case byModel
}

// MARK: - Tab Bar

private struct PanelTabBarView: View {
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
    }
}

// MARK: - Header

private struct PanelHeaderView: View {
    let isLoading: Bool
    let lastFetchedAt: Date?
    let onRefresh: () -> Void

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f
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
                    } else {
                        Image(systemName: "arrow.clockwise")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundColor(Color.white.opacity(0.4))
                    }
                }
            }
            .buttonStyle(.plain)
            .padding(.leading, 6)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 11)
    }
}

// MARK: - Date Picker

private struct PanelDatePickerView: View {
    @ObservedObject var service: UsageService
    @State private var showStartPicker = false
    @State private var showEndPicker   = false

    private var cal: Calendar { Calendar.current }

    private var isToday: Bool {
        cal.isDateInToday(service.startDate) && service.isSingleDay
    }

    private static let fmt: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "MMM d, yyyy"; return f
    }()
    private static let fmtShort: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "MMM d"; return f
    }()

    var body: some View {
        HStack(spacing: 0) {
            if service.isRangeMode {
                rangeRow
            } else {
                singleDayRow
            }

            Spacer()

            // Today 버튼 — 오늘이 아닐 때만 표시
            if !isToday {
                Button {
                    service.isRangeMode = false
                    service.selectDay(Date())
                    Task { await service.refresh() }
                } label: {
                    Text("Today")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundColor(Color(red: 0.55, green: 0.45, blue: 1.0))
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3)
                        .background(Color(red: 0.55, green: 0.45, blue: 1.0).opacity(0.12))
                        .clipShape(RoundedRectangle(cornerRadius: 4))
                }
                .buttonStyle(.plain)
                .padding(.trailing, 6)
            }

            Button {
                service.isRangeMode.toggle()
                if !service.isRangeMode { service.selectDay(service.startDate) }
                Task { await service.refresh() }
            } label: {
                Image(systemName: service.isRangeMode ? "calendar.badge.minus" : "calendar")
                    .font(.system(size: 12))
                    .foregroundColor(service.isRangeMode
                        ? Color(red: 0.55, green: 0.45, blue: 1.0)
                        : Color.white.opacity(0.3))
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 9)
    }

    // ── 단일 날짜 ────────────────────────────────────────────────────────────
    private var singleDayRow: some View {
        HStack(spacing: 10) {
            navButton(icon: "chevron.left") {
                service.selectDay(cal.date(byAdding: .day, value: -1, to: service.startDate)!)
                Task { await service.refresh() }
            }

            Button { showStartPicker.toggle() } label: {
                Text(Self.fmt.string(from: service.startDate))
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(.white)
            }
            .buttonStyle(.plain)
            .popover(isPresented: $showStartPicker, arrowEdge: .bottom) {
                calendarPicker(date: Binding(
                    get: { service.startDate },
                    set: {
                        let newDay = cal.startOfDay(for: $0)
                        showStartPicker = false
                        guard newDay != service.startDate else { return }
                        service.selectDay(newDay)
                        Task { await service.refresh() }
                    }
                ))
            }

            navButton(icon: "chevron.right", disabled: isToday) {
                let next = cal.date(byAdding: .day, value: 1, to: service.startDate)!
                guard next <= Date() else { return }
                service.selectDay(next)
                Task { await service.refresh() }
            }
        }
    }

    // ── 날짜 범위 ────────────────────────────────────────────────────────────
    private var rangeRow: some View {
        HStack(spacing: 6) {
            Button { showStartPicker.toggle() } label: {
                dateChip(Self.fmtShort.string(from: service.startDate))
            }
            .buttonStyle(.plain)
            .popover(isPresented: $showStartPicker, arrowEdge: .bottom) {
                calendarPicker(date: Binding(
                    get: { service.startDate },
                    set: {
                        service.startDate = cal.startOfDay(for: $0)
                        if service.startDate >= service.endDate {
                            service.endDate = cal.date(byAdding: .day, value: 1, to: service.startDate)!
                        }
                        Task { await service.refresh() }
                        showStartPicker = false
                    }
                ))
            }

            Text("–")
                .font(.system(size: 11))
                .foregroundColor(Color.white.opacity(0.35))

            Button { showEndPicker.toggle() } label: {
                dateChip(Self.fmtShort.string(
                    from: cal.date(byAdding: .day, value: -1, to: service.endDate) ?? service.endDate
                ))
            }
            .buttonStyle(.plain)
            .popover(isPresented: $showEndPicker, arrowEdge: .bottom) {
                calendarPicker(date: Binding(
                    get: { cal.date(byAdding: .day, value: -1, to: service.endDate) ?? service.endDate },
                    set: {
                        service.endDate = cal.date(byAdding: .day, value: 1, to: cal.startOfDay(for: $0)) ?? service.endDate
                        Task { await service.refresh() }
                        showEndPicker = false
                    }
                ))
            }
        }
    }

    // ── 서브 컴포넌트 ─────────────────────────────────────────────────────────
    private func navButton(icon: String, disabled: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 10, weight: .semibold))
                .foregroundColor(disabled ? Color.white.opacity(0.15) : Color.white.opacity(0.5))
        }
        .buttonStyle(.plain)
        .disabled(disabled)
    }

    private func dateChip(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11, weight: .medium))
            .foregroundColor(.white)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(Color.white.opacity(0.08))
            .clipShape(RoundedRectangle(cornerRadius: 5))
    }

    private func calendarPicker(date: Binding<Date>) -> some View {
        DatePicker("", selection: date, in: ...Date(), displayedComponents: .date)
            .datePickerStyle(.graphical)
            .labelsHidden()
            .padding(8)
            .frame(width: 260)
            .preferredColorScheme(.dark)
    }
}

// MARK: - Hero (Total Tokens)

private struct PanelHeroView: View {
    let usage: UsageData
    let isLoading: Bool
    let yesterdayTotal: Int?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("TOTAL TOKENS")
                .font(.system(size: 10, weight: .semibold))
                .foregroundColor(Color.white.opacity(0.3))
                .tracking(1.5)

            if isLoading {
                SkeletonBar(width: 148, height: 44, cornerRadius: 8)
            } else {
                Text(usage.totalTokens.formattedTokens())
                    .font(.system(size: 42, weight: .bold, design: .rounded))
                    .tracking(-1.5)
                    .foregroundColor(.white)
            }

            if !isLoading, let comparison = comparisonContent {
                HStack(spacing: 3) {
                    Image(systemName: comparison.symbolName)
                        .font(.system(size: 9, weight: .bold))
                    Text(comparison.text)
                        .font(.system(size: 10, weight: .medium))
                }
                .foregroundColor(comparison.color)
            }

        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 16)
        .padding(.vertical, 20)
    }

    private var comparisonContent: PanelHeroComparisonContent? {
        PanelHeroComparisonContent.make(
            currentTotal: usage.totalTokens,
            yesterdayTotal: yesterdayTotal
        )
    }
}

// MARK: - Token Breakdown

private struct PanelTokenBreakdownView: View {
    let usage: UsageData
    let isLoading: Bool

    var body: some View {
        VStack(spacing: 0) {
            StatRowView(label: "Input", value: usage.inputTokens.formattedTokens(), accent: Color(red: 0.4, green: 0.8, blue: 1.0), isLoading: isLoading)
            StatRowView(label: "Output", value: usage.outputTokens.formattedTokens(), accent: Color(red: 0.6, green: 1.0, blue: 0.7), isLoading: isLoading)
            StatRowView(label: "Cache Read", value: usage.cacheReadTokens.formattedTokens(), accent: Color(red: 1.0, green: 0.8, blue: 0.4), isLoading: isLoading)
            StatRowView(label: "Cache Hit", value: String(format: "%.1f%%", usage.cacheEfficiency), accent: Color(red: 1.0, green: 0.65, blue: 0.2), isLoading: isLoading)
            StatRowView(label: "Estimated Cost", value: usage.cost.formattedCost(), accent: Color(red: 0.4, green: 0.9, blue: 0.6), isLoading: isLoading)
        }
        .padding(.vertical, 6)
    }
}

// MARK: - Summary (Cost)

private struct PanelSummaryView: View {
    let usage: UsageData
    let isLoading: Bool

    var body: some View {
        VStack(spacing: 0) {
            StatRowView(label: "Estimated Cost", value: String(format: "$%.2f", usage.cost), accent: Color(red: 0.4, green: 0.9, blue: 0.6), isLoading: isLoading)
        }
        .padding(.vertical, 6)
    }
}

// MARK: - By Model Tab

private let skeletonRowWidths: [CGFloat] = [88, 72, 96, 64, 80]

private struct PanelByModelView: View {
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
            } else if usage.perModel.isEmpty {
                Text("No data")
                    .font(.system(size: 12))
                    .foregroundColor(Color.white.opacity(0.3))
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, 24)
            } else {
                VStack(spacing: 0) {
                    ForEach(usage.perModel, id: \.id) { stat in
                        ModelStatRowView(stat: stat)
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
            SkeletonBar(width: labelWidth, height: 10)
            Spacer()
            SkeletonBar(width: 36, height: 10)
            SkeletonBar(width: 32, height: 10)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 7)
    }
}

private struct ModelStatRowView: View {
    let stat: ModelStat

    var body: some View {
        HStack(alignment: .center, spacing: 6) {
            Circle()
                .fill(accentColor.opacity(0.5))
                .frame(width: 5, height: 5)
            Text(displayName)
                .font(.system(size: 11))
                .foregroundColor(Color.white.opacity(0.45))
                .lineLimit(1)
            Spacer()
            Text(stat.totalTokens.formattedTokens())
                .font(.system(size: 11, weight: .semibold, design: .rounded))
                .foregroundColor(Color.white.opacity(0.7))
                .frame(width: 44, alignment: .trailing)
            Text(stat.cost > 0 ? stat.cost.formattedCost() : "—")
                .font(.system(size: 11, weight: .semibold, design: .rounded))
                .foregroundColor(stat.cost > 0 ? Color(red: 0.4, green: 0.9, blue: 0.6) : Color.white.opacity(0.25))
                .frame(width: 56, alignment: .trailing)
                .lineLimit(1)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 7)
    }

    private var displayName: String {
        let id = stat.id
        let baseName = id.hasPrefix("claude-") ? String(id.dropFirst(7)) : id
        guard !stat.sources.isEmpty else { return baseName }
        return "\(baseName) · \(sourceLabel)"
    }

    private var sourceLabel: String {
        if stat.sources.count == 1 { return stat.sources[0] }
        let head = stat.sources.prefix(2).joined(separator: ", ")
        let remainder = stat.sources.count - 2
        return remainder > 0 ? "\(head) +\(remainder)" : head
    }

    private var accentColor: Color {
        let id = stat.id
        if id.hasPrefix("claude-") { return Color(red: 0.55, green: 0.45, blue: 1.0) }
        if id.hasPrefix("gpt-") { return Color(red: 0.4, green: 0.9, blue: 0.5) }
        if id.hasPrefix("gemini-") { return Color(red: 0.3, green: 0.7, blue: 1.0) }
        if id.hasPrefix("grok-") { return Color(red: 1.0, green: 0.8, blue: 0.2) }
        return Color.white.opacity(0.5)
    }
}

// MARK: - Reusable Stat Row

private struct StatRowView: View {
    let label: String
    let value: String
    let accent: Color
    var isLoading: Bool = false

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
                SkeletonBar(width: CGFloat.random(in: 36...56), height: 11)
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

// MARK: - Footer

private struct PanelFooterView: View {
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
