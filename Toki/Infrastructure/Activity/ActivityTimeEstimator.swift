import Foundation

struct ActivityTimeEvent<Key: Hashable> {
    let streamID: String
    let timestamp: Date
    let key: Key?
}

struct ActivityTimeEstimate<Key: Hashable> {
    let totalSeconds: TimeInterval
    let secondsByKey: [Key: TimeInterval]

    static var zero: Self {
        ActivityTimeEstimate(totalSeconds: 0, secondsByKey: [:])
    }
}

private struct ActivityInterval<Key: Hashable> {
    let start: Date
    let end: Date
    let key: Key?
}

enum ActivityTimeEstimator {
    static let defaultMaximumGap: TimeInterval = 300
    static let defaultMinimumSlice: TimeInterval = 30

    static func estimate<Key: Hashable>(
        events: [ActivityTimeEvent<Key>],
        maximumGap: TimeInterval = defaultMaximumGap,
        minimumSlice: TimeInterval = defaultMinimumSlice
    ) -> ActivityTimeEstimate<Key> {
        let intervals = estimatedIntervals(
            from: events,
            maximumGap: maximumGap,
            minimumSlice: minimumSlice
        )
        guard !intervals.isEmpty else { return .zero }

        let totalSeconds = mergedDuration(intervals.map { DateInterval(start: $0.start, end: $0.end) })
        let secondsByKey = Dictionary(
            grouping: intervals.compactMap { interval -> (Key, DateInterval)? in
                guard let key = interval.key else { return nil }
                return (key, DateInterval(start: interval.start, end: interval.end))
            },
            by: \.0
        ).reduce(into: [Key: TimeInterval]()) { result, item in
            let (key, intervalsForKey) = item
            result[key] = mergedDuration(intervalsForKey.map(\.1))
        }

        return ActivityTimeEstimate(totalSeconds: totalSeconds, secondsByKey: secondsByKey)
    }

    private static func estimatedSlice(
        currentTimestamp: Date,
        nextTimestamp: Date?,
        maximumGap: TimeInterval,
        minimumSlice: TimeInterval
    ) -> TimeInterval {
        guard let nextTimestamp else { return minimumSlice }

        let gap = nextTimestamp.timeIntervalSince(currentTimestamp)
        guard gap > 0 else { return 0 }
        return gap <= maximumGap ? gap : minimumSlice
    }

    private static func estimatedIntervals<Key: Hashable>(
        from events: [ActivityTimeEvent<Key>],
        maximumGap: TimeInterval,
        minimumSlice: TimeInterval
    ) -> [ActivityInterval<Key>] {
        let groupedEvents = Dictionary(grouping: events, by: \.streamID)

        return groupedEvents.values.flatMap { streamEvents in
            let orderedEvents = streamEvents.sorted { $0.timestamp < $1.timestamp }
            guard !orderedEvents.isEmpty else { return [ActivityInterval<Key>]() }

            return orderedEvents.indices.compactMap { index in
                let current = orderedEvents[index]
                let next = orderedEvents.indices.contains(index + 1) ? orderedEvents[index + 1] : nil
                let slice = estimatedSlice(
                    currentTimestamp: current.timestamp,
                    nextTimestamp: next?.timestamp,
                    maximumGap: maximumGap,
                    minimumSlice: minimumSlice
                )

                guard slice > 0 else { return nil }
                return ActivityInterval(
                    start: current.timestamp,
                    end: current.timestamp.addingTimeInterval(slice),
                    key: current.key
                )
            }
        }
    }

    private static func mergedDuration(_ intervals: [DateInterval]) -> TimeInterval {
        let orderedIntervals = intervals
            .filter { $0.duration > 0 }
            .sorted { $0.start < $1.start }

        guard var current = orderedIntervals.first else { return 0 }
        var total: TimeInterval = 0

        for interval in orderedIntervals.dropFirst() {
            if interval.start <= current.end {
                current = DateInterval(start: current.start, end: max(current.end, interval.end))
            } else {
                total += current.duration
                current = interval
            }
        }

        total += current.duration
        return total
    }
}
