import Foundation
import XCTest
@testable import TokiUsageReaders

#if os(Linux)
    import Glibc
#else
    import Darwin
#endif

final class HermesHostileProfilePathTests: XCTestCase {
    func test_enotdirProfileRetainsHealthyUsageAndDiagnosesIncompleteCollection() async throws {
        try await assertPartial(kind: .notDirectory)
    }

    func test_eloopProfileRetainsHealthyUsageAndDiagnosesIncompleteCollection() async throws {
        try await assertPartial(kind: .loop)
    }

    func test_enametoolongProfileRetainsHealthyUsageAndDiagnosesIncompleteCollection() async throws {
        try await assertPartial(kind: .tooLong)
    }

    func test_malformedDefaultDatabaseRetainsHealthyNamedUsageAndDiagnostics() async throws {
        for kind in HostileHermesPath.allCases {
            try await assertPartial(kind: kind, malformedDefault: true)
        }
    }

    func test_malformedExplicitHomeFailsWithSanitizedDiagnostics() async throws {
        for kind in HostileHermesPath.allCases {
            let fixture = try HermesM1Fixture()
            defer { fixture.remove() }
            let selected = fixture.root.appendingPathComponent("selected")
            try kind.create(at: selected, fixture: fixture)
            let reader = fixture.reader(at: selected)
            do {
                _ = try await reader.readUsage(from: fixture.start, to: fixture.end)
                XCTFail("An uninspectable selected source must not be reported as empty")
            } catch HermesProfileCollectionError.discoveryFailed {}
            XCTAssertThrowsError(try reader.coverageStatus())
        }
    }

    private func assertPartial(kind: HostileHermesPath, malformedDefault: Bool = false) async throws {
        for existing in [false, true] {
            let fixture = try HermesM1Fixture()
            defer { fixture.remove() }
            let badDatabase = fixture.database(malformedDefault ? nil : "hostile")
            let healthy = malformedDefault ? [fixture.database("healthy")] : [
                fixture.database(),
                fixture.database("healthy"),
            ]
            for database in healthy + (existing ? [badDatabase] : []) {
                try fixture.createDatabase(at: database)
                try fixture.insert(at: database, tokens: database == badDatabase ? 17 : 10)
                try await fixture
                    .seedLedger(at: fixture.ledgerURL(for: database == fixture.database() ? nil : database))
            }
            let reader = fixture.reader()
            let original = try await reader.readUsage(from: fixture.start, to: fixture.end)
            let path = malformedDefault ? badDatabase : badDatabase.deletingLastPathComponent()
            if existing { try FileManager.default.removeItem(at: path) }
            try kind.create(at: path, fixture: fixture)
            var metadata = stat()
            XCTAssertEqual(path.path.withCString { stat($0, &metadata) }, -1)
            XCTAssertEqual(errno, kind.code, "Fixture must exercise the intended POSIX failure")

            for current in [reader, reader, fixture.reader()] {
                do {
                    let usage = try await current.readUsage(from: fixture.start, to: fixture.end)
                    XCTAssertEqual(usage.tokenEvents, original.tokenEvents)
                    XCTAssertEqual(usage.inputTokens, healthy.count * 10 + (existing ? 17 : 0))
                    XCTAssertEqual(usage.cost, Double(healthy.count + (existing ? 1 : 0)) * 0.25)
                    XCTAssertEqual(usage.supplemental.first { $0.id == "hermes-profile-read-errors" }?.value, 1)
                } catch {
                    XCTFail("Healthy siblings must survive a profile path error: \(error.localizedDescription)")
                }
                do {
                    XCTAssertEqual(try current.coverageStatus().profileReadErrorCount, 1)
                } catch {
                    XCTFail("Coverage must preserve healthy siblings: \(error.localizedDescription)")
                }
                do {
                    _ = try await HermesSnapshotReader(reader: current).readUsage(from: fixture.start, to: fixture.end)
                    XCTFail("Snapshot must reject incomplete collection")
                } catch HermesProfileCollectionError.incompleteCollection {
                    // Expected: the public snapshot boundary sees the reader's partial diagnostic.
                } catch {
                    XCTFail("Expected partial collection rejection, got \(error.localizedDescription)")
                }
            }
        }
    }
}

private enum HostileHermesPath: CaseIterable {
    case notDirectory, loop, tooLong

    var code: Int32 {
        switch self {
        case .notDirectory: ENOTDIR
        case .loop: ELOOP
        case .tooLong: ENAMETOOLONG
        }
    }

    func create(at path: URL, fixture: HermesM1Fixture) throws {
        try FileManager.default.createDirectory(at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
        let target: URL
        switch self {
        case .notDirectory:
            let file = fixture.root.appendingPathComponent("regular-file")
            try Data([1]).write(to: file)
            target = file.appendingPathComponent("child")
        case .loop:
            target = path
        case .tooLong:
            target = fixture.root.appendingPathComponent(String(repeating: "x", count: 300))
        }
        try FileManager.default.createSymbolicLink(at: path, withDestinationURL: target)
    }
}
