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
    defaultDatabaseURL: URL? = nil) throws -> [HermesDatabaseSource] {
    try Task.checkCancellation()
    let canonicalHome = hermesHome.resolvingSymlinksInPath().standardizedFileURL
    var candidates: [(url: URL, isDefault: Bool)] = [
        (defaultDatabaseURL ?? canonicalHome.appendingPathComponent("state.db"), true),
    ]

    if includesProfiles {
        let profilesURL = canonicalHome.appendingPathComponent("profiles", isDirectory: true)
        if try hermesSourceExists(at: profilesURL) {
            guard try profilesURL.resolvingSymlinksInPath()
                .resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true else {
                throw HermesProfileCollectionError.discoveryFailed
            }
            let entries = try hermesProfileEntries(
                in: profilesURL, fileManager: fileManager, maximumCount: maximumProfileCount)
            for entry in entries {
                try Task.checkCancellation()
                // A removed profile can leave a dangling alias. Its registered history remains usable.
                guard try hermesSourceExists(at: entry) else { continue }
                let values: URLResourceValues
                do {
                    values = try entry.resolvingSymlinksInPath().resourceValues(forKeys: [.isDirectoryKey])
                } catch {
                    throw HermesProfileCollectionError.discoveryFailed
                }
                guard values.isDirectory == true else { continue }
                let databaseURL = entry.appendingPathComponent("state.db")
                // Only absence is safe to omit. Let the reader report inaccessible databases
                // alongside successful siblings through its existing per-profile diagnostics.
                guard (try? hermesSourceExists(at: databaseURL)) != false else { continue }
                candidates.append((databaseURL, false))
            }
        }
    }

    let identified = try candidates.map { candidate in
        try Task.checkCancellation()
        let canonicalURL = candidate.url.resolvingSymlinksInPath().standardizedFileURL
        let identity = HermesPhysicalDatabaseIdentity(url: canonicalURL, fileManager: fileManager)
        let ledgerIdentifier = SnapshotCipher.digest(
            "toki.hermes.profile-ledger.v1:\(canonicalURL.path)")
        let source = HermesDatabaseSource(
            databaseURL: canonicalURL,
            isDefault: candidate.isDefault,
            ledgerIdentifier: ledgerIdentifier)
        return (identity: identity, source: source)
    }.sorted { lhs, rhs in
        if lhs.source.isDefault != rhs.source.isDefault { return lhs.source.isDefault }
        let lhsKnown = preferredLedgerIdentifiers.contains(lhs.source.ledgerIdentifier)
        let rhsKnown = preferredLedgerIdentifiers.contains(rhs.source.ledgerIdentifier)
        if lhsKnown != rhsKnown { return lhsKnown }
        return lhs.source.databaseURL.path < rhs.source.databaseURL.path
    }
    let aliases = Dictionary(grouping: identified, by: \.identity)
    var seen = Set<HermesPhysicalDatabaseIdentity>()
    return try identified.compactMap { candidate in
        guard seen.insert(candidate.identity).inserted else { return nil }
        let source = candidate.source
        let databaseURL = try hermesDatabaseReadURL(
            preferred: source.databaseURL,
            aliases: aliases[candidate.identity, default: []].map(\.source.databaseURL),
            fileManager: fileManager)
        // The established ledger owns history and session identity independently of the
        // hardlink path that currently holds SQLite's committed journal state.
        return HermesDatabaseSource(
            databaseURL: databaseURL,
            isDefault: source.isDefault,
            ledgerIdentifier: source.ledgerIdentifier)
    }
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

private struct HermesPhysicalDatabaseIdentity: Hashable {
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
        if let lhsSystem = lhs.systemNumber,
           let lhsFile = lhs.fileNumber,
           let rhsSystem = rhs.systemNumber,
           let rhsFile = rhs.fileNumber {
            return lhsSystem == rhsSystem && lhsFile == rhsFile
        }
        return lhs.canonicalPath == rhs.canonicalPath
    }

    func hash(into hasher: inout Hasher) {
        if let systemNumber, let fileNumber {
            hasher.combine(0)
            hasher.combine(systemNumber)
            hasher.combine(fileNumber)
        } else {
            hasher.combine(1)
            hasher.combine(canonicalPath)
        }
    }
}
