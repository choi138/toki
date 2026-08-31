import Foundation
import TokiUsageCore
import XCTest
@testable import TokiUsageReaders

final class PiFamilyReaderDiscoveryTests: XCTestCase {
    func test_existingNonDirectorySessionRootSurfacesInspectionFailure() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("toki-pi-invalid-root-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        try Data("not a directory".utf8).write(to: root)

        do {
            _ = try await PiReader(sessionsURLOverride: root).readUsage(
                from: date("2026-08-20T00:00:00Z"),
                to: date("2026-08-21T00:00:00Z"))
            XCTFail("Expected session-root inspection to fail")
        } catch {
            XCTAssertEqual(
                error as? PiCompatibleReaderError,
                .unreadableFile(root.standardizedFileURL))
        }
    }

    func test_familyReadersReturnEmptyUsageForMissingRoots() async throws {
        let missing = FileManager.default.temporaryDirectory
            .appendingPathComponent("toki-pi-family-missing-\(UUID().uuidString)")
        let readers: [any TokenReader] = [
            PiReader(sessionsURLOverride: missing),
            OMPReader(sessionsURLOverride: missing),
            KimchiReader(sessionsURLOverride: missing),
        ]

        for reader in readers {
            let usage = try await reader.readUsage(
                from: date("2026-08-20T00:00:00Z"),
                to: date("2026-08-21T00:00:00Z"))
            XCTAssertFalse(usage.hasReportableData, reader.name)
        }
    }

    func test_cancellationPropagatesBeforeDiscovery() async throws {
        let missing = FileManager.default.temporaryDirectory
            .appendingPathComponent("toki-pi-cancelled-\(UUID().uuidString)")
        let reader = PiReader(sessionsURLOverride: missing)
        let task = Task { () throws -> RawTokenUsage in
            withUnsafeCurrentTask { $0?.cancel() }
            return try await reader.readUsage(
                from: date("2026-08-20T00:00:00Z"),
                to: date("2026-08-21T00:00:00Z"))
        }

        do {
            _ = try await task.value
            XCTFail("Expected cancellation to propagate")
        } catch is CancellationError {
            // Expected.
        }
    }

    private func date(_ value: String) -> Date {
        ISO8601DateFormatter().date(from: value) ?? .distantPast
    }
}
