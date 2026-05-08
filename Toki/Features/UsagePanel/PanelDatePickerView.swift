import SwiftUI

struct PanelDatePickerView: View {
    let startDate: Date
    let endDate: Date
    @Binding var isRangeMode: Bool
    let isSingleDay: Bool
    let selectDay: (Date) -> Void
    let selectRangeStart: (Date) -> Void
    let selectRangeEnd: (Date) -> Void
    let refresh: () -> Void

    @State private var showStartPicker = false
    @State private var showEndPicker = false

    private var calendar: Calendar {
        .current
    }

    private var isToday: Bool {
        calendar.isDateInToday(startDate) && isSingleDay
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
            if isRangeMode {
                rangeRow
            } else {
                singleDayRow
            }

            Spacer()

            if !isToday {
                todayButton
            }

            Button {
                isRangeMode.toggle()
                if !isRangeMode {
                    selectDay(startDate)
                } else {
                    refresh()
                }
            } label: {
                Image(systemName: isRangeMode ? "calendar.badge.minus" : "calendar")
                    .font(.system(size: 12))
                    .foregroundColor(
                        isRangeMode
                            ? Color(red: 0.55, green: 0.45, blue: 1.0)
                            : Color.white.opacity(0.3))
            }
            .buttonStyle(.plain)
            .accessibilityLabel(
                isRangeMode ? "Switch to single day" : "Switch to date range")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 9)
    }

    private var todayButton: some View {
        Button {
            isRangeMode = false
            selectDay(Date())
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
                guard let previousDay = calendar.date(byAdding: .day, value: -1, to: startDate) else { return }
                selectDay(previousDay)
            }

            Button { showStartPicker.toggle() } label: {
                Text(Self.fullDateFormatter.string(from: startDate))
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(.white)
            }
            .buttonStyle(.plain)
            .popover(isPresented: $showStartPicker, arrowEdge: .bottom) {
                calendarPicker(
                    date: Binding(
                        get: { startDate },
                        set: { selectedDate in
                            let newDay = calendar.startOfDay(for: selectedDate)
                            showStartPicker = false
                            guard newDay != startDate else { return }
                            selectDay(newDay)
                        }))
            }

            navButton(
                icon: "chevron.right",
                disabled: isToday,
                accessibilityLabel: "Next day") {
                    guard let nextDay = calendar.date(byAdding: .day, value: 1, to: startDate) else { return }
                    guard nextDay <= Date() else { return }
                    selectDay(nextDay)
                }
        }
    }

    private var rangeRow: some View {
        HStack(spacing: 6) {
            Button { showStartPicker.toggle() } label: {
                dateChip(Self.shortDateFormatter.string(from: startDate))
            }
            .buttonStyle(.plain)
            .popover(isPresented: $showStartPicker, arrowEdge: .bottom) {
                calendarPicker(
                    date: Binding(
                        get: { startDate },
                        set: { selectedDate in
                            selectRangeStart(selectedDate)
                            showStartPicker = false
                        }))
            }

            Text("–")
                .font(.system(size: 11))
                .foregroundColor(Color.white.opacity(0.35))

            Button { showEndPicker.toggle() } label: {
                dateChip(
                    Self.shortDateFormatter.string(
                        from: calendar.date(byAdding: .day, value: -1, to: endDate) ?? endDate))
            }
            .buttonStyle(.plain)
            .popover(isPresented: $showEndPicker, arrowEdge: .bottom) {
                calendarPicker(
                    date: Binding(
                        get: { calendar.date(byAdding: .day, value: -1, to: endDate) ?? endDate },
                        set: { selectedDate in
                            selectRangeEnd(selectedDate)
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
