import Foundation

#if os(Linux)
    import Glibc
#else
    import Darwin
#endif

final class AgentProcessLock {
    private let descriptor: Int32

    private init(descriptor: Int32) {
        self.descriptor = descriptor
    }

    deinit {
        _ = flock(descriptor, LOCK_UN)
        _ = close(descriptor)
    }

    static func acquire(paths: AgentPaths) throws -> AgentProcessLock {
        try paths.prepare()
        let descriptor = paths.lockURL.path.withCString { path in
            open(path, O_CREAT | O_RDWR | O_CLOEXEC | O_NOFOLLOW, mode_t(0o600))
        }
        guard descriptor >= 0 else {
            throw AgentProcessLockError.unavailable
        }
        var fileStatus = stat()
        guard fstat(descriptor, &fileStatus) == 0,
              fileStatus.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG) else {
            _ = close(descriptor)
            throw AgentProcessLockError.unavailable
        }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            let lockError = errno
            _ = close(descriptor)
            if lockError == EWOULDBLOCK || lockError == EAGAIN {
                throw AgentProcessLockError.alreadyRunning
            }
            throw AgentProcessLockError.unavailable
        }
        guard fchmod(descriptor, mode_t(0o600)) == 0 else {
            _ = flock(descriptor, LOCK_UN)
            _ = close(descriptor)
            throw AgentProcessLockError.unavailable
        }
        do {
            try paths.removeStaleTemporaryFiles()
        } catch {
            _ = flock(descriptor, LOCK_UN)
            _ = close(descriptor)
            throw AgentProcessLockError.unavailable
        }
        return AgentProcessLock(descriptor: descriptor)
    }
}

enum AgentProcessLockError: LocalizedError {
    case alreadyRunning
    case unavailable

    var errorDescription: String? {
        switch self {
        case .alreadyRunning:
            "Another Toki Agent operation is already running."
        case .unavailable:
            "The Toki Agent process lock could not be acquired."
        }
    }
}
