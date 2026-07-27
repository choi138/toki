import Foundation

final class RemoteSyncLifecycleCoordinator: @unchecked Sendable {
    struct ReadTicket: Equatable {
        fileprivate let generation: UInt64
    }

    static let shared = RemoteSyncLifecycleCoordinator()

    private let lock = NSRecursiveLock()
    private var generation: UInt64 = 0

    func beginRead() -> ReadTicket {
        lock.lock()
        defer { lock.unlock() }
        return ReadTicket(generation: generation)
    }

    func validate(_ ticket: ReadTicket) throws {
        lock.lock()
        defer { lock.unlock() }
        try validateLocked(ticket)
    }

    func withReadCommit<Value>(
        _ ticket: ReadTicket,
        _ commit: () throws -> Value) throws -> Value {
        lock.lock()
        defer { lock.unlock() }
        try validateLocked(ticket)
        return try commit()
    }

    func invalidateReadTickets() {
        lock.lock()
        defer { lock.unlock() }
        generation &+= 1
    }

    func withInvalidatingMutation<Value>(_ mutation: () throws -> Value) rethrows -> Value {
        lock.lock()
        defer { lock.unlock() }
        generation &+= 1
        return try mutation()
    }

    private func validateLocked(_ ticket: ReadTicket) throws {
        guard generation == ticket.generation else {
            throw RemoteSyncLifecycleError.stateChanged
        }
    }
}

enum RemoteSyncLifecycleError: LocalizedError {
    case stateChanged

    var errorDescription: String? {
        "Remote sync settings changed during refresh. Refresh again."
    }
}
