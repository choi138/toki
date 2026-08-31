import Foundation
import TokiUsageCore

#if os(Linux)
    import Glibc
#else
    import Darwin
#endif

enum AgentSenpiMountPreparer {
    static func prepare(home: URL = homeDir()) throws {
        let homeDescriptor = try openRequiredDirectory(at: home)
        defer { _ = close(homeDescriptor) }

        guard let omoDescriptor = try openOptionalDirectory(
            named: ".omo",
            relativeTo: homeDescriptor) else {
            return
        }
        defer { _ = close(omoDescriptor) }

        guard let taskDescriptor = try openOptionalDirectory(
            named: "senpi-task",
            relativeTo: omoDescriptor) else {
            return
        }
        defer { _ = close(taskDescriptor) }

        try createPrivateDirectory(named: "children", relativeTo: taskDescriptor)
        try createPrivateDirectory(named: "sessions", relativeTo: taskDescriptor)
    }

    private static func openRequiredDirectory(at url: URL) throws -> Int32 {
        let descriptor = url.path.withCString { path in
            open(path, O_RDONLY | O_CLOEXEC | O_DIRECTORY | O_NOFOLLOW)
        }
        guard descriptor >= 0 else {
            throw AgentCommandError.unsafeSenpiMountPaths
        }
        do {
            try validateOwnedDirectory(descriptor)
            return descriptor
        } catch {
            _ = close(descriptor)
            throw error
        }
    }

    private static func openOptionalDirectory(
        named name: String,
        relativeTo parentDescriptor: Int32) throws -> Int32? {
        let descriptor = name.withCString { path in
            openat(parentDescriptor, path, O_RDONLY | O_CLOEXEC | O_DIRECTORY | O_NOFOLLOW)
        }
        guard descriptor >= 0 else {
            if errno == ENOENT { return nil }
            throw AgentCommandError.unsafeSenpiMountPaths
        }
        do {
            try validateOwnedDirectory(descriptor)
            return descriptor
        } catch {
            _ = close(descriptor)
            throw error
        }
    }

    private static func createPrivateDirectory(
        named name: String,
        relativeTo parentDescriptor: Int32) throws {
        let createResult = name.withCString { path in
            mkdirat(parentDescriptor, path, mode_t(0o700))
        }
        guard createResult == 0 || errno == EEXIST else {
            throw AgentCommandError.unsafeSenpiMountPaths
        }
        guard let descriptor = try openOptionalDirectory(
            named: name,
            relativeTo: parentDescriptor) else {
            throw AgentCommandError.unsafeSenpiMountPaths
        }
        _ = close(descriptor)
    }

    private static func validateOwnedDirectory(_ descriptor: Int32) throws {
        var status = stat()
        guard fstat(descriptor, &status) == 0,
              status.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR),
              status.st_uid == geteuid() else {
            throw AgentCommandError.unsafeSenpiMountPaths
        }
    }
}
