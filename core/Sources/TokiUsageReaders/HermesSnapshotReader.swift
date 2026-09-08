import Foundation
import TokiUsageCore

func hermesReaderDescriptor(
    paths: LocalUsageReaderPaths,
    usageLedger: HermesUsageLedger,
    cacheScope: LocalUsageCacheScope) -> LocalUsageReaderDescriptor {
    let reader = HermesReader(
        hermesHomeURL: paths.hermesHome,
        includesProfiles: paths.hermesDiscoversProfiles,
        usesLegacyDefaultLedger: true,
        usageLedger: usageLedger,
        profileLedgerDirectory: paths.cacheDirectory(for: cacheScope)
            .appendingPathComponent("hermes-profile-ledgers", isDirectory: true),
        legacyDefaultDatabaseURL: paths.hermesDefaultDatabase)
    let scopedReader: any TokenReader = switch cacheScope {
    case .application: reader
    case .agent: HermesSnapshotReader(reader: reader)
    }
    return LocalUsageReaderDescriptor(
        reader: scopedReader,
        sourceLocations: [.file(paths.hermesDatabase, includesSQLiteSidecars: true)],
        sourceSignatureStrategy: .allFiles,
        collectorRevision: 1,
        sourceLocationsResolver: reader.selectedSourceLocations)
}

/// Snapshot consumers currently have no partial-coverage field. Block incomplete exports
/// while the application reader can still display successful profiles and their diagnostics.
struct HermesSnapshotReader: TokenReader {
    let reader: HermesReader
    var name: String {
        reader.name
    }

    func readUsage(from startDate: Date, to endDate: Date) async throws -> RawTokenUsage {
        let usage = try await reader.readUsage(from: startDate, to: endDate)
        try Task.checkCancellation()
        let errors = usage.supplemental.first { $0.id == "hermes-profile-read-errors" }?.value ?? 0
        guard errors == 0 else { throw HermesProfileCollectionError.incompleteCollection(errors) }
        return usage
    }
}
