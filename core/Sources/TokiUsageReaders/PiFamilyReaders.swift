import Foundation
import TokiUsageCore

public struct PiReader: TokenReader {
    public static let sourceName = "Pi"

    public let name = Self.sourceName
    private let sessionsURLOverride: URL?
    private let readLimits: PiCompatibleReadLimits

    public init(sessionsURLOverride: URL? = nil) {
        self.sessionsURLOverride = sessionsURLOverride
        readLimits = .default
    }

    init(
        sessionsURLOverride: URL?,
        readLimits: PiCompatibleReadLimits) {
        self.sessionsURLOverride = sessionsURLOverride
        self.readLimits = readLimits
    }

    public func readUsage(from startDate: Date, to endDate: Date) async throws -> RawTokenUsage {
        let sessionsURL = sessionsURLOverride ?? LocalUsageReaderPaths().piSessions
        return try PiCompatibleReader(
            source: .pi,
            sessionRoots: [sessionsURL],
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
    private let sessionsURLOverride: URL?

    public init(sessionsURLOverride: URL? = nil) {
        self.sessionsURLOverride = sessionsURLOverride
    }

    public func readUsage(from startDate: Date, to endDate: Date) async throws -> RawTokenUsage {
        let sessionsURL = sessionsURLOverride ?? LocalUsageReaderPaths().ompSessions
        return try PiCompatibleReader(source: .ohMyPi, sessionRoots: [sessionsURL])
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
