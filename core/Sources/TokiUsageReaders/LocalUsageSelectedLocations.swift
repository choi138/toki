import Foundation
import TokiUsageCore

extension LocalUsageSourceLocation {
    /// Canonicalize only roots/files explicitly selected by a registered reader. Generic
    /// directory enumeration keeps its existing policy of skipping child symbolic links.
    var canonicalSelectedLocation: LocalUsageSourceLocation {
        let canonical = url.resolvingSymlinksInPath().standardizedFileURL
        return switch self {
        case let .file(_, sidecars, identity):
            .file(canonical, includesSQLiteSidecars: sidecars, selectionIdentity: identity)
        case let .directory(_, extensions, identity):
            .directory(canonical, extensions: extensions, selectionIdentity: identity)
        case .directoryPresence: .directoryPresence(canonical)
        }
    }
}

package enum LocalUsageSourceLocation: Equatable {
    /// Optional selection identity covers semantic ownership beyond file metadata.
    /// The agent hashes this local context; it is never included in a snapshot.
    case file(URL, includesSQLiteSidecars: Bool, selectionIdentity: String? = nil)
    case directory(URL, extensions: Set<String>, selectionIdentity: String? = nil)
    /// A selected discovery root; its contents are already classified by the reader.
    case directoryPresence(URL)

    package var url: URL {
        switch self {
        case let .file(url, _, _), let .directory(url, _, _), let .directoryPresence(url):
            url
        }
    }
}

package enum LocalUsageSourceSignatureStrategy {
    case standard
    case allFiles
    case boundedAllFiles(maximumFileCount: Int, maximumEntryCount: Int)
    case codexRollouts
}

package struct LocalUsageReaderDescriptor {
    package let reader: any TokenReader
    package let sourceLocations: [LocalUsageSourceLocation]
    package let sourceSignatureStrategy: LocalUsageSourceSignatureStrategy
    package let collectorRevision: Int?
    private let sourceLocationsResolver: (() throws -> [LocalUsageSourceLocation])?

    package init(
        reader: any TokenReader,
        sourceLocations: [LocalUsageSourceLocation],
        sourceSignatureStrategy: LocalUsageSourceSignatureStrategy = .standard,
        collectorRevision: Int? = nil,
        sourceLocationsResolver: (() throws -> [LocalUsageSourceLocation])? = nil) {
        self.reader = reader
        self.sourceLocations = sourceLocations
        self.sourceSignatureStrategy = sourceSignatureStrategy
        self.collectorRevision = collectorRevision
        self.sourceLocationsResolver = sourceLocationsResolver
    }

    package func resolvedSourceLocations() throws -> [LocalUsageSourceLocation] {
        try Task.checkCancellation()
        return try sourceLocationsResolver?() ?? sourceLocations
    }

    package var name: String {
        reader.name
    }
}
