import Foundation

extension Double {
    func formattedCost() -> String {
        if self >= 1_000 { return String(format: "$%.1fK", self / 1_000) }
        if self >= 100 { return String(format: "$%.0f", self) }
        if self >= 10 { return String(format: "$%.1f", self) }
        return String(format: "$%.2f", self)
    }
}

extension Int {
    func formattedTokens() -> String {
        let value = Double(self)
        if value >= 1_000_000_000 { return Self.format(value / 1_000_000_000) + "B" }
        if value >= 1_000_000 { return Self.format(value / 1_000_000) + "M" }
        if value >= 1_000 { return Self.format(value / 1_000) + "K" }
        return "\(self)"
    }

    private static func format(_ value: Double) -> String {
        let places = value >= 10 ? 1 : 2
        var formatted = String(format: "%.\(places)f", value)
        while formatted.hasSuffix("0"), !formatted.hasSuffix(".0") {
            formatted.removeLast()
        }
        return formatted
    }
}

extension TimeInterval {
    func formattedWorkDuration() -> String {
        let roundedSeconds = Int(rounded())
        if roundedSeconds <= 0 { return "0m" }
        if roundedSeconds < 60 { return "\(roundedSeconds)s" }

        let totalMinutes = roundedSeconds / 60
        if totalMinutes < 60 { return "\(totalMinutes)m" }

        let hours = totalMinutes / 60
        let minutes = totalMinutes % 60
        return minutes == 0 ? "\(hours)h" : "\(hours)h \(minutes)m"
    }
}
