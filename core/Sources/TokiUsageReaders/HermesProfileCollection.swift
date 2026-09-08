import Foundation
import TokiSyncProtocol

#if os(Linux)
    import Glibc
#else
    import Darwin
#endif

struct HermesDatabaseSource: Equatable {
    let databaseURL: URL
    let isDefault: Bool
    let ledgerIdentifier: String
    var inspectionFailed = false
}

/// Keep discovered sources and durable membership bound across the ledger actor handoff.
struct HermesProfileCollection {
    let canonicalHome: URL
    let identifier: String
    let includesDefaultLedger: Bool
    let sources: [HermesDatabaseSource]
}

enum HermesProfileCollectionError: LocalizedError {
    case tooManyProfiles(Int)
    case discoveryFailed
    case invalidMembership
    case incompleteCollection(Int)

    var errorDescription: String? {
        switch self {
        case let .tooManyProfiles(count):
            "Hermes profile discovery exceeded the safe limit (\(count))."
        case .discoveryFailed:
            "Hermes profiles could not be discovered."
        case .invalidMembership:
            "Hermes profile collection history could not be read safely."
        case let .incompleteCollection(count):
            "Hermes collection is incomplete (\(count) profile read errors)."
        }
    }
}

func discoverHermesDatabaseSources(
    hermesHome: URL,
    includesProfiles: Bool,
    fileManager: FileManager = .default,
    maximumProfileCount: Int = 1024,
    preferredLedgerIdentifiers: Set<String> = [],
    hasDefaultLedger: Bool = false,
    ledgerDirectory: URL? = nil,
    defaultDatabaseURL: URL? = nil,
    defaultDatabaseAliases: [URL] = []) throws -> [HermesDatabaseSource] {
    try Task.checkCancellation()
    let canonicalHome = hermesHome.resolvingSymlinksInPath().standardizedFileURL
    var candidates: [(url: URL, isDefault: Bool)] = [
        (defaultDatabaseURL ?? canonicalHome.appendingPathComponent("state.db"), true),
    ]
    candidates.append(contentsOf: defaultDatabaseAliases.map { ($0, true) })
    var failedSources: [HermesDatabaseSource] = []

    if includesProfiles {
        let profiles = try hermesProfileCandidates(
            in: canonicalHome.appendingPathComponent("profiles", isDirectory: true),
            fileManager: fileManager, maximumCount: maximumProfileCount)
        candidates.append(contentsOf: profiles.urls.map { ($0, false) })
        failedSources = profiles.failures
    }

    let identified = try candidates.map { candidate in
        try Task.checkCancellation()
        let canonicalURL = candidate.url.resolvingSymlinksInPath().standardizedFileURL
        let identity = HermesPhysicalDatabaseIdentity(url: canonicalURL, fileManager: fileManager)
        if identity.systemNumber == nil || identity.fileNumber == nil {
            // Path fallback is safe for absent/unreadable sources, which cannot be refreshed.
            // An existing readable file needs physical identity to rule out hidden hardlinks.
            guard (try? hermesSourceExists(at: canonicalURL)) != true else {
                throw HermesProfileCollectionError.discoveryFailed
            }
        }
        let ledgerIdentifier = SnapshotCipher.digest(
            "toki.hermes.profile-ledger.v1:\(canonicalURL.path)")
        // A previously independent profile may now be a symlink. Keep its old
        // path-derived owner visible even though the read URL resolves elsewhere.
        // Candidates already use the canonical home; standardizing again follows
        // the final symlink on Linux and erases the historical alias identity.
        let pathIdentifier = SnapshotCipher.digest(
            "toki.hermes.profile-ledger.v1:\(candidate.url.path)")
        let owners = try Set([ledgerIdentifier, pathIdentifier].filter { identifier in
            if preferredLedgerIdentifiers.contains(identifier) { return true }
            // Explicit legacy-default selection owns only the legacy ledger. Other
            // collections also recognize compatible flat ledgers before membership exists.
            guard !candidate.isDefault || includesProfiles, let ledgerDirectory else { return false }
            return try hermesSourceExists(at: ledgerDirectory.appendingPathComponent(
                "hermes-usage-ledger-profile-\(identifier).json"))
        })
        let source = HermesDatabaseSource(
            databaseURL: canonicalURL,
            isDefault: candidate.isDefault,
            ledgerIdentifier: ledgerIdentifier)
        return (identity: identity, source: source, owners: owners)
    }.sorted { lhs, rhs in
        if lhs.source.isDefault != rhs.source.isDefault { return lhs.source.isDefault }
        let lhsKnown = preferredLedgerIdentifiers.contains(lhs.source.ledgerIdentifier)
        let rhsKnown = preferredLedgerIdentifiers.contains(rhs.source.ledgerIdentifier)
        if lhsKnown != rhsKnown { return lhsKnown }
        return lhs.source.databaseURL.path < rhs.source.databaseURL.path
    }
    let aliases = Dictionary(grouping: identified, by: \.identity)
    var seen = Set<HermesPhysicalDatabaseIdentity>()
    let sources: [HermesDatabaseSource] = try identified.compactMap { candidate in
        guard seen.insert(candidate.identity).inserted else { return nil }
        let source = candidate.source
        let group = aliases[candidate.identity, default: []]
        let owners = Set(group.flatMap(\.owners))
        let ownsDefault = hasDefaultLedger && group.contains { $0.source.isDefault }
        guard owners.count + (ownsDefault ? 1 : 0) <= 1 else {
            throw HermesProfileCollectionError.invalidMembership
        }
        let databaseURL = try hermesDatabaseReadURL(
            preferred: source.databaseURL,
            aliases: aliases[candidate.identity, default: []].map(\.source.databaseURL),
            fileManager: fileManager)
        // The established ledger owns history and session identity independently of the
        // hardlink path that currently holds SQLite's committed journal state.
        return HermesDatabaseSource(
            databaseURL: databaseURL,
            isDefault: owners.isEmpty ? source.isDefault : false,
            ledgerIdentifier: owners.first ?? source.ledgerIdentifier)
    }
    return sources + failedSources
}

