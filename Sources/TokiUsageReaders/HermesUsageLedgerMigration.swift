import Foundation
import TokiDurableStorage
import TokiSyncProtocol

public enum HermesUsageLedgerMigrationMode: Equatable {
    case dryRun
    case apply
}

public enum HermesUsageLedgerMigrationResult: Equatable {
    case noLedger
    case notRequired
    case migrationRequired
    case migrated
}

public enum HermesUsageLedgerMigrator {
    public static func migrate(
        fileURL: URL,
        mode: HermesUsageLedgerMigrationMode = .dryRun) throws -> HermesUsageLedgerMigrationResult {
        let source: Data
        do {
            guard let data = try DurableFileIO.readPrivate(
                from: fileURL,
                maximumByteCount: hermesUsageLedgerMaximumBytes) else {
                if mode == .apply,
                   pathExistsIncludingSymbolicLink(fileURL.deletingLastPathComponent()) {
                    let legacyTemporaryURLs = try legacyTemporaryLedgerURLs(ledgerURL: fileURL)
                    try removeLegacyArtifacts(
                        ledgerURL: fileURL,
                        temporaryURLs: legacyTemporaryURLs)
                }
                return .noLedger
            }
            source = data
        } catch DurableFileIOError.privateFileTooLarge {
            throw HermesUsageLedgerError.ledgerTooLarge
        } catch {
            throw HermesUsageLedgerError.invalidLedger
        }

        let legacyTemporaryURLs = mode == .apply
            ? try legacyTemporaryLedgerURLs(ledgerURL: fileURL)
            : []
        let schemaVersion: Int
        do {
            schemaVersion = try JSONDecoder().decode(HermesUsageLedgerVersionProbe.self, from: source).schemaVersion
        } catch {
            throw HermesUsageLedgerError.invalidLedger
        }
        if schemaVersion == hermesUsageLedgerSchemaVersion {
            try validateCurrentLedger(source, fileURL: fileURL)
            if mode == .apply {
                try removeLegacyArtifacts(
                    ledgerURL: fileURL,
                    temporaryURLs: legacyTemporaryURLs)
            }
            return .notRequired
        }

        let migration = try migration(source: source, schemaVersion: schemaVersion)
        guard mode == .apply else { return .migrationRequired }

        try writeIdentifierKeyIfNeeded(migration.identifierKey, ledgerURL: fileURL)
        do {
            try DurableFileIO.writePrivate(migration.ledger, to: fileURL)
        } catch DurableFileIOError.replacementCommittedDirectorySyncFailed {
            throw HermesUsageLedgerError.durabilityNotConfirmed
        } catch {
            throw HermesUsageLedgerError.couldNotPersist
        }
        try removeLegacyArtifacts(
            ledgerURL: fileURL,
            temporaryURLs: legacyTemporaryURLs)
        return .migrated
    }
}

private extension HermesUsageLedgerMigrator {
    struct Migration {
        let identifierKey: String
        let ledger: Data
    }

