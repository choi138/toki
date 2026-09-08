import Foundation
import XCTest
@testable import TokiUsageReaders

final class HermesPhysicalIdentityTests: XCTestCase {
    func test_identityEqualityIsTransitiveAndEqualValuesShareHashes() throws {
        let fixture = try HermesM1Fixture()
        defer { fixture.remove() }
        let original = fixture.database("original")
        let hardlink = fixture.database("hardlink")
        try fixture.createDatabase(at: original)
        try FileManager.default.createDirectory(
            at: hardlink.deletingLastPathComponent(),
            withIntermediateDirectories: true)
        try FileManager.default.linkItem(at: original, to: hardlink)
        let inode = HermesPhysicalDatabaseIdentity(url: original, fileManager: .default)
        let alias = HermesPhysicalDatabaseIdentity(url: hardlink, fileManager: .default)
        let fallback = HermesMetadataFileManager.Mode.allCases.map {
            HermesPhysicalDatabaseIdentity(
                url: original, fileManager: HermesMetadataFileManager(paths: [original.path], mode: $0))
        }
        XCTAssertEqual(inode, alias, "Hardlink paths share the inode identity domain")
        XCTAssertTrue(fallback.allSatisfy { $0 != inode }, "Path and inode domains must remain distinct")
        let values = [inode, alias] + fallback
        for lhs in values {
            XCTAssertEqual(lhs, lhs)
            for rhs in values {
                XCTAssertEqual(lhs == rhs, rhs == lhs)
                if lhs == rhs {
                    // Compare equal values only. No randomized unequal-hash assumptions.
                    XCTAssertEqual(lhs.hashValue, rhs.hashValue)
                }
                for third in values where lhs == rhs && rhs == third {
                    XCTAssertEqual(lhs, third)
                }
            }
        }
        XCTAssertEqual(Set(values).count, 2)
    }

    func test_partialMetadataCannotSplitHardlinkAliasesIntoIndependentSources() throws {
        for mode in HermesMetadataFileManager.Mode.allCases {
            let fixture = try HermesM1Fixture()
            defer { fixture.remove() }
            let original = fixture.database("original")
            let alias = fixture.database("alias")
            try fixture.createDatabase(at: original)
            try FileManager.default.createDirectory(
                at: alias.deletingLastPathComponent(),
                withIntermediateDirectories: true)
            try FileManager.default.linkItem(at: original, to: alias)
            let manager = HermesMetadataFileManager(paths: [alias.path], mode: mode)
            XCTAssertThrowsError(
                try discoverHermesDatabaseSources(
                    hermesHome: fixture.hermesHome, includesProfiles: true, fileManager: manager),
                "An existing database with uncertain identity must fail closed, not become another ledger")
        }
    }

    func test_missingMetadataForBothHardlinksCannotCreateTwoOwners() throws {
        let fixture = try HermesM1Fixture()
        defer { fixture.remove() }
        let original = fixture.database("original")
        let alias = fixture.database("alias")
        try fixture.createDatabase(at: original)
        try FileManager.default.createDirectory(
            at: alias.deletingLastPathComponent(),
            withIntermediateDirectories: true)
        try FileManager.default.linkItem(at: original, to: alias)
        XCTAssertThrowsError(try discoverHermesDatabaseSources(
            hermesHome: fixture.hermesHome, includesProfiles: true,
            fileManager: HermesMetadataFileManager(paths: [original.path, alias.path], mode: .missing)))
    }

    func test_realMetadataPreservesHardlinkSymlinkDedupAndDistinctDatabasesThroughReader() async throws {
        let fixture = try HermesM1Fixture()
        defer { fixture.remove() }
        let original = fixture.database("original")
        let other = fixture.database("other")
        for database in [original, other] {
            try fixture.createDatabase(at: database)
            try fixture.insert(at: database, tokens: 20)
            try await fixture.seedLedger(at: fixture.ledgerURL(for: database))
        }
        let reader = fixture.reader()
        let expected = try await reader.readUsage(from: fixture.start, to: fixture.end)
        for (name, symbolic) in [("hard", false), ("symbolic", true)] {
            let alias = fixture.database(name)
            try FileManager.default.createDirectory(
                at: alias.deletingLastPathComponent(),
                withIntermediateDirectories: true)
            if symbolic {
                try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: original)
            } else {
                try FileManager.default.linkItem(at: original, to: alias)
            }
        }
        for current in [reader, reader, fixture.reader()] {
            let usage = try await current.readUsage(from: fixture.start, to: fixture.end)
            XCTAssertEqual(usage.tokenEvents, expected.tokenEvents)
            XCTAssertEqual(usage.inputTokens, 40)
            XCTAssertEqual(usage.cost, 0.5)
            XCTAssertEqual(usage.tokenEvents.count, 2)
            XCTAssertEqual(try current.coverageStatus().profileReadErrorCount, 0)
        }
    }
}

final class HermesMetadataFileManager: FileManager, @unchecked Sendable {
    enum Mode: CaseIterable {
        case missing, fileOnly, systemOnly, denied
    }

    let paths: Set<String>
    let mode: Mode

    init(paths: Set<String>, mode: Mode) {
        self.paths = paths
        self.mode = mode
        super.init()
    }

    override func attributesOfItem(atPath path: String) throws -> [FileAttributeKey: Any] {
        guard paths.contains(path) else { return try super.attributesOfItem(atPath: path) }
        if mode == .denied { throw NSError(domain: NSPOSIXErrorDomain, code: 13) }
        var attributes = try super.attributesOfItem(atPath: path)
        if mode != .systemOnly { attributes.removeValue(forKey: .systemNumber) }
        if mode != .fileOnly { attributes.removeValue(forKey: .systemFileNumber) }
        return attributes
    }
}
