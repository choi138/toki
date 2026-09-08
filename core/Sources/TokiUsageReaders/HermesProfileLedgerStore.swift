import Foundation
import TokiDurableStorage
import TokiSyncProtocol

struct HermesProfileLedger {
    // Nil is reserved for the unchanged default legacy ledger identity.
    let profileIdentifier: String?
    let ledger: HermesUsageLedger

    var failureIdentifier: String {
        profileIdentifier ?? "default"
    }

    func events(from start: Date, to end: Date) async throws -> [HermesUsageLedgerEvent] {
        let events = try await ledger.events(from: start, to: end)
        guard let profileIdentifier else { return events }
        // Namespace only the exported projection. Never rewrite stored identifiers or baselines.
        return try events.map { event in
            try Task.checkCancellation()
            return HermesUsageLedgerEvent(
                sessionIdentifier: SnapshotCipher.digest(
                    "toki.hermes.profile-session.v1:\(profileIdentifier):\(event.sessionIdentifier)"),
                timestamp: event.timestamp,
                model: event.model,
                counters: event.counters,
                cost: event.cost,
                projectName: event.projectName,
                attributionQuality: event.attributionQuality)
        }
    }
}

actor HermesProfileLedgerStore {
    private static let maximumMembershipCount = 4096
    private static let maximumMembershipBytes = 512 * 1024

    private let defaultLedger: HermesUsageLedger
    private let includesDefaultLedger: Bool
    private let directory: URL
    private let hermesHome: URL
    private let includesProfiles: Bool
    private var profileLedgers: [String: HermesUsageLedger] = [:]

    init(
        defaultLedger: HermesUsageLedger,
        includesDefaultLedger: Bool,
        directory: URL,
        hermesHome: URL,
        includesProfiles: Bool) {
        self.defaultLedger = defaultLedger
        self.includesDefaultLedger = includesDefaultLedger
        self.directory = directory
        self.hermesHome = hermesHome
        self.includesProfiles = includesProfiles
    }

    nonisolated func discoverCollection() throws -> HermesProfileCollection {
        try Task.checkCancellation()
        // Capture once before reading membership or discovering sources. A later root
        // retarget must not register this collection's identifiers in another collection.
        let canonicalHome = hermesHome.resolvingSymlinksInPath().standardizedFileURL
        let collectionIdentifier = SnapshotCipher.digest(
            "toki.hermes.profile-collection.v1:\(includesProfiles):\(includesDefaultLedger):\(canonicalHome.path)")
        let sources = try discoverHermesDatabaseSources(
            hermesHome: canonicalHome,
            includesProfiles: includesProfiles,
            preferredLedgerIdentifiers: readMembership(for: collectionIdentifier))
        return HermesProfileCollection(
            canonicalHome: canonicalHome,
            identifier: collectionIdentifier,
            sources: includesDefaultLedger ? sources : sources.map {
                HermesDatabaseSource(
                    databaseURL: $0.databaseURL, isDefault: false, ledgerIdentifier: $0.ledgerIdentifier)
            })
    }

    func ledger(for source: HermesDatabaseSource) -> HermesUsageLedger {
        if source.isDefault { return defaultLedger }
        return profileLedger(identifier: source.ledgerIdentifier)
    }

    func selectedLedgers(collection: HermesProfileCollection) throws -> [HermesProfileLedger] {
        try Task.checkCancellation()
        // Reload membership so separately constructed readers can discover durable history.
        let previous = try readMembership(for: collection.identifier)
        let selected = Set(collection.sources.filter { !$0.isDefault }.map(\.ledgerIdentifier))
        let identifiers = previous.union(selected)
        guard identifiers.count <= Self.maximumMembershipCount else {
            throw HermesProfileCollectionError.invalidMembership
        }
        if identifiers != previous {
            try Task.checkCancellation()
            let document = HermesProfileMembership(schemaVersion: 1, ledgerIdentifiers: identifiers.sorted())
            try DurableFileIO.preparePrivateDirectory(directory)
            try DurableFileIO.writePrivate(
                JSONEncoder().encode(document), to: membershipURL(for: collection.identifier))
        }
        let defaults = includesDefaultLedger
            ? [HermesProfileLedger(profileIdentifier: nil, ledger: defaultLedger)] : []
        return defaults + identifiers.sorted().map {
            HermesProfileLedger(profileIdentifier: $0, ledger: profileLedger(identifier: $0))
        }
    }

    func historyStatus(collection: HermesProfileCollection) async throws -> HermesCollectionHistoryStatus {
        let identifiers = try readMembership(for: collection.identifier)
            .union(collection.sources.filter { !$0.isDefault }.map(\.ledgerIdentifier))
        guard identifiers.count <= Self.maximumMembershipCount else {
            throw HermesProfileCollectionError.invalidMembership
        }
        let ledgers = (includesDefaultLedger ? [(true, defaultLedger)] : [])
            + identifiers.sorted().map { (false, profileLedger(identifier: $0)) }
        var profiles: [HermesCollectionHistoryStatus.Profile] = []
        for (isDefault, ledger) in ledgers {
            try Task.checkCancellation()
            do {
                let status = try await ledger.status()
                profiles.append(.init(isDefault: isDefault, status: status))
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                profiles.append(.init(isDefault: isDefault, status: nil))
            }
        }
        return HermesCollectionHistoryStatus(profiles: profiles)
    }

    nonisolated func sourceLocations(collection: HermesProfileCollection) throws -> [LocalUsageSourceLocation] {
        let identifiers = try readMembership(for: collection.identifier)
            .union(collection.sources.filter { !$0.isDefault }.map(\.ledgerIdentifier))
        guard identifiers.count <= Self.maximumMembershipCount else {
            throw HermesProfileCollectionError.invalidMembership
        }
        let ledgerURLs = (includesDefaultLedger ? [defaultLedger.fileURL] : []) + identifiers.sorted().map {
            directory.appendingPathComponent("hermes-usage-ledger-profile-\($0).json")
        }
        var locations: [LocalUsageSourceLocation] = [
            .file(membershipURL(for: collection.identifier), includesSQLiteSidecars: false),
        ]
        for url in ledgerURLs {
            try Task.checkCancellation()
            locations.append(.file(url, includesSQLiteSidecars: false))
            locations.append(.file(hermesUsageLedgerIdentifierKeyURL(for: url), includesSQLiteSidecars: false))
        }
        return locations
    }

    private nonisolated func membershipURL(for collectionIdentifier: String) -> URL {
        directory.appendingPathComponent("hermes-profile-collection-\(collectionIdentifier).json")
    }

    private nonisolated func readMembership(for collectionIdentifier: String) throws -> Set<String> {
        do {
            guard let data = try DurableFileIO.readPrivate(
                from: membershipURL(for: collectionIdentifier),
                maximumByteCount: Self.maximumMembershipBytes) else { return [] }
            let document = try JSONDecoder().decode(HermesProfileMembership.self, from: data)
            guard document.schemaVersion == 1,
                  document.ledgerIdentifiers.count <= Self.maximumMembershipCount,
                  document.ledgerIdentifiers.allSatisfy(SnapshotCipher.isSHA256Digest),
                  Set(document.ledgerIdentifiers).count == document.ledgerIdentifiers.count else {
                throw HermesProfileCollectionError.invalidMembership
            }
            return Set(document.ledgerIdentifiers)
        } catch {
            throw HermesProfileCollectionError.invalidMembership
        }
    }

    private func profileLedger(identifier: String) -> HermesUsageLedger {
        if let ledger = profileLedgers[identifier] { return ledger }
        // Retain the candidate's exact file names and existing per-ledger key files.
        // Unmapped old ledgers are left untouched; their collection cannot safely be guessed.
        let url = directory.appendingPathComponent("hermes-usage-ledger-profile-\(identifier).json")
        let ledger = HermesUsageLedger(fileURL: url)
        profileLedgers[identifier] = ledger
        return ledger
    }
}

private struct HermesProfileMembership: Codable {
    let schemaVersion: Int
    let ledgerIdentifiers: [String]
}
