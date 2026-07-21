import Foundation
import TokiDurableStorage
import TokiUsageCore

struct AgentPaths {
    let configurationDirectory: URL
    let stateDirectory: URL
    let dataDirectory: URL

    init(environment: [String: String] = ProcessInfo.processInfo.environment, home: URL = homeDir()) {
        configurationDirectory = Self.xdgDirectory(
            environment["XDG_CONFIG_HOME"],
            fallback: home.appendingPathComponent(".config"))
            .appendingPathComponent("toki-agent")
        stateDirectory = Self.xdgDirectory(
            environment["XDG_STATE_HOME"],
            fallback: home.appendingPathComponent(".local/state"))
            .appendingPathComponent("toki-agent")
        dataDirectory = Self.xdgDirectory(
            environment["XDG_DATA_HOME"],
            fallback: home.appendingPathComponent(".local/share"))
            .appendingPathComponent("toki-agent")
    }

    var configurationURL: URL {
        configurationDirectory.appendingPathComponent("config.json")
    }

    var runtimeStateURL: URL {
        stateDirectory.appendingPathComponent("state.json")
    }

    var lockURL: URL {
        stateDirectory.appendingPathComponent("agent.lock")
    }

    var spoolDirectory: URL {
        dataDirectory.appendingPathComponent("spool")
    }

    func prepare() throws {
        try createPrivateDirectory(configurationDirectory)
        try createPrivateDirectory(stateDirectory)
        try createPrivateDirectory(dataDirectory)
        try createPrivateDirectory(spoolDirectory)
    }

    func writePrivate(_ data: Data, to url: URL) throws {
        try DurableFileIO.writePrivate(data, to: url)
    }

    func pathExistsIncludingSymbolicLink(_ url: URL) -> Bool {
        FileManager.default.fileExists(atPath: url.path)
            || (try? FileManager.default.destinationOfSymbolicLink(atPath: url.path)) != nil
    }

    func removeStaleTemporaryFiles() throws {
        try removeStaleTemporaryFiles(in: configurationDirectory) { destinationName in
            destinationName == configurationURL.lastPathComponent
        }
        try removeStaleTemporaryFiles(in: stateDirectory) { destinationName in
            destinationName == runtimeStateURL.lastPathComponent
                || destinationName == "codex-rollout-cache.json"
                || destinationName == "hermes-usage-ledger.json"
        }
        try removeStaleTemporaryFiles(in: spoolDirectory) { destinationName in
            guard destinationName.hasSuffix(".json") else { return false }
            let sequence = destinationName.dropLast(5)
            return sequence.utf8.count == 20 && sequence.utf8.allSatisfy { (48...57).contains($0) }
        }
    }

    private func createPrivateDirectory(_ url: URL) throws {
        try FileManager.default.createDirectory(
            at: url,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: NSNumber(value: 0o700)])
        let values = try url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard values.isDirectory == true,
              values.isSymbolicLink != true else {
            throw AgentPathError.invalidPrivateDirectory
        }
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: 0o700)],
            ofItemAtPath: url.path)
    }

    private func removeStaleTemporaryFiles(
        in directory: URL,
        destinationNameIsAllowed: (String) -> Bool) throws {
        let urls = try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey])
        for url in urls {
            guard let destinationName = durableTemporaryDestinationName(url.lastPathComponent),
                  destinationNameIsAllowed(destinationName) else {
                continue
            }
            let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            guard values.isRegularFile == true,
                  values.isSymbolicLink != true else {
                throw AgentPathError.invalidTemporaryFile
            }
            try DurableFileIO.removeIfPresent(url)
        }
    }

    private static func xdgDirectory(_ value: String?, fallback: URL) -> URL {
        guard let value,
              !value.isEmpty,
              NSString(string: value).isAbsolutePath else {
            return fallback
        }
        return URL(fileURLWithPath: value)
    }
}

private func durableTemporaryDestinationName(_ temporaryName: String) -> String? {
    guard temporaryName.hasPrefix("."), temporaryName.hasSuffix(".tmp") else { return nil }
    let body = temporaryName.dropFirst().dropLast(4)
    guard let separator = body.lastIndex(of: ".") else { return nil }
    let destinationName = body[..<separator]
    let identifier = body[body.index(after: separator)...]
    guard !destinationName.isEmpty,
          UUID(uuidString: String(identifier)) != nil else {
        return nil
    }
    return String(destinationName)
}

private enum AgentPathError: Error {
    case invalidPrivateDirectory
    case invalidTemporaryFile
}
