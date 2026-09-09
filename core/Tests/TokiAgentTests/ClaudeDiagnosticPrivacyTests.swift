import Foundation
import TokiUsageCore
import XCTest
@testable import TokiUsageReaders

#if os(Linux)
    import Glibc
#else
    import Darwin
#endif

final class ClaudeDiagnosticPrivacyTests: XCTestCase {
    func test_deniedProjectDiscoveryDoesNotExposeEncodedProjectPath() async throws {
        try requirePermissionEnforcement()
        let fixture = try ClaudeDiagnosticFixture()
        defer { fixture.remove() }
        try fixture.write(Data(ClaudeDiagnosticFixture.validRow.utf8))
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: fixture.project.path)
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: fixture.project.path)
        }
        do {
            _ = try await fixture.read()
            XCTFail("Denied discovery must fail")
        } catch {
            assertPrivateDiagnostic(error, fixture: fixture, containing: "could not be read")
        }
    }

    func test_nonDirectorySelectedRootDoesNotExposeEncodedProjectPath() async throws {
        let fixture = try ClaudeDiagnosticFixture()
        defer { fixture.remove() }
        try Data().write(to: fixture.project)
        let reader = fixture.reader(projects: fixture.project)
        do {
            _ = try await reader.readUsage(from: ClaudeDiagnosticFixture.start, to: ClaudeDiagnosticFixture.end)
            XCTFail("A non-directory root must fail")
        } catch {
            assertPrivateDiagnostic(error, fixture: fixture, containing: "could not be read")
        }
    }

    func test_deniedJSONLDoesNotExposeSessionFilename() async throws {
        try requirePermissionEnforcement()
        let fixture = try ClaudeDiagnosticFixture()
        defer { fixture.remove() }
        try fixture.write(Data(ClaudeDiagnosticFixture.validRow.utf8))
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: fixture.file.path)
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fixture.file.path)
        }
        do {
            _ = try await fixture.read()
            XCTFail("An unreadable JSONL file must fail")
        } catch {
            assertPrivateDiagnostic(error, fixture: fixture, containing: "could not be read")
        }
    }

    func test_invalidUTF8FailsWithoutExposingSessionFilename() async throws {
        let fixture = try ClaudeDiagnosticFixture()
        defer { fixture.remove() }
        let bytes = Data([0xFF, 0x0A])
        try fixture.write(bytes)
        do {
            _ = try await fixture.read()
            XCTFail("Invalid UTF-8 must fail")
        } catch {
            assertPrivateDiagnostic(error, fixture: fixture, containing: "invalid UTF-8 at line 1")
        }
        XCTAssertEqual(try Data(contentsOf: fixture.file), bytes)
    }

    func test_oversizedRecordFailsWithoutExposingSessionFilename() async throws {
        let fixture = try ClaudeDiagnosticFixture()
        defer { fixture.remove() }
        let bytes = Data(repeating: 0x78, count: PiCompatibleReadLimits.default.maximumLineBytes + 1)
        try fixture.write(bytes)
        do {
            _ = try await fixture.read()
            XCTFail("An oversized record must fail")
        } catch {
            assertPrivateDiagnostic(error, fixture: fixture, containing: "oversized record")
        }
        XCTAssertEqual(try Data(contentsOf: fixture.file), bytes)
    }

    func test_oversizedFileFailsWithoutExposingSessionFilename() async throws {
        let fixture = try ClaudeDiagnosticFixture()
        defer { fixture.remove() }
        try fixture.write(Data())
        let bytes = UInt64(PiCompatibleReadLimits.default.maximumFileBytes) + 1
        let handle = try FileHandle(forWritingTo: fixture.file)
        try handle.truncate(atOffset: bytes) // Sparse fixture: do not allocate the full file in memory.
        try handle.close()
        do {
            _ = try await fixture.read()
            XCTFail("An oversized file must fail")
        } catch {
            assertPrivateDiagnostic(error, fixture: fixture, containing: "supported size")
        }
        let size = try FileManager.default.attributesOfItem(atPath: fixture.file.path)[.size] as? NSNumber
        XCTAssertEqual(size?.uint64Value, bytes)
    }

    func test_malformedJSONAndUsageRemainFailedAfterValidRows() async throws {
        let fixture = try ClaudeDiagnosticFixture()
        defer { fixture.remove() }
        for malformed in [
            #"{"type":"assistant","synthetic-private-content":"#,
            #"{"type":"assistant","timestamp":"2026-09-08T00:01:00Z","#
                + #""message":{"usage":{"input_tokens":"synthetic-private-content"}}}"#,
        ] {
            try fixture.write(Data((ClaudeDiagnosticFixture.validRow + "\n" + malformed).utf8))
            do {
                _ = try await fixture.read()
                XCTFail("Malformed source data must not produce a partial successful read")
            } catch {
                XCTAssertTrue(error is LocalUsageReaderDiagnosticError)
                assertPrivateDiagnostic(error, fixture: fixture, containing: "decode failed")
                XCTAssertFalse(error.localizedDescription.contains("synthetic-private-content"))
            }
        }
    }

    func test_cancelledReadKeepsCancellationError() async throws {
        let fixture = try ClaudeDiagnosticFixture()
        defer { fixture.remove() }
        try fixture.write(Data(ClaudeDiagnosticFixture.validRow.utf8))
        let reader = fixture.reader()
        let task = Task {
            while !Task.isCancelled {
                await Task.yield()
            }
            return try await reader.readUsage(from: ClaudeDiagnosticFixture.start, to: ClaudeDiagnosticFixture.end)
        }
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("Cancelled reads must preserve cancellation")
        } catch {
            XCTAssertTrue(error is CancellationError)
        }
    }

    func test_healthyAndCachedReadsKeepUsageAfterDiagnosticBoundary() async throws {
        let fixture = try ClaudeDiagnosticFixture()
        defer { fixture.remove() }
        let bytes = Data(ClaudeDiagnosticFixture.validRow.utf8)
        try fixture.write(bytes)
        let reader = fixture.reader()
        for _ in 0..<2 {
            let usage = try await reader.readUsage(from: ClaudeDiagnosticFixture.start, to: ClaudeDiagnosticFixture.end)
            XCTAssertEqual(usage.totalTokens, 15)
            XCTAssertEqual(usage.tokenEvents.count, 1)
        }
        XCTAssertEqual(try Data(contentsOf: fixture.file), bytes)
    }
}

