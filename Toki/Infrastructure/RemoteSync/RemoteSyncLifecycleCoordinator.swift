import Foundation

final class RemoteSyncLifecycleCoordinator: @unchecked Sendable {
    struct ReadTicket: Equatable {
        fileprivate let generation: UInt64
    }

    static let shared = RemoteSyncLifecycleCoordinator()

    private let lock = NSLock()
    private var generation: UInt64 = 0

    func beginRead() -> ReadTicket {
        lock.lock()
        defer { lock.unlock() }
        return ReadTicket(generation: generation)
    }

    func validate(_ ticket: ReadTicket) throws {
        lock.lock()
        defer { lock.unlock() }
        guard generation == ticket.generation else {
            throw RemoteSyncLifecycleError.stateChanged
        }
    }

    func invalidateReadTickets() {
        lock.lock()
        defer { lock.unlock() }
        generation &+= 1
    }
}

enum RemoteSyncLifecycleError: LocalizedError {
    case stateChanged

    var errorDescription: String? {
        "Remote sync settings changed during refresh. Refresh again."
    }
}
