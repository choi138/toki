import SwiftUI

/// Case names are the raw values persisted with the user's tab order, so
/// renaming a case invalidates a stored order. `UsagePanelSettings` falls back
/// to the declared order for values it no longer recognizes.
enum PanelTab: String, CaseIterable, Hashable, Identifiable {
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