    static func migration(source: Data, schemaVersion: Int) throws -> Migration {
        let document: HermesUsageLedgerDocument
        switch schemaVersion {
        case hermesUsageLedgerPreviousSchemaVersion:
            let previous: HermesUsageLedgerDocument
            do {
                previous = try JSONDecoder().decode(HermesUsageLedgerDocument.self, from: source)
            } catch {
                throw HermesUsageLedgerError.invalidLedger
            }
            try validatePrevious(previous)
            document = sanitize(previous)
        case hermesUsageLedgerLegacySchemaVersion:
            let legacy: HermesUsageLedgerV1Document
            do {
                legacy = try JSONDecoder().decode(HermesUsageLedgerV1Document.self, from: source)
            } catch {
                throw HermesUsageLedgerError.invalidLedger
            }
            try validateLegacy(legacy)
            document = migrateLegacy(legacy)
        default:
            throw HermesUsageLedgerError.invalidLedger
        }
        try validate(document)
        let encoded: Data
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            encoded = try encoder.encode(HermesUsageLedgerPrivateDocument(document))
        } catch {
            throw HermesUsageLedgerError.couldNotPersist
        }
        guard encoded.count <= hermesUsageLedgerMaximumBytes else {
            throw HermesUsageLedgerError.ledgerTooLarge
        }
        return Migration(identifierKey: document.identifierKey, ledger: encoded)
    }

    static func sanitize(_ previous: HermesUsageLedgerDocument) -> HermesUsageLedgerDocument {
        HermesUsageLedgerDocument(
            schemaVersion: hermesUsageLedgerSchemaVersion,
            identifierKey: previous.identifierKey,
            accurateSince: previous.accurateSince,
            lastSuccessfulObservationAt: previous.lastSuccessfulObservationAt,
            baselines: previous.baselines.mapValues {
                HermesUsageLedgerPrivateBaseline($0).baseline
            },
            unattributed: previous.unattributed,
            events: previous.events.map { HermesUsageLedgerPrivateEvent($0).event })
    }

    static func migrateLegacy(_ legacy: HermesUsageLedgerV1Document) -> HermesUsageLedgerDocument {
        let accurateSince = legacy.baselines.values.map(\.lastObservedAt).max()
        let unattributed = legacy.baselines.reduce(
            into: [String: HermesUsageLedgerCarryover]()) { result, element in
                guard element.value.counters.totalTokens > 0 else { return }
                result[element.key] = HermesUsageLedgerCarryover(
                    counters: element.value.counters,
                    cost: element.value.cost,
                    firstObservedAt: element.value.lastObservedAt)
            }
        return HermesUsageLedgerDocument(
            schemaVersion: hermesUsageLedgerSchemaVersion,
            identifierKey: legacy.identifierKey,
            accurateSince: accurateSince,
            lastSuccessfulObservationAt: accurateSince,
            baselines: legacy.baselines.mapValues {
                HermesUsageLedgerPrivateBaseline($0).baseline
            },
            unattributed: unattributed,
            events: [])
    }

    static func validateCurrentLedger(_ data: Data, fileURL: URL) throws {
        let privateDocument: HermesUsageLedgerPrivateDocument
        do {
            privateDocument = try JSONDecoder().decode(HermesUsageLedgerPrivateDocument.self, from: data)
        } catch {
            throw HermesUsageLedgerError.invalidLedger
        }
        let key = try readIdentifierKey(ledgerURL: fileURL)
        try validate(privateDocument.document(identifierKey: key))
    }

    static func validate(_ document: HermesUsageLedgerDocument) throws {
        guard document.schemaVersion == hermesUsageLedgerSchemaVersion,
              document.baselines.count <= hermesUsageLedgerMaximumBaselines,
              document.unattributed.count <= hermesUsageLedgerMaximumBaselines,
              document.events.count <= hermesUsageLedgerMaximumEvents,
              document.accurateSince.map(hermesDateIsValid) ?? true,
              document.lastSuccessfulObservationAt.map(hermesDateIsValid) ?? true,
              validLedgerObservationRange(document),
              (try? SnapshotCipher.makeOpaqueIdentifierHasher(key: document.identifierKey)) != nil,
              document.baselines.allSatisfy({ identifier, baseline in
                  hermesIdentifierIsValid(identifier) && baseline.isValid
              }),
              document.unattributed.allSatisfy({ identifier, carryover in
                  hermesIdentifierIsValid(identifier)
                      && document.baselines[identifier] != nil
                      && carryover.isValid
              }),
              document.events.allSatisfy(\.isValid) else {
            throw HermesUsageLedgerError.invalidLedger
        }
    }

    static func validatePrevious(_ document: HermesUsageLedgerDocument) throws {
        guard document.schemaVersion == hermesUsageLedgerPreviousSchemaVersion,
              document.baselines.count <= hermesUsageLedgerMaximumBaselines,
              document.unattributed.count <= hermesUsageLedgerMaximumBaselines,
              document.events.count <= hermesUsageLedgerMaximumEvents,
              document.accurateSince.map(hermesDateIsValid) ?? true,
              document.lastSuccessfulObservationAt.map(hermesDateIsValid) ?? true,
              (try? SnapshotCipher.makeOpaqueIdentifierHasher(key: document.identifierKey)) != nil,
              document.baselines.allSatisfy({ identifier, baseline in
                  hermesIdentifierIsValid(identifier) && baseline.isValid
              }),
              document.unattributed.allSatisfy({ identifier, carryover in
                  hermesIdentifierIsValid(identifier)
                      && document.baselines[identifier] != nil
                      && carryover.isValid
              }),
              document.events.allSatisfy(\.isValid) else {
            throw HermesUsageLedgerError.invalidLedger
        }
    }

    static func validateLegacy(_ document: HermesUsageLedgerV1Document) throws {
        guard document.schemaVersion == hermesUsageLedgerLegacySchemaVersion,
              document.baselines.count <= hermesUsageLedgerMaximumBaselines,
              document.events.count <= hermesUsageLedgerMaximumEvents,
              (try? SnapshotCipher.makeOpaqueIdentifierHasher(key: document.identifierKey)) != nil,
              document.baselines.allSatisfy({ identifier, baseline in
                  hermesIdentifierIsValid(identifier) && baseline.isValid
              }),
              document.events.allSatisfy(\.isValid) else {
            throw HermesUsageLedgerError.invalidLedger
        }
    }

    static func writeIdentifierKeyIfNeeded(_ key: String, ledgerURL: URL) throws {
        let keyURL = hermesUsageLedgerIdentifierKeyURL(for: ledgerURL)
        do {
            if let existing = try DurableFileIO.readPrivate(from: keyURL, maximumByteCount: 4096) {
                guard String(data: existing, encoding: .utf8) == key else {
                    throw HermesUsageLedgerError.invalidLedger
                }
                return
            }
            try DurableFileIO.writePrivate(Data(key.utf8), to: keyURL)
        } catch DurableFileIOError.replacementCommittedDirectorySyncFailed {
            throw HermesUsageLedgerError.durabilityNotConfirmed
        } catch let error as HermesUsageLedgerError {
            throw error
        } catch {
            throw HermesUsageLedgerError.couldNotPersist
        }
    }

    static func readIdentifierKey(ledgerURL: URL) throws -> String {
        do {
            guard let data = try DurableFileIO.readPrivate(
                from: hermesUsageLedgerIdentifierKeyURL(for: ledgerURL),
                maximumByteCount: 4096),
                let key = String(data: data, encoding: .utf8),
                (try? SnapshotCipher.makeOpaqueIdentifierHasher(key: key)) != nil else {
                throw HermesUsageLedgerError.invalidLedger
            }
            return key
        } catch let error as HermesUsageLedgerError {
            throw error
        } catch {
            throw HermesUsageLedgerError.invalidLedger
        }
    }

    static func legacyTemporaryLedgerURLs(ledgerURL: URL) throws -> [URL] {
        let directory = ledgerURL.deletingLastPathComponent()
        let prefix = ".\(ledgerURL.lastPathComponent)."
        let suffix = ".tmp"
        let urls: [URL]
        do {
            urls = try FileManager.default.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey])
        } catch {
            throw HermesUsageLedgerError.invalidLedger
        }
        return try urls.compactMap { url in
            let name = url.lastPathComponent
            guard name.hasPrefix(prefix),
                  name.hasSuffix(suffix),
                  name.count >= prefix.count + suffix.count else {
                return nil
            }
            let identifierStart = name.index(name.startIndex, offsetBy: prefix.count)
            let identifierEnd = name.index(name.endIndex, offsetBy: -suffix.count)
            guard UUID(uuidString: String(name[identifierStart..<identifierEnd])) != nil else {
                return nil
            }
            let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            guard values.isRegularFile == true, values.isSymbolicLink != true else {
                throw HermesUsageLedgerError.invalidLedger
            }
            let data: Data
            do {
                guard let source = try DurableFileIO.readPrivate(
                    from: url,
                    maximumByteCount: hermesUsageLedgerMaximumBytes) else {
                    return nil
                }
                data = source
            } catch {
                throw HermesUsageLedgerError.invalidLedger
            }
            guard let schemaVersion = try? JSONDecoder()
                .decode(HermesUsageLedgerVersionProbe.self, from: data).schemaVersion,
                schemaVersion == hermesUsageLedgerLegacySchemaVersion
                || schemaVersion == hermesUsageLedgerPreviousSchemaVersion else {
                return nil
            }
            return url
        }
    }

    static func removeLegacyArtifacts(
        ledgerURL: URL,
        temporaryURLs: [URL]) throws {
        for temporaryURL in temporaryURLs {
            do {
                try DurableFileIO.removeIfPresent(temporaryURL)
            } catch DurableFileIOError.removalCommittedDirectorySyncFailed {
                throw HermesUsageLedgerError.durabilityNotConfirmed
            } catch {
                throw HermesUsageLedgerError.couldNotPersist
            }
        }
        try removeLegacyBackups(ledgerURL: ledgerURL)
    }

    static func removeLegacyBackups(ledgerURL: URL) throws {
        for schemaVersion in [hermesUsageLedgerLegacySchemaVersion, hermesUsageLedgerPreviousSchemaVersion] {
            let backupURL = ledgerURL.appendingPathExtension("v\(schemaVersion).backup")
            do {
                try DurableFileIO.removeIfPresent(backupURL)
            } catch DurableFileIOError.removalCommittedDirectorySyncFailed {
                throw HermesUsageLedgerError.durabilityNotConfirmed
            } catch {
                throw HermesUsageLedgerError.couldNotPersist
            }
        }
    }
}
