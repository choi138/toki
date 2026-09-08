import Foundation

// Schema/filename policy and synthetic fixture references:
// junhoyeo/tokscale@3bd6dceb98925edab4e149c9bb1cf3fec9123f17, MIT licensed.
// The Swift implementation is local; retain this notice with source-derived policy/fixtures.
//
// MIT License
// Copyright (c) 2025 Junho Yeo
//
// Permission is hereby granted, free of charge, to any person obtaining a copy
// of this software and associated documentation files (the "Software"), to deal
// in the Software without restriction, including without limitation the rights
// to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
// copies of the Software, and to permit persons to whom the Software is
// furnished to do so, subject to the following conditions:
//
// The above copyright notice and this permission notice shall be included in all
// copies or substantial portions of the Software.
//
// THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
// IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
// FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
// AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
// LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
// OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
// SOFTWARE.

/// A fresh, bounded discovery result for registry/mount/signature integration.
/// Database URLs include explicitly configured missing files so their creation can be watched.
public struct OpenCodeSourceLocations: Equatable {
    public let dataRoots: [URL]
    public let databaseURLs: [URL]
    public let legacyMessageDirectories: [URL]
}

struct OpenCodeDatabaseStore {
    var url: URL
    var migrationRoots: Set<URL>
    let namespace: String
    var aliases: Set<URL>

    var selectionIdentity: String {
        let roots = migrationRoots.map(\.path).sorted().map(openCodeIdentityComponent).joined()
        let paths = aliases.map(\.path).sorted().map(openCodeIdentityComponent).joined()
        return [namespace, roots, paths].map(openCodeIdentityComponent).joined()
    }
}

struct OpenCodeDiscovery {
    let stores: [OpenCodeDatabaseStore]
    let legacyRoots: [URL]
    let locations: OpenCodeSourceLocations

    static func collect(
        dataRoots: [URL],
        databaseURLs: [URL],
        budget: OpenCodeReadBudget) throws -> OpenCodeDiscovery {
        try Task.checkCancellation()
        guard dataRoots.count <= budget.limits.maximumRootCount,
              databaseURLs.count <= budget.limits.maximumDatabaseCount,
              (dataRoots + databaseURLs).allSatisfy({ $0.isFileURL && !$0.path.contains("\0") }) else {
            throw OpenCodeReaderError.invalidConfiguration
        }
        let roots = Array(Set(dataRoots.map(openCodeCanonicalURL))).sorted { $0.path < $1.path }
        var candidates = try databaseURLs + discoveredDatabases(in: roots, budget: budget)
        // Prefer the default file over hard-link/channel aliases, then use path order.
        candidates.sort {
            let lhs = openCodeCanonicalURL($0)
            let rhs = openCodeCanonicalURL($1)
            if (lhs.lastPathComponent == "opencode.db") != (rhs.lastPathComponent == "opencode.db") {
                return lhs.lastPathComponent == "opencode.db"
            }
            return lhs.path < rhs.path
        }
        var stores: [OpenCodeDatabaseStore] = []
        var indices: [String: Int] = [:]
        var missingExplicit: Set<URL> = []
        var legacyRoots = Set(roots + databaseURLs.map { openCodeCanonicalURL($0.deletingLastPathComponent()) })
        for candidate in candidates {
            try Task.checkCancellation()
            let canonical = openCodeCanonicalURL(candidate)
            guard let attributes = try openCodeAttributes(canonical) else {
                if databaseURLs.contains(candidate) { missingExplicit.insert(canonical) }
                continue
            }
            guard attributes[.type] as? FileAttributeType == .typeRegular else {
                throw OpenCodeReaderError.unreadableSource
            }
            let migrationRoots: Set<URL> = [
                openCodeCanonicalURL(candidate.deletingLastPathComponent()),
                openCodeCanonicalURL(canonical.deletingLastPathComponent()),
            ]
            let identity = openCodePhysicalIdentity(canonical, attributes: attributes)
            if let index = indices[identity] {
                stores[index].migrationRoots.formUnion(migrationRoots)
                stores[index].aliases.insert(canonical)
            } else {
                guard stores.count < budget.limits.maximumDatabaseCount else {
                    throw OpenCodeReaderError.limitExceeded
                }
                indices[identity] = stores.count
                stores.append(OpenCodeDatabaseStore(
                    url: canonical, migrationRoots: migrationRoots,
                    namespace: openCodeDatabaseNamespace(canonical), aliases: [canonical]))
            }
            // Do not follow an auto-discovered file alias into unrelated legacy trees.
            // Only requested roots and explicit database parents authorize legacy discovery.
        }
        for index in stores.indices {
            stores[index].url = try databaseReadURL(preferred: stores[index].url, aliases: stores[index].aliases)
        }
        legacyRoots = Set(legacyRoots.map(openCodeCanonicalURL))
        guard legacyRoots.count <= budget.limits.maximumRootCount else {
            throw OpenCodeReaderError.limitExceeded
        }
        let orderedLegacyRoots = legacyRoots.sorted { $0.path < $1.path }
        return OpenCodeDiscovery(
            stores: stores,
            legacyRoots: orderedLegacyRoots,
            locations: OpenCodeSourceLocations(
                dataRoots: roots,
                databaseURLs: Array(Set(stores.map(\.url)).union(missingExplicit)).sorted { $0.path < $1.path },
                legacyMessageDirectories: orderedLegacyRoots.map { $0.appendingPathComponent("storage/message") }))
    }

