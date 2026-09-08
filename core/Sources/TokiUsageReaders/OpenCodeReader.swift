import Foundation
import TokiUsageCore

/// Reads OpenCode's default/channel SQLite databases and legacy storage/message JSON.
/// Sources are rediscovered on each call; no source writes or migration-complete cache are used.
public struct OpenCodeReader: TokenReader {
    public let name = "OpenCode"
    private let dataRoots: [URL]
    private let databaseURLs: [URL]
    private let limits: OpenCodeReadLimits

    /// Compatibility API: an override selects that database plus adjacent legacy messages.
    /// A nil override discovers the current home/XDG root and any explicit OPENCODE_DB path.
    public init(dbPathOverride: String? = nil) {
        if let dbPathOverride {
            self.init(databaseURLs: [URL(fileURLWithPath: dbPathOverride)])
        } else {
            self.init(homeDirectory: homeDir(), environment: ProcessInfo.processInfo.environment)
        }
    }

    /// Roots are OpenCode data directories, not home directories. Only allowlisted database
    /// names are discovered there. Explicit files are schema-checked and may have custom names.
    public init(dataRoots: [URL], databaseURLs: [URL] = [], limits: OpenCodeReadLimits = .default) {
        self.dataRoots = dataRoots
        self.databaseURLs = databaseURLs
        self.limits = limits
    }

    public init(databaseURLs: [URL], limits: OpenCodeReadLimits = .default) {
        self.init(dataRoots: [], databaseURLs: databaseURLs, limits: limits)
    }

    /// Inject an empty environment for an isolated home. No config, credential or session
    /// files are consulted to resolve roots. Relative environment overrides are ignored.
    public init(
        homeDirectory: URL,
        environment: [String: String] = [:],
        limits: OpenCodeReadLimits = .default) {
        let dataHome = Self.absolutePath(environment["XDG_DATA_HOME"])
            ?? homeDirectory.appendingPathComponent(".local/share")
        self.init(
            dataRoots: [dataHome.appendingPathComponent("opencode")],
            databaseURLs: Self.absolutePath(environment["OPENCODE_DB"]).map { [$0] } ?? [],
            limits: limits)
    }

    public func sourceLocations() throws -> OpenCodeSourceLocations {
        try OpenCodeDiscovery.collect(
            dataRoots: dataRoots, databaseURLs: databaseURLs, budget: OpenCodeReadBudget(limits)).locations
    }

    public func readUsage(from startDate: Date, to endDate: Date) async throws -> RawTokenUsage {
        try Task.checkCancellation()
        guard startDate.timeIntervalSince1970.isFinite, endDate.timeIntervalSince1970.isFinite else {
            throw OpenCodeReaderError.invalidDateRange
        }
        guard startDate < endDate else { return RawTokenUsage() }
        let budget = try OpenCodeReadBudget(limits)
        let discovery = try OpenCodeDiscovery.collect(dataRoots: dataRoots, databaseURLs: databaseURLs, budget: budget)
        var messages: [OpenCodeMessage] = []
        var databaseIDs: [URL: Set<OpenCodeMessageIdentity>] = [:]
        var sessionNamespaces: [URL: [String: Set<String>]] = [:]
        for store in discovery.stores {
            try Task.checkCancellation()
            let databaseMessages = try OpenCodeSQLiteReader(url: store.url, budget: budget).read(store: store)
            messages.append(contentsOf: databaseMessages)
            for message in databaseMessages {
                try Task.checkCancellation()
                for root in store.migrationRoots {
                    if let identity = message.migrationIdentity { databaseIDs[root, default: []].insert(identity) }
                    sessionNamespaces[root, default: [:]][message.sessionID, default: []].insert(message.namespace)
                }
            }
        }
        try messages.append(contentsOf: legacyMessages(
            roots: discovery.legacyRoots, databaseIDs: databaseIDs,
            sessionNamespaces: sessionNamespaces, budget: budget))
        // Dedup precedes date filtering: a stale JSON timestamp cannot resurrect a
        // database message whose authoritative timestamp moved out of this window.
        messages.sort {
            if $0.timestamp != $1.timestamp { return $0.timestamp < $1.timestamp }
            if $0.namespace != $1.namespace { return $0.namespace < $1.namespace }
            if $0.sessionID != $1.sessionID { return $0.sessionID < $1.sessionID }
            return $0.identity.message < $1.identity.message
        }
        var usage = RawTokenUsage()
        for message in messages {
            try Task.checkCancellation()
            guard message.timestamp >= startDate, message.timestamp < endDate else { continue }
            try message.accumulate(into: &usage)
        }
        usage.recomputeMergedActiveEstimate(source: name, clippingEndDate: endDate)
        try Task.checkCancellation()
        return usage
    }

    private func legacyMessages(
        roots: [URL],
        databaseIDs: [URL: Set<OpenCodeMessageIdentity>],
        sessionNamespaces: [URL: [String: Set<String>]],
        budget: OpenCodeReadBudget) throws -> [OpenCodeMessage] {
        var messages: [OpenCodeMessage] = []
        for root in roots {
            var legacyIDs: Set<OpenCodeMessageIdentity> = []
            for file in try OpenCodeLegacyReader.files(in: root, budget: budget) {
                guard var message = try OpenCodeLegacyReader.read(file, root: root, budget: budget) else { continue }
                if let identity = message.migrationIdentity, databaseIDs[root]?.contains(identity) == true { continue }
                guard legacyIDs.insert(message.identity).inserted else { continue }
                // JSON-only turns in a partially migrated session keep the database's
                // stream when exactly one store claims it. Independent channel streams
                // remain distinct when session IDs conflict.
                if let namespaces = sessionNamespaces[root]?[message.sessionID], namespaces.count == 1,
                   let namespace = namespaces.first { message.namespace = namespace }
                messages.append(message)
            }
        }
        return messages
    }

    private static func absolutePath(_ value: String?) -> URL? {
        guard let value, value.hasPrefix("/"), !value.contains("\0") else { return nil }
        // Preserve filename bytes and the selected alias. Foundation on Linux may
        // resolve a symlink during standardization; discovery must resolve it afresh.
        return URL(fileURLWithPath: value)
    }
}
