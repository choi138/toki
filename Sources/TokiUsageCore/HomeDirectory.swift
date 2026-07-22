import Foundation

public func homeDir() -> URL {
    FileManager.default.homeDirectoryForCurrentUser
}
