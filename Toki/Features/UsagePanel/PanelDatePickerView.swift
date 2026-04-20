import SwiftUI

struct PanelDatePickerView: View {
    @ObservedObject var service: UsageService
    @State private var showStartPicker = false
    @State private var showEndPicker = false

    private var calendar: Calendar {
        .current
    }

    private var isToday: Bool {
        calendar.isDateInToday(service.startDate) && service.isSingleDay
    }

    private static let fullDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "MMM d, yyyy"
        return formatter
    }()

    private static let shortDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "MMM d"
        return formatter
    }()

    var body: some View {
        HStack(spacing: 0) {
            if service.isRangeMode {
                rangeRow
            } else {
                singleDayRow
            }

            Spacer()

            if !isToday {
                todayButton
            }

            Button {
                service.isRangeMode.toggle()
                if !service.isRangeMode {
                    service.selectDay(service.startDate)
                }
                Task { await service.refresh() }
            } label: {
                Image(systemName: service.isRangeMode ? "calendar.badge.minus" : "calendar")
                    .font(.system(size: 12))
                    .foregroundColor(
                        service.isRangeMode
                            ? Color(red: 0.55, green: 0.45, blue: 1.0)
                            : Color.white.opacity(0.3))
            }
            .buttonStyle(.plain)
            .accessibilityLabel(
                service.isRangeMode ? "Switch to single day" : "Switch to date range")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 9)
    }

    private var todayButton: some View {
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

    private var singleDayRow: some View {
        HStack(spacing: 10) {
            navButton(icon: "chevron.left", accessibilityLabel: "Previous day") {
                service.selectDay(calendar.date(byAdding: .day, value: -1, to: service.startDate)!)
                Task { await service.refresh() }
            }

            Button { showStartPicker.toggle() } label: {
                Text(Self.fullDateFormatter.string(from: service.startDate))
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(.white)
            }
            .buttonStyle(.plain)
            .popover(isPresented: $showStartPicker, arrowEdge: .bottom) {
                calendarPicker(
                    date: Binding(
                        get: { service.startDate },
                        set: { selectedDate in
                            let newDay = calendar.startOfDay(for: selectedDate)
                            showStartPicker = false
                            guard newDay != service.startDate else { return }
                            service.selectDay(newDay)
                            Task { await service.refresh() }
                        }))
            }

            navButton(
                icon: "chevron.right",
                disabled: isToday,
                accessibilityLabel: "Next day") {
                    let nextDay = calendar.date(byAdding: .day, value: 1, to: service.startDate)!
                    guard nextDay <= Date() else { return }
                    service.selectDay(nextDay)
                    Task { await service.refresh() }
                }
        }
    }

    private var rangeRow: some View {
        HStack(spacing: 6) {
            Button { showStartPicker.toggle() } label: {
                dateChip(Self.shortDateFormatter.string(from: service.startDate))
            }
            .buttonStyle(.plain)
            .popover(isPresented: $showStartPicker, arrowEdge: .bottom) {
                calendarPicker(
                    date: Binding(
                        get: { service.startDate },
                        set: { selectedDate in
                            service.selectRangeStart(selectedDate)
                            Task { await service.refresh() }
                            showStartPicker = false
                        }))
            }

            Text("–")
                .font(.system(size: 11))
                .foregroundColor(Color.white.opacity(0.35))

            Button { showEndPicker.toggle() } label: {
                dateChip(
                    Self.shortDateFormatter.string(
                        from: calendar.date(byAdding: .day, value: -1, to: service.endDate) ?? service.endDate))
            }
            .buttonStyle(.plain)
            .popover(isPresented: $showEndPicker, arrowEdge: .bottom) {
                calendarPicker(
                    date: Binding(
                        get: { calendar.date(byAdding: .day, value: -1, to: service.endDate) ?? service.endDate },
                        set: { selectedDate in
                            service.selectRangeEnd(selectedDate)
                            Task { await service.refresh() }
                            showEndPicker = false
                        }))
            }
        }
    }

    private func navButton(
        icon: String,
        disabled: Bool = false,
        accessibilityLabel: String,
        action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 10, weight: .semibold))
                .foregroundColor(disabled ? Color.white.opacity(0.15) : Color.white.opacity(0.5))
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .accessibilityLabel(accessibilityLabel)
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
