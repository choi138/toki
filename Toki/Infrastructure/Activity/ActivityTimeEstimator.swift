import Foundation

enum WorkTimeAgentKind: Hashable {
    case main
    case subagent
}

struct ActivityTimeEvent<Key: Hashable> {
    let streamID: String
    let timestamp: Date
    let key: Key?
    let agentKind: WorkTimeAgentKind

    init(
        streamID: String,
        timestamp: Date,
        key: Key?,
        agentKind: WorkTimeAgentKind = .main) {
        self.streamID = streamID
        self.timestamp = timestamp
        self.key = key
        self.agentKind = agentKind
    }
}

struct ActivityTimeEstimate<Key: Hashable> {
    let totalSeconds: TimeInterval
    let mainAgentSeconds: TimeInterval
    let subagentSeconds: TimeInterval
    let wallClockSeconds: TimeInterval
    let activeStreamCount: Int
    let maxConcurrentStreams: Int
    let secondsByKey: [Key: TimeInterval]

    static var zero: Self {
        ActivityTimeEstimate(
            totalSeconds: 0,
            mainAgentSeconds: 0,
            subagentSeconds: 0,
            wallClockSeconds: 0,
            activeStreamCount: 0,
            maxConcurrentStreams: 0,
            secondsByKey: [:])
    }
}

private struct ActivityInterval<Key: Hashable> {
    let streamID: String
    let start: Date
    let end: Date
    let key: Key?
    let agentKind: WorkTimeAgentKind
}

enum ActivityTimeEstimator {
    static let defaultMaximumGap: TimeInterval = 300
    static let defaultMinimumSlice: TimeInterval = 30

    static func estimate<Key: Hashable>(
        events: [ActivityTimeEvent<Key>],
        maximumGap: TimeInterval = defaultMaximumGap,
        minimumSlice: TimeInterval = defaultMinimumSlice,
        clippingEndDate: Date? = nil) -> ActivityTimeEstimate<Key> {
        let intervals = estimatedIntervals(
            from: events,
            maximumGap: maximumGap,
            minimumSlice: minimumSlice,
            clippingEndDate: clippingEndDate)
        guard !intervals.isEmpty else { return .zero }

        let totalSeconds = summedDurationByStream(intervals)
        let secondsByAgentKind = Dictionary(
            grouping: intervals,
            by: \.agentKind).mapValues { intervalsForKind in
            summedDurationByStream(intervalsForKind)
        }
        let mergedStreamIntervals = mergedDateIntervalsByStream(intervals)
        let wallClockSeconds = mergedDuration(mergedStreamIntervals)
        let activeStreamCount = Set(intervals.map(\.streamID)).count
        let maxConcurrentStreams = maximumConcurrentStreams(mergedStreamIntervals)
        let secondsByKey = Dictionary(
            grouping: intervals.compactMap { interval -> (Key, ActivityInterval<Key>)? in
                guard let key = interval.key else { return nil }
                return (key, interval)
            },
            by: \.0).reduce(into: [Key: TimeInterval]()) { result, item in
                let (key, intervalsForKey) = item
                result[key] = summedDurationByStream(intervalsForKey.map(\.1))
            }

        return ActivityTimeEstimate(
            totalSeconds: totalSeconds,
            mainAgentSeconds: secondsByAgentKind[.main, default: 0],
            subagentSeconds: secondsByAgentKind[.subagent, default: 0],
            wallClockSeconds: wallClockSeconds,
            activeStreamCount: activeStreamCount,
            maxConcurrentStreams: maxConcurrentStreams,
            secondsByKey: secondsByKey)
    }

    private static func estimatedSlice(
        currentTimestamp: Date,
        nextTimestamp: Date?,
        maximumGap: TimeInterval,
        minimumSlice: TimeInterval,
        clippingEndDate: Date?) -> TimeInterval {
        if let clippingEndDate, currentTimestamp >= clippingEndDate {
            return 0
        }

        guard let nextTimestamp else { return minimumSlice }

        let gap = nextTimestamp.timeIntervalSince(currentTimestamp)
        guard gap > 0 else { return 0 }
        return gap <= maximumGap ? gap : minimumSlice
    }

    private static func estimatedIntervals<Key: Hashable>(
        from events: [ActivityTimeEvent<Key>],
        maximumGap: TimeInterval,
        minimumSlice: TimeInterval,
        clippingEndDate: Date?) -> [ActivityInterval<Key>] {
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
                    minimumSlice: minimumSlice,
                    clippingEndDate: clippingEndDate)

                let unclampedEnd = current.timestamp.addingTimeInterval(slice)
                let intervalEnd = clippingEndDate.map { min(unclampedEnd, $0) } ?? unclampedEnd
                guard slice > 0, intervalEnd > current.timestamp else { return nil }
                return ActivityInterval(
                    streamID: current.streamID,
                    start: current.timestamp,
                    end: intervalEnd,
                    key: current.key,
                    agentKind: current.agentKind)
            }
        }
    }

    private static func summedDurationByStream(_ intervals: [ActivityInterval<some Hashable>]) -> TimeInterval {
        Dictionary(grouping: intervals, by: \.streamID).values.reduce(0) { partial, streamIntervals in
            partial + mergedDuration(streamIntervals.map { DateInterval(start: $0.start, end: $0.end) })
        }
    }

    private static func mergedDateIntervalsByStream(
        _ intervals: [ActivityInterval<some Hashable>]) -> [DateInterval] {
        Dictionary(grouping: intervals, by: \.streamID).values.flatMap { streamIntervals in
            mergedIntervals(streamIntervals.map { DateInterval(start: $0.start, end: $0.end) })
        }
    }

    private static func mergedDuration(_ intervals: [DateInterval]) -> TimeInterval {
        mergedIntervals(intervals).reduce(0) { $0 + $1.duration }
    }

    private static func mergedIntervals(_ intervals: [DateInterval]) -> [DateInterval] {
        let orderedIntervals = intervals
            .filter { $0.duration > 0 }
            .sorted { $0.start < $1.start }

        guard var current = orderedIntervals.first else { return [] }
        var result: [DateInterval] = []

        for interval in orderedIntervals.dropFirst() {
            if interval.start <= current.end {
                current = DateInterval(start: current.start, end: max(current.end, interval.end))
            } else {
                result.append(current)
                current = interval
            }
        }

        result.append(current)
        return result
    }

    private static func maximumConcurrentStreams(_ intervals: [DateInterval]) -> Int {
        let points = intervals.flatMap { interval in
            [
                (date: interval.start, delta: 1),
                (date: interval.end, delta: -1),
            ]
        }
        .sorted { lhs, rhs in
            if lhs.date == rhs.date { return lhs.delta < rhs.delta }
            return lhs.date < rhs.date
        }

        var current = 0
        var maximum = 0
        for point in points {
            current += point.delta
            maximum = max(maximum, current)
        }
        return maximum
    }
}
