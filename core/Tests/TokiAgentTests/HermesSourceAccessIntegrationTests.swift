import Foundation
import XCTest
@testable import TokiAgentCore
@testable import TokiUsageReaders

final class HermesSourceAccessIntegrationTests: XCTestCase {
    func test_inaccessibleProfileCannotReuseCompleteSourceSignature() async throws {
        let fixture = try HermesM1Fixture()
        defer { fixture.remove() }
        let database = fixture.database("restricted")
        try fixture.createDatabase(at: database)
        let builder = AgentSnapshotBuilder(home: fixture.home, environment: fixture.environment)
        let before = try await builder.sourceSignature(configuration: fixture.configuration(), now: fixture.now)
        XCTAssertNotNil(before)
        let directory = database.deletingLastPathComponent()
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: directory.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path) }
        try XCTSkipIf(
            FileManager.default.fileExists(atPath: database.path),
            "The test process can bypass directory traversal permissions")
        do {
            _ = try await builder.sourceSignature(configuration: fixture.configuration(), now: fixture.now)
            XCTFail("An inaccessible profile must not become a successful missing-file signature")
        } catch HermesProfileCollectionError.discoveryFailed {}
        XCTAssertThrowsError(try builder.validateSourceMounts())
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        let restored = try await builder.sourceSignature(configuration: fixture.configuration(), now: fixture.now)
        XCTAssertEqual(restored, before)
    }
}