private extension ClaudeDiagnosticPrivacyTests {
    func requirePermissionEnforcement() throws {
        if geteuid() == 0 { throw XCTSkip("Permission regression requires a non-root process") }
    }

    func assertPrivateDiagnostic(
        _ error: Error,
        fixture: ClaudeDiagnosticFixture,
        containing expected: String,
        file: StaticString = #filePath,
        line: UInt = #line) {
        let description = error.localizedDescription
        XCTAssertTrue(description.contains("Claude Code"), file: file, line: line)
        XCTAssertTrue(description.contains(expected), file: file, line: line)
        for privateValue in [
            fixture.root.path,
            fixture.project.lastPathComponent,
            fixture.file.lastPathComponent,
            "synthetic-private-user",
            "synthetic-acquisition-project",
        ] {
            XCTAssertFalse(description.contains(privateValue), file: file, line: line)
        }
    }
}

private struct ClaudeDiagnosticFixture {
    let root: URL
    var projects: URL {
        root.appendingPathComponent(".claude/projects")
    }

    var project: URL {
        projects.appendingPathComponent("-Users-synthetic-private-user-synthetic-acquisition-project")
    }

    var file: URL {
        project.appendingPathComponent("confidential-fixture-session.jsonl")
    }

    static let start = Date(timeIntervalSince1970: 1_788_825_600) // 2026-09-08 00:00 UTC
    static let end = start.addingTimeInterval(86400)
    static let validRow = #"{"type":"assistant","requestId":"fixture","timestamp":"2026-09-08T00:01:00Z","#
        + #""message":{"model":"claude-sonnet-4-20250514","#
        + #""usage":{"input_tokens":10,"output_tokens":2,"cache_read_input_tokens":3}}}"#

    init() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("toki-claude-diagnostic-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: projects, withIntermediateDirectories: true)
    }

    func write(_ data: Data) throws {
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        try data.write(to: file)
    }

    func reader(projects selectedProjects: URL? = nil) -> ClaudeCodeReader {
        ClaudeCodeReader(
            projectsURLOverride: selectedProjects ?? projects,
            usageCache: ClaudeUsageCache(cacheURL: root.appendingPathComponent("cache/claude.json")))
    }

    func read() async throws -> RawTokenUsage {
        try await reader().readUsage(from: Self.start, to: Self.end)
    }

    func remove() {
        try? FileManager.default.removeItem(at: root)
    }
}
