import Foundation

/// Exhausting a limit fails the read; partial totals are never returned as complete usage.
public struct OpenCodeReadLimits: Sendable {
    public static let `default` = OpenCodeReadLimits()

    public let maximumRootCount: Int
    public let maximumDatabaseCount: Int
    public let maximumFileCount: Int
    public let maximumEntryCount: Int
    public let maximumRowCount: Int
    public let maximumRecordBytes: Int
    public let maximumTotalBytes: Int
    public let maximumSQLiteSteps: Int

    public init(
        maximumRootCount: Int = 32,
        maximumDatabaseCount: Int = 64,
        maximumFileCount: Int = 100_000,
        maximumEntryCount: Int = 200_000,
        maximumRowCount: Int = 500_000,
        maximumRecordBytes: Int = 4 * 1024 * 1024,
        maximumTotalBytes: Int = 256 * 1024 * 1024,
        maximumSQLiteSteps: Int = 20_000_000) {
        self.maximumRootCount = maximumRootCount
        self.maximumDatabaseCount = maximumDatabaseCount
        self.maximumFileCount = maximumFileCount
        self.maximumEntryCount = maximumEntryCount
        self.maximumRowCount = maximumRowCount
        self.maximumRecordBytes = maximumRecordBytes
        self.maximumTotalBytes = maximumTotalBytes
        self.maximumSQLiteSteps = maximumSQLiteSteps
    }
}

/// Diagnostics intentionally exclude source paths, SQL, and message contents.
public enum OpenCodeReaderError: LocalizedError, Equatable {
    case unsupportedSchema
    case unreadableSource
    case limitExceeded
    case invalidConfiguration
    case invalidDateRange
    case invalidAggregate
    case sourceChangedDuringRead
    case sqlite(operation: String, code: Int32)

    public var errorDescription: String? {
        switch self {
        case .unsupportedSchema: "OpenCode database schema is not supported."
        case .unreadableSource: "An OpenCode usage source could not be read."
        case .limitExceeded: "OpenCode usage exceeded the configured read limits."
        case .invalidConfiguration: "OpenCode read limits or source locations are invalid."
        case .invalidDateRange: "OpenCode usage requires finite date boundaries."
        case .invalidAggregate: "OpenCode usage contains an invalid aggregate."
        case .sourceChangedDuringRead: "An OpenCode database changed while it was being read."
        case let .sqlite(operation, code): "OpenCode SQLite \(operation) failed (code \(code))."
        }
    }
}

final class OpenCodeReadBudget {
    let limits: OpenCodeReadLimits
    private var entries = 0
    private var files = 0
    private var rows = 0
    private var bytes = 0
    private var remainingSQLiteSteps: Int
    private(set) var sqliteLimitExceeded = false

    init(_ limits: OpenCodeReadLimits) throws {
        guard [
            limits.maximumRootCount, limits.maximumDatabaseCount, limits.maximumFileCount,
            limits.maximumEntryCount, limits.maximumRowCount, limits.maximumRecordBytes,
            limits.maximumTotalBytes, limits.maximumSQLiteSteps,
        ].allSatisfy({ $0 > 0 }) else { throw OpenCodeReaderError.invalidConfiguration }
        self.limits = limits
        remainingSQLiteSteps = limits.maximumSQLiteSteps
    }

    func consumeEntry() throws {
        try Task.checkCancellation()
        guard entries < limits.maximumEntryCount else { throw OpenCodeReaderError.limitExceeded }
        entries += 1
    }

    func consumeFile() throws {
        try Task.checkCancellation()
        guard files < limits.maximumFileCount else { throw OpenCodeReaderError.limitExceeded }
        files += 1
    }

    func consumeRow() throws {
        try Task.checkCancellation()
        guard rows < limits.maximumRowCount else { throw OpenCodeReaderError.limitExceeded }
        rows += 1
    }

    func consumeBytes(_ count: Int) throws {
        try Task.checkCancellation()
        guard count >= 0, count <= limits.maximumTotalBytes - bytes else {
            throw OpenCodeReaderError.limitExceeded
        }
        bytes += count
    }

    /// Called on the reading task's thread by SQLite, including during expensive schema/scan work.
    func interruptSQLite() -> Bool {
        if Task<Never, Never>.isCancelled { return true }
        guard remainingSQLiteSteps >= 1000 else {
            sqliteLimitExceeded = true
            return true
        }
        remainingSQLiteSteps -= 1000
        return false
    }
}

func openCodeCanonicalURL(_ url: URL) -> URL {
    let path = url.resolvingSymlinksInPath().standardizedFileURL.path
    // A URL's directory hint must not split the same migration root into two dictionary keys.
    return URL(fileURLWithPath: path, isDirectory: false)
}

func openCodeAttributes(_ url: URL) throws -> [FileAttributeKey: Any]? {
    do {
        return try FileManager.default.attributesOfItem(atPath: url.path)
    } catch {
        let failure = error as NSError
        if failure.domain == NSCocoaErrorDomain,
           [NSFileNoSuchFileError, NSFileReadNoSuchFileError].contains(failure.code) { return nil }
        if failure.domain == NSPOSIXErrorDomain, failure.code == 2 { return nil }
        throw OpenCodeReaderError.unreadableSource
    }
}

func openCodePhysicalIdentity(_ url: URL, attributes: [FileAttributeKey: Any]) -> String {
    if let device = (attributes[.systemNumber] as? NSNumber)?.uint64Value,
       let inode = (attributes[.systemFileNumber] as? NSNumber)?.uint64Value {
        return "\(device):\(inode)"
    }
    return url.path
}

/// Length-prefixing makes these stable, unambiguous identifiers without randomized Hasher values.
/// These identifiers remain local; existing snapshot consumers anonymize exported activity streams.
func openCodeIdentityComponent(_ value: String) -> String {
    "\(value.utf8.count):\(value)"
}

func openCodeRootNamespace(_ root: URL) -> String {
    "opencode:root:\(openCodeIdentityComponent(root.path))"
}

func openCodeDatabaseNamespace(_ url: URL) -> String {
    if url.lastPathComponent == "opencode.db" {
        return openCodeRootNamespace(url.deletingLastPathComponent())
    }
    return "opencode:database:\(openCodeIdentityComponent(url.path))"
}
