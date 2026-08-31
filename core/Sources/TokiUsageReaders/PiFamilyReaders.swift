import Foundation
import TokiUsageCore

public struct PiReader: TokenReader {
    public static let sourceName = "Pi"

    public let name = Self.sourceName
    private let sessionRootsOverride: [URL]?
    private let readLimits: PiCompatibleReadLimits

    public init(sessionsURLOverride: URL? = nil) {
        sessionRootsOverride = sessionsURLOverride.map { [$0] }
        readLimits = .default
    }

    init(
        sessionRootsOverride: [URL],
        readLimits: PiCompatibleReadLimits = .default) {
        self.sessionRootsOverride = sessionRootsOverride
        self.readLimits = readLimits
    }

    init(
        sessionsURLOverride: URL?,
        readLimits: PiCompatibleReadLimits) {
        sessionRootsOverride = sessionsURLOverride.map { [$0] }
        self.readLimits = readLimits
    }

    public func readUsage(from startDate: Date, to endDate: Date) async throws -> RawTokenUsage {
        let sessionRoots = sessionRootsOverride ?? [LocalUsageReaderPaths().piSessions]
        return try PiCompatibleReader(
            source: .pi,
            sessionRoots: sessionRoots,
            readLimits: readLimits)
            .readUsage(from: startDate, to: endDate)
    }

    static func usage(
        fromJSONLLines lines: [String],
        streamID: String,
        from startDate: Date,
        to endDate: Date) -> RawTokenUsage {
        PiCompatibleReader.usage(
            fromJSONLLines: lines,
            streamID: streamID,
            source: .pi,
            from: startDate,
            to: endDate)
    }
}

public struct OMPReader: TokenReader {
    public static let sourceName = "Oh My Pi"

    public let name = Self.sourceName
    private let sessionRootsOverride: [URL]?

    public init(sessionsURLOverride: URL? = nil) {
        sessionRootsOverride = sessionsURLOverride.map { [$0] }
    }

    init(sessionRootsOverride: [URL]) {
        self.sessionRootsOverride = sessionRootsOverride
    }

    public func readUsage(from startDate: Date, to endDate: Date) async throws -> RawTokenUsage {
        let sessionRoots = sessionRootsOverride ?? LocalUsageReaderPaths().ompSessionRoots
        return try PiCompatibleReader(
            source: .ohMyPi,
            sessionRoots: sessionRoots,
            agentKindForFile: Self.agentKind)
            .readUsage(from: startDate, to: endDate)
    }

    private static func agentKind(for file: URL) -> WorkTimeAgentKind {
        let parentDirectory = file.deletingLastPathComponent()
        let parentSession = parentDirectory.deletingLastPathComponent()
            .appendingPathComponent(parentDirectory.lastPathComponent)
            .appendingPathExtension("jsonl")
        return FileManager.default.fileExists(atPath: parentSession.path) ? .subagent : .main
    }

    static func usage(
        fromJSONLLines lines: [String],
        streamID: String,
        from startDate: Date,
        to endDate: Date) -> RawTokenUsage {
        PiCompatibleReader.usage(
            fromJSONLLines: lines,
            streamID: streamID,
            source: .ohMyPi,
            from: startDate,
            to: endDate)
    }
}

struct SharedPiOMPReader: TokenReader {
    static let sourceName = "Pi / Oh My Pi"

    let name = Self.sourceName
    private let sessionsURL: URL

    init(sessionsURL: URL) {
        self.sessionsURL = sessionsURL
    }

    func readUsage(from startDate: Date, to endDate: Date) async throws -> RawTokenUsage {
        try PiCompatibleReader(source: .piAndOhMyPi, sessionRoots: [sessionsURL])
            .readUsage(from: startDate, to: endDate)
    }
}

public struct KimchiReader: TokenReader {
    public static let sourceName = "Kimchi"

    public let name = Self.sourceName
    private let sessionsURLOverride: URL?

    public init(sessionsURLOverride: URL? = nil) {
        self.sessionsURLOverride = sessionsURLOverride
    }

    public func readUsage(from startDate: Date, to endDate: Date) async throws -> RawTokenUsage {
        let sessionsURL = sessionsURLOverride ?? LocalUsageReaderPaths().kimchiSessions
        return try PiCompatibleReader(source: .kimchi, sessionRoots: [sessionsURL])
            .readUsage(from: startDate, to: endDate)
    }

    static func usage(
        fromJSONLLines lines: [String],
        streamID: String,
        from startDate: Date,
        to endDate: Date) -> RawTokenUsage {
        PiCompatibleReader.usage(
            fromJSONLLines: lines,
            streamID: streamID,
            source: .kimchi,
            from: startDate,
            to: endDate)
    }
}
