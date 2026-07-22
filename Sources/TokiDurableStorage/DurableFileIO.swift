import Foundation

#if os(Linux)
    import Glibc
#else
    import Darwin
#endif

public enum DurableFileIO {
    /// Creates or validates a caller-owned private directory. The final path
    /// must be a real directory rather than a symbolic link.
    public static func preparePrivateDirectory(
        _ directory: URL,
        permissions: Int16 = 0o700) throws {
        do {
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: NSNumber(value: permissions)])
            let values = try directory.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            guard values.isDirectory == true,
                  values.isSymbolicLink != true else {
                throw DurableFileIOError.invalidPrivateDirectory
            }
            try FileManager.default.setAttributes(
                [.posixPermissions: NSNumber(value: permissions)],
                ofItemAtPath: directory.path)
        } catch let error as DurableFileIOError {
            throw error
        } catch {
            throw DurableFileIOError.invalidPrivateDirectory
        }
    }

    /// Atomically replaces a private file. A missing destination directory is
    /// created with `directoryPermissions`; an existing directory's permissions
    /// are never changed because it may be shared or managed by the caller. If
    /// `replacementCommittedDirectorySyncFailed` is thrown, the
    /// destination already contains the replacement even though its directory
    /// durability could not be confirmed.
    public static func writePrivate(
        _ data: Data,
        to url: URL,
        directoryPermissions: Int16 = 0o700,
        filePermissions: Int16 = 0o600) throws {
        try writePrivate(
            data,
            to: url,
            directoryPermissions: directoryPermissions,
            filePermissions: filePermissions,
            directorySynchronizer: synchronizeDirectory)
    }

    /// Reads a caller-owned private regular file without following a symbolic
    /// link. Missing files return `nil`; files that are not user-only or exceed
    /// `maximumByteCount` are rejected before their contents are returned.
    public static func readPrivate(
        from url: URL,
        maximumByteCount: Int) throws -> Data? {
        guard maximumByteCount >= 0, maximumByteCount < Int.max else {
            throw DurableFileIOError.invalidMaximumByteCount
        }

        let descriptor = url.path.withCString { path in
            systemOpen(path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW, 0)
        }
        guard descriptor >= 0 else {
            if errno == ENOENT { return nil }
            throw DurableFileIOError.couldNotOpenPrivateFile
        }
        defer { _ = systemClose(descriptor) }

        var status = stat()
        guard systemFstat(descriptor, &status) == 0,
              status.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG),
              status.st_mode & mode_t(0o077) == 0 else {
            throw DurableFileIOError.invalidPrivateFile
        }
        guard status.st_size >= 0,
              UInt64(status.st_size) <= UInt64(maximumByteCount) else {
            throw DurableFileIOError.privateFileTooLarge
        }

        var data = Data()
        data.reserveCapacity(Int(status.st_size))
        var buffer = [UInt8](repeating: 0, count: min(64 * 1024, maximumByteCount + 1))
        while true {
            let count = buffer.withUnsafeMutableBytes { bytes in
                systemRead(descriptor, bytes.baseAddress, bytes.count)
            }
            if count < 0, errno == EINTR { continue }
            guard count >= 0 else {
                throw DurableFileIOError.couldNotReadPrivateFile
            }
            if count == 0 { break }
            guard data.count <= maximumByteCount - count else {
                throw DurableFileIOError.privateFileTooLarge
            }
            data.append(buffer, count: count)
        }
        return data
    }
}

