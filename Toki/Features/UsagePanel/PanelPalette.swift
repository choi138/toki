import SwiftUI

func panelAccentColor(forSource source: String) -> Color {
    switch source {
    case "Claude Code":
        Color(red: 0.55, green: 0.45, blue: 1.0)
    case "Codex":
        Color(red: 0.4, green: 0.9, blue: 0.5)
    case "Cursor":
        Color(red: 0.45, green: 0.75, blue: 1.0)
    case "Gemini CLI":
        Color(red: 0.3, green: 0.7, blue: 1.0)
    case "OpenCode":
        Color(red: 1.0, green: 0.72, blue: 0.35)
    case "OpenClaw":
        Color(red: 0.85, green: 0.68, blue: 1.0)
    default:
        Color.white.opacity(0.5)
    }
}
