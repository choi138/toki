import Foundation

final class AgentDeferredEventRecheck: @unchecked Sendable {
    struct Signature: Encodable {
        let timestamp: Date
        let isEligible: Bool
    }

    private let lock = NSLock()
    private var earliestTimestamp: Date?

    func replaceEarliestTimestamp(_ timestamp: Date?) {
        lock.lock()
        earliestTimestamp = timestamp
        lock.unlock()
    }

    func signature(now: Date) -> Signature? {
        lock.lock()
        defer { lock.unlock() }
        return earliestTimestamp.map { timestamp in
            Signature(timestamp: timestamp, isEligible: now >= timestamp)
        }
    }
}
