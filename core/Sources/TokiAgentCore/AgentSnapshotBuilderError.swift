import Foundation

enum AgentSnapshotBuilderError: LocalizedError {
    case cacheResetFailed, invalidDateRange
    case readerFailed(String)
    case snapshotLimitExceeded
    case sourceLimitExceeded
    case sourceMountRefreshRequired
    case sourceInspectionFailed

    var requiresProcessRestart: Bool {
        switch self {
        case .sourceMountRefreshRequired, .sourceInspectionFailed:
            true
        default:
            false
        }
    }

    var errorDescription: String? {
        switch self {
        case .cacheResetFailed:
            "Could not safely reset the local usage parse caches."
        case .invalidDateRange:
            "Could not construct the configured retention window."
        case let .readerFailed(name):
            "The \(name) usage reader failed. The previous remote snapshot was preserved."
        case .snapshotLimitExceeded:
            "The local usage snapshot exceeds the safe synchronization limit."
        case .sourceLimitExceeded:
            "A local usage source exceeds the safe inspection limit."
        case .sourceMountRefreshRequired:
            "A sandboxed usage source was replaced. Restarting the Agent to refresh its read-only mounts."
        case .sourceInspectionFailed:
            "Could not inspect local usage source metadata. Run `toki-agent doctor`."
        }
    }
}