extension DurableFileIO {
    static func writePrivate(
        _ data: Data,
        to url: URL,
        directoryPermissions: Int16 = 0o700,
        filePermissions: Int16 = 0o600,
        directorySynchronizer: (URL) throws -> Void) throws {
        let directory = url.deletingLastPathComponent()
        var isDirectory: ObjCBool = false
        let directoryExists = FileManager.default.fileExists(
            atPath: directory.path,
            isDirectory: &isDirectory)
        guard !directoryExists || isDirectory.boolValue else {
            throw DurableFileIOError.couldNotOpenDirectory
        }
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: NSNumber(value: directoryPermissions)])
        if !directoryExists {
            try FileManager.default.setAttributes(
                [.posixPermissions: NSNumber(value: directoryPermissions)],
                ofItemAtPath: directory.path)
        }

        let temporaryURL = directory.appendingPathComponent(".\(url.lastPathComponent).\(UUID().uuidString).tmp")
        var descriptor = temporaryURL.path.withCString { path in
            systemOpen(path, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW, mode_t(filePermissions))
        }
        guard descriptor >= 0 else {
            throw DurableFileIOError.couldNotCreateTemporaryFile
        }

        var shouldRemoveTemporaryFile = true
        defer {
            if descriptor >= 0 {
                _ = systemClose(descriptor)
            }
            if shouldRemoveTemporaryFile {
                _ = unlink(temporaryURL)
            }
        }

        guard systemFchmod(descriptor, mode_t(filePermissions)) == 0 else {
            throw DurableFileIOError.couldNotSetPermissions
        }
        try writeAll(data, to: descriptor)
        guard synchronize(descriptor) else {
            throw DurableFileIOError.couldNotSynchronizeFile
        }
        let closeResult = systemClose(descriptor)
        // On Linux, retrying `close` after EINTR can close an unrelated file
        // descriptor that another thread has already reused. Treat this
        // descriptor as consumed regardless of the result.
        descriptor = -1
        guard closeResult == 0 else {
            throw DurableFileIOError.couldNotCloseFile
        }

        let renameResult = temporaryURL.path.withCString { sourcePath in
            url.path.withCString { destinationPath in
                systemRename(sourcePath, destinationPath)
            }
        }
        guard renameResult == 0 else {
            throw DurableFileIOError.couldNotReplaceFile
        }
        shouldRemoveTemporaryFile = false
        do {
            try directorySynchronizer(directory)
        } catch {
            throw DurableFileIOError.replacementCommittedDirectorySyncFailed
        }
    }

    public static func removeIfPresent(_ url: URL) throws {
        try removeIfPresent(url, directorySynchronizer: synchronizeDirectory)
    }

    public static func removeEmptyDirectoryIfPresent(_ url: URL) throws {
        let removeResult = removeEmptyDirectory(url)
        if removeResult != 0 {
            guard errno == ENOENT else {
                throw DurableFileIOError.couldNotRemoveDirectory
            }
            return
        }
        do {
            try synchronizeDirectory(url.deletingLastPathComponent())
        } catch {
            throw DurableFileIOError.removalCommittedDirectorySyncFailed
        }
    }

    static func removeIfPresent(
        _ url: URL,
        directorySynchronizer: (URL) throws -> Void) throws {
        let unlinkResult = unlink(url)
        if unlinkResult != 0 {
            guard errno == ENOENT else {
                throw DurableFileIOError.couldNotRemoveFile
            }
            return
        }
        do {
            try directorySynchronizer(url.deletingLastPathComponent())
        } catch {
            throw DurableFileIOError.removalCommittedDirectorySyncFailed
        }
    }

    public static func synchronizeDirectory(_ directory: URL) throws {
        let descriptor = directory.path.withCString { path in
            systemOpen(path, O_RDONLY | O_CLOEXEC | O_DIRECTORY, 0)
        }
        guard descriptor >= 0 else {
            throw DurableFileIOError.couldNotOpenDirectory
        }
        defer { _ = systemClose(descriptor) }

        guard synchronize(descriptor) else {
            #if os(macOS)
                if errno == EINVAL { return }
            #endif
            throw DurableFileIOError.couldNotSynchronizeDirectory
        }
    }

    private static func writeAll(_ data: Data, to descriptor: Int32) throws {
        try data.withUnsafeBytes { rawBuffer in
            guard var baseAddress = rawBuffer.baseAddress else { return }
            var remaining = rawBuffer.count
            while remaining > 0 {
                let written = systemWrite(descriptor, baseAddress, remaining)
                if written < 0, errno == EINTR { continue }
                guard written > 0 else {
                    throw DurableFileIOError.couldNotWriteFile
                }
                remaining -= written
                baseAddress = baseAddress.advanced(by: written)
            }
        }
    }

    private static func synchronize(_ descriptor: Int32) -> Bool {
        while true {
            if systemFsync(descriptor) == 0 { return true }
            if errno != EINTR { return false }
        }
    }

    private static func unlink(_ url: URL) -> Int32 {
        while true {
            let result = url.path.withCString { path in
                systemUnlink(path)
            }
            if result == 0 || errno != EINTR { return result }
        }
    }

    private static func removeEmptyDirectory(_ url: URL) -> Int32 {
        while true {
            let result = url.path.withCString { path in
                systemRmdir(path)
            }
            if result == 0 || errno != EINTR { return result }
        }
    }
}

public enum DurableFileIOError: LocalizedError {
    case couldNotCreateTemporaryFile
    case couldNotSetPermissions
    case couldNotWriteFile
    case couldNotSynchronizeFile
    case couldNotCloseFile
    case couldNotReplaceFile
    case couldNotOpenDirectory
    case couldNotSynchronizeDirectory
    case invalidPrivateDirectory
    case replacementCommittedDirectorySyncFailed
    case removalCommittedDirectorySyncFailed
    case couldNotRemoveFile
    case couldNotRemoveDirectory
    case invalidMaximumByteCount
    case couldNotOpenPrivateFile
    case invalidPrivateFile
    case privateFileTooLarge
    case couldNotReadPrivateFile