    private static func databaseReadURL(preferred: URL, aliases paths: Set<URL>) throws -> URL {
        guard paths.count > 1 else { return preferred }
        let journalOwners = try paths.filter { url in
            try ["-wal", "-journal"].contains { suffix in
                guard let attributes = try openCodeAttributes(URL(fileURLWithPath: url.path + suffix)) else {
                    return false
                }
                guard attributes[.type] as? FileAttributeType == .typeRegular,
                      let size = attributes[.size] as? NSNumber else {
                    throw OpenCodeReaderError.unreadableSource
                }
                return size.uint64Value > 0
            }
        }
        // SQLite journals belong to a pathname, while hardlinks share only the database.
        // Keep the namespace from the preferred alias even when the read path changes.
        guard journalOwners.count <= 1 else { throw OpenCodeReaderError.unreadableSource }
        return journalOwners.first ?? preferred
    }

    private static func discoveredDatabases(in roots: [URL], budget: OpenCodeReadBudget) throws -> [URL] {
        var candidates: [URL] = []
        for root in roots {
            guard let attributes = try openCodeAttributes(root) else { continue }
            guard attributes[.type] as? FileAttributeType == .typeDirectory else {
                throw OpenCodeReaderError.unreadableSource
            }
            var failed = false
            guard let enumerator = FileManager.default.enumerator(
                at: root, includingPropertiesForKeys: nil,
                errorHandler: { _, _ in
                    failed = true
                    return false
                }) else { throw OpenCodeReaderError.unreadableSource }
            while let entry = enumerator.nextObject() as? URL {
                enumerator.skipDescendants()
                try budget.consumeEntry()
                guard isDatabaseFilename(entry.lastPathComponent),
                      let entryAttributes = try openCodeAttributes(openCodeCanonicalURL(entry)),
                      entryAttributes[.type] as? FileAttributeType == .typeRegular else { continue }
                guard candidates.count < budget.limits.maximumDatabaseCount else {
                    throw OpenCodeReaderError.limitExceeded
                }
                candidates.append(entry)
            }
            if failed { throw OpenCodeReaderError.unreadableSource }
        }
        return candidates
    }

    /// Pinned tokscale scanner.rs: opencode.db or opencode-<channel>.db;
    /// channel sanitization is ASCII [a-zA-Z0-9._-], never WAL/SHM/journal files.
    private static func isDatabaseFilename(_ name: String) -> Bool {
        if name == "opencode.db" { return true }
        guard name.hasPrefix("opencode-"), name.hasSuffix(".db") else { return false }
        let channel = name.dropFirst("opencode-".count).dropLast(3)
        return !channel.isEmpty && channel.utf8.allSatisfy {
            (65...90).contains($0) || (97...122).contains($0) || (48...57).contains($0)
                || $0 == 46 || $0 == 95 || $0 == 45
        }
    }
}
