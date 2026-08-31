import TokiSyncProtocol

struct AgentSnapshotEventLimits: Equatable {
    static let protocolMaximum = AgentSnapshotEventLimits(
        maximumTokenEventCount: RemoteUsageSnapshotValidator.maximumTokenEventCount,
        maximumCostEventCount: RemoteUsageSnapshotValidator.maximumCostEventCount,
        maximumActivityEventCount: RemoteUsageSnapshotValidator.maximumActivityEventCount)

    let maximumTokenEventCount: Int
    let maximumCostEventCount: Int
    let maximumActivityEventCount: Int
}

func boundedMostRecentEvents<Event>(_ events: [Event], maximumCount: Int) -> [Event] {
    let boundedCount = max(0, maximumCount)
    guard events.count > boundedCount else { return events }
    return Array(events.suffix(boundedCount))
}