    public var errorDescription: String? {
        switch self {
        case .couldNotCreateTemporaryFile:
            "Could not create a durable temporary file."
        case .couldNotSetPermissions:
            "Could not apply private file permissions."
        case .couldNotWriteFile:
            "Could not write durable file data."
        case .couldNotSynchronizeFile:
            "Could not synchronize durable file data."
        case .couldNotCloseFile:
            "Could not close a durable file."
        case .couldNotReplaceFile:
            "Could not atomically replace a durable file."
        case .couldNotOpenDirectory:
            "Could not open a durable storage directory."
        case .couldNotSynchronizeDirectory:
            "Could not synchronize a durable storage directory."
        case .invalidPrivateDirectory:
            "The private storage directory is invalid."
        case .replacementCommittedDirectorySyncFailed:
            "The file was replaced, but its directory could not be synchronized."
        case .removalCommittedDirectorySyncFailed:
            "The file was removed, but its directory could not be synchronized."
        case .couldNotRemoveFile:
            "Could not durably remove a file."
        case .couldNotRemoveDirectory:
            "Could not durably remove an empty directory."
        case .invalidMaximumByteCount:
            "The private file size limit is invalid."
        case .couldNotOpenPrivateFile:
            "Could not securely open the private file."
        case .invalidPrivateFile:
            "The private file type or permissions are invalid."
        case .privateFileTooLarge:
            "The private file exceeds its size limit."
        case .couldNotReadPrivateFile:
            "Could not read the private file."
        }
    }
}

#if os(Linux)
    private func systemOpen(_ path: UnsafePointer<CChar>, _ flags: Int32, _ mode: mode_t) -> Int32 {
        Glibc.open(path, flags, mode)
    }

    private func systemClose(_ descriptor: Int32) -> Int32 {
        Glibc.close(descriptor)
    }

    private func systemFchmod(_ descriptor: Int32, _ mode: mode_t) -> Int32 {
        Glibc.fchmod(descriptor, mode)
    }

    private func systemFsync(_ descriptor: Int32) -> Int32 {
        Glibc.fsync(descriptor)
    }

    private func systemRename(_ source: UnsafePointer<CChar>, _ destination: UnsafePointer<CChar>) -> Int32 {
        Glibc.rename(source, destination)
    }

    private func systemUnlink(_ path: UnsafePointer<CChar>) -> Int32 {
        Glibc.unlink(path)
    }

    private func systemRmdir(_ path: UnsafePointer<CChar>) -> Int32 {
        Glibc.rmdir(path)
    }

    private func systemWrite(_ descriptor: Int32, _ buffer: UnsafeRawPointer, _ count: Int) -> Int {
        Glibc.write(descriptor, buffer, count)
    }

    private func systemRead(_ descriptor: Int32, _ buffer: UnsafeMutableRawPointer?, _ count: Int) -> Int {
        Glibc.read(descriptor, buffer, count)
    }

    private func systemFstat(_ descriptor: Int32, _ status: UnsafeMutablePointer<stat>) -> Int32 {
        Glibc.fstat(descriptor, status)
    }
#else
    private func systemOpen(_ path: UnsafePointer<CChar>, _ flags: Int32, _ mode: mode_t) -> Int32 {
        Darwin.open(path, flags, mode)
    }

    private func systemClose(_ descriptor: Int32) -> Int32 {
        Darwin.close(descriptor)
    }

    private func systemFchmod(_ descriptor: Int32, _ mode: mode_t) -> Int32 {
        Darwin.fchmod(descriptor, mode)
    }

    private func systemFsync(_ descriptor: Int32) -> Int32 {
        Darwin.fsync(descriptor)
    }

    private func systemRename(_ source: UnsafePointer<CChar>, _ destination: UnsafePointer<CChar>) -> Int32 {
        Darwin.rename(source, destination)
    }

    private func systemUnlink(_ path: UnsafePointer<CChar>) -> Int32 {
        Darwin.unlink(path)
    }

    private func systemRmdir(_ path: UnsafePointer<CChar>) -> Int32 {
        Darwin.rmdir(path)
    }

    private func systemWrite(_ descriptor: Int32, _ buffer: UnsafeRawPointer, _ count: Int) -> Int {
        Darwin.write(descriptor, buffer, count)
    }

    private func systemRead(_ descriptor: Int32, _ buffer: UnsafeMutableRawPointer?, _ count: Int) -> Int {
        Darwin.read(descriptor, buffer, count)
    }

    private func systemFstat(_ descriptor: Int32, _ status: UnsafeMutablePointer<stat>) -> Int32 {
        Darwin.fstat(descriptor, status)
    }
#endif