private func hermesProfileCandidates(
    in profilesURL: URL,
    fileManager: FileManager,
    maximumCount: Int) throws -> (urls: [URL], failures: [HermesDatabaseSource]) {
    guard try hermesSourceExists(at: profilesURL) else { return ([], []) }
    guard try profilesURL.resolvingSymlinksInPath()
        .resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true else {
        throw HermesProfileCollectionError.discoveryFailed
    }
    let entries = try hermesProfileEntries(in: profilesURL, fileManager: fileManager, maximumCount: maximumCount)
    var urls: [URL] = []
    var failures: [HermesDatabaseSource] = []
    for entry in entries {
        try Task.checkCancellation()
        do {
            // A removed profile can leave a dangling alias. Its registered history remains usable.
            guard try hermesSourceExists(at: entry) else { continue }
            let values = try entry.resolvingSymlinksInPath().resourceValues(forKeys: [.isDirectoryKey])
            guard values.isDirectory == true else { continue }
            let databaseURL = entry.appendingPathComponent("state.db")
            guard (try? hermesSourceExists(at: databaseURL)) != false else { continue }
            urls.append(databaseURL)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            // Preserve failed inspections so healthy siblings remain usable without
            // allowing coverage or snapshot export to claim completeness.
            let databaseURL = entry.appendingPathComponent("state.db").standardizedFileURL
            failures.append(HermesDatabaseSource(
                databaseURL: databaseURL, isDefault: false,
                ledgerIdentifier: SnapshotCipher.digest("toki.hermes.profile-ledger.v1:\(databaseURL.path)"),
                inspectionFailed: true))
        }
    }
    return (urls, failures)
}

