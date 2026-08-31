import Foundation

func earliestDeferredEventTimestamp(
    in readerUsages: [AgentReaderUsage],
    after now: Date,
    before coveredTo: Date) throws -> Date? {
    var earliestTimestamp: Date?
    for readerUsage in readerUsages {
        try Task.checkCancellation()
        for event in readerUsage.usage.tokenEvents {
            try updateEarliestDeferredTimestamp(
                &earliestTimestamp,
                candidate: event.timestamp,
                after: now,
                before: coveredTo)
        }
        for event in readerUsage.usage.activityEvents {
            try updateEarliestDeferredTimestamp(
                &earliestTimestamp,
                candidate: event.timestamp,
                after: now,
                before: coveredTo)
        }
    }
    return earliestTimestamp
}

private func updateEarliestDeferredTimestamp(
    _ earliestTimestamp: inout Date?,
    candidate: Date,
    after now: Date,
    before coveredTo: Date) throws {
    try Task.checkCancellation()
    guard candidate > now, candidate < coveredTo else { return }
    if earliestTimestamp.map({ candidate < $0 }) ?? true {
        earliestTimestamp = candidate
    }
}
