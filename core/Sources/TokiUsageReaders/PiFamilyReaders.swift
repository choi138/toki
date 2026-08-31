import Foundation
import TokiUsageCore

public struct SenpiReader: TokenReader {
    public static let sourceName = "Senpi"

    public let name = Self.sourceName
    private let sessionRoots: [URL]

    public init(sessionRootsOverride: [URL]? = nil) {
        sessionRoots = sessionRootsOverride ?? [
            homeDir().appendingPathComponent(".omo/agent/sessions"),
            homeDir().appendingPathComponent(".senpi/agent/sessions"),
        ]
    }

    public func readUsage(from startDate: Date, to endDate: Date) async throws -> RawTokenUsage {
        PiCompatibleReader(source: .senpi, sessionRoots: sessionRoots)
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
            source: .senpi,
            from: startDate,
            to: endDate)
    }
}

public struct PiReader: TokenReader {
    public static let sourceName = "Pi"

    public let name = Self.sourceName
    private let sessionRoots: [URL]

    public init(sessionsURLOverride: URL? = nil) {
        sessionRoots = [sessionsURLOverride ?? homeDir().appendingPathComponent(".pi/agent/sessions")]
    }

    init(sessionRootsOverride: [URL]) {
        sessionRoots = sessionRootsOverride
    }

    public func readUsage(from startDate: Date, to endDate: Date) async throws -> RawTokenUsage {
        PiCompatibleReader(source: .pi, sessionRoots: sessionRoots)
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
    private let sessionsURL: URL

    public init(sessionsURLOverride: URL? = nil) {
        sessionsURL = sessionsURLOverride ?? homeDir().appendingPathComponent(".omp/agent/sessions")
    }

    public func readUsage(from startDate: Date, to endDate: Date) async throws -> RawTokenUsage {
        PiCompatibleReader(source: .ohMyPi, sessionRoots: [sessionsURL])
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

public struct KimchiReader: TokenReader {
    public static let sourceName = "Kimchi"

    public let name = Self.sourceName
    private let sessionsURL: URL

    public init(sessionsURLOverride: URL? = nil) {
        sessionsURL = sessionsURLOverride
            ?? homeDir().appendingPathComponent(".config/kimchi/harness/sessions")
    }

    public func readUsage(from startDate: Date, to endDate: Date) async throws -> RawTokenUsage {
        PiCompatibleReader(source: .kimchi, sessionRoots: [sessionsURL])
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
