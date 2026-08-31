import Foundation
import TokiUsageCore

public struct GJCReader: TokenReader {
    public static let sourceName = "GJC"

    public let name = Self.sourceName
    private let sessionsURL: URL

    public init(sessionsURLOverride: URL? = nil) {
        sessionsURL = sessionsURLOverride ?? homeDir().appendingPathComponent(".gjc/agent/sessions")
    }

    public func readUsage(from startDate: Date, to endDate: Date) async throws -> RawTokenUsage {
        PiCompatibleReader(source: .gjc, sessionRoots: [sessionsURL])
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
            source: .gjc,
            from: startDate,
            to: endDate)
    }
}
