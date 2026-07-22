import Foundation

#if os(Linux)
    import Glibc
#else
    import Darwin
#endif

final class HubStorageLock {
    private let descriptor: Int32

    private init(descriptor: Int32) {
        self.descriptor = descriptor
    }

    deinit {
        _ = flock(descriptor, LOCK_UN)
        _ = close(descriptor)
    }

    static func acquire(directory: URL) throws -> HubStorageLock {
        let lockURL = directory.appendingPathComponent(".hub.lock")
        let descriptor = lockURL.path.withCString { path in
            open(path, O_CREAT | O_RDWR | O_CLOEXEC | O_NOFOLLOW, mode_t(0o600))
        }
        guard descriptor >= 0 else {
            throw HubStorageLockError.unavailable
        }
        var fileStatus = stat()
        guard fstat(descriptor, &fileStatus) == 0,
              fileStatus.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG) else {
            _ = close(descriptor)
            throw HubStorageLockError.unavailable
        }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            let lockError = errno
            _ = close(descriptor)
            if lockError == EWOULDBLOCK || lockError == EAGAIN {
                throw HubStorageLockError.alreadyRunning
            }
            throw HubStorageLockError.unavailable
        }
        guard fchmod(descriptor, mode_t(0o600)) == 0 else {
            _ = flock(descriptor, LOCK_UN)
            _ = close(descriptor)
            throw HubStorageLockError.unavailable
        }
        return HubStorageLock(descriptor: descriptor)
    }
}

enum HubStorageLockError: LocalizedError {
    case alreadyRunning
    case unavailable

    var errorDescription: String? {
        switch self {
        case .alreadyRunning:
            "Another Toki Hub process already owns this storage directory."
        case .unavailable:
            "The Toki Hub storage lock could not be acquired."
        }
    }
}
