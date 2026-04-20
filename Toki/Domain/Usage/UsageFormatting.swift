import Foundation

extension Double {
    func formattedCost() -> String {
        if self >= 1000 { return String(format: "$%.1fK", self / 1000) }
        if self >= 100 { return String(format: "$%.0f", self) }
        if self >= 10 { return String(format: "$%.1f", self) }
        return String(format: "$%.2f", self)
    }
}

extension Int {
    func formattedTokens() -> String {
        let value = Double(self)
        let suffixes: [(divisor: Double, suffix: String)] = [
            (1_000_000_000, "B"),
            (1_000_000, "M"),
            (1000, "K"),
        ]

        guard let startIndex = suffixes.firstIndex(where: { value >= $0.divisor }) else {
            return "\(self)"
        }

        var index = startIndex
        while true {
            let candidate = suffixes[index]
            let representation = Self.representation(for: value / candidate.divisor)
            if representation.rounded < 1000 || index == 0 {
                return representation.formatted + candidate.suffix
            }
            index -= 1
        }
    }

    private static func representation(for value: Double) -> (rounded: Double, formatted: String) {
        let places = value >= 10 ? 1 : 2
        let scale = pow(10.0, Double(places))
        let rounded = (value * scale).rounded() / scale
        var formatted = String(format: "%.\(places)f", rounded)
        while formatted.hasSuffix("0"), !formatted.hasSuffix(".0") {
            formatted.removeLast()
        }
        return (rounded: rounded, formatted: formatted)
    }

    private static func format(_ value: Double) -> String {
        representation(for: value).formatted
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
