import SwiftUI

struct PanelHeroComparisonContent {
    let symbolName: String
    let text: String
    let color: Color

    static func make(
        currentTotal: Int,
        yesterdayTotal: Int?
    ) -> PanelHeroComparisonContent? {
        guard let yesterdayTotal else { return nil }

        if yesterdayTotal == 0 {
            if currentTotal == 0 {
                return PanelHeroComparisonContent(
                    symbolName: "minus",
                    text: "0% from yesterday",
                    color: Color.white.opacity(0.35)
                )
            }

            return PanelHeroComparisonContent(
                symbolName: "arrow.up",
                text: "No usage yesterday",
                color: Color(red: 1.0, green: 0.45, blue: 0.4)
            )
        }

        let delta = currentTotal - yesterdayTotal
        let pct = Int(abs(Double(delta) / Double(yesterdayTotal) * 100))
        let isUp = delta >= 0

        return PanelHeroComparisonContent(
            symbolName: isUp ? "arrow.up" : "arrow.down",
            text: "\(pct)% from yesterday",
            color: isUp
                ? Color(red: 1.0, green: 0.45, blue: 0.4)
                : Color(red: 0.4, green: 0.9, blue: 0.6)
        )
    }
}