func hermesDatabasesShareIdentity(_ selected: URL, _ legacy: URL) throws -> Bool {
    let legacy = legacy.resolvingSymlinksInPath().standardizedFileURL
    // Path fallback retains removed default history without assigning it to an unrelated source.
    if selected == legacy { return true }
    guard try hermesSourceExists(at: selected), try hermesSourceExists(at: legacy) else { return false }
    let selectedIdentity = HermesPhysicalDatabaseIdentity(url: selected, fileManager: .default)
    let legacyIdentity = HermesPhysicalDatabaseIdentity(url: legacy, fileManager: .default)
    guard selectedIdentity.systemNumber != nil, selectedIdentity.fileNumber != nil,
          legacyIdentity.systemNumber != nil, legacyIdentity.fileNumber != nil else {
        throw HermesProfileCollectionError.discoveryFailed
    }
    return selectedIdentity == legacyIdentity
}

private func hermesDatabaseReadURL(preferred: URL, aliases: [URL], fileManager: FileManager) throws -> URL {
    let preferred = preferred.resolvingSymlinksInPath().standardizedFileURL
    let canonicalURLs = Set(aliases.map { $0.resolvingSymlinksInPath().standardizedFileURL })
    guard canonicalURLs.count > 1 else { return preferred }
    let journalURLs = try canonicalURLs.filter { url in
        try ["-wal", "-journal"].contains { suffix in
            let sidecar = URL(fileURLWithPath: url.path + suffix)
            guard try hermesSourceExists(at: sidecar) else { return false }
            guard let attributes = try? fileManager.attributesOfItem(atPath: sidecar.path),
                  let size = attributes[.size] as? NSNumber else {
                throw HermesProfileCollectionError.discoveryFailed
            }
            return size.uint64Value > 0
        }
    }
    // Multiple independent journals cannot be reconciled by selecting the first alias.
    guard journalURLs.count <= 1 else { throw HermesProfileCollectionError.discoveryFailed }
    return journalURLs.first ?? preferred
}

func hermesSourceExists(at url: URL) throws -> Bool {
    var metadata = stat()
    if url.path.withCString({ stat($0, &metadata) }) == 0 { return true }
    guard errno == ENOENT else { throw HermesProfileCollectionError.discoveryFailed }
    return false
}

private func hermesProfileEntries(
    in directory: URL,
    fileManager: FileManager,
    maximumCount: Int) throws -> [URL] {
    var inspectionFailed = false
    guard let enumerator = fileManager.enumerator(
        at: directory,
        includingPropertiesForKeys: [.isDirectoryKey],
        options: [.skipsHiddenFiles, .skipsSubdirectoryDescendants],
        errorHandler: { _, _ in
            inspectionFailed = true
            return false
        }) else { throw HermesProfileCollectionError.discoveryFailed }
    var entries: [URL] = []
    for case let entry as URL in enumerator {
        try Task.checkCancellation()
        guard entries.count < maximumCount else {
            throw HermesProfileCollectionError.tooManyProfiles(entries.count + 1)
        }
        entries.append(entry)
    }
    guard !inspectionFailed else { throw HermesProfileCollectionError.discoveryFailed }
    return entries.sorted { $0.path < $1.path }
}

struct HermesPhysicalDatabaseIdentity: Hashable {
    let systemNumber: UInt64?
    let fileNumber: UInt64?
    let canonicalPath: String

    init(url: URL, fileManager: FileManager) {
        let attributes = try? fileManager.attributesOfItem(atPath: url.path)
        systemNumber = (attributes?[.systemNumber] as? NSNumber)?.uint64Value
        fileNumber = (attributes?[.systemFileNumber] as? NSNumber)?.uint64Value
        canonicalPath = url.path
    }

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.key == rhs.key
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(key)
    }

    private var key: Key {
        if let systemNumber, let fileNumber { return .inode(systemNumber, fileNumber) }
        return .path(canonicalPath)
    }

    private enum Key: Hashable {
        case inode(UInt64, UInt64)
        case path(String)
    }
}
