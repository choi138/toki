import Foundation
import TokiUsageCore
import XCTest
@testable import TokiAgentCore
@testable import TokiUsageReaders

final class AgentPiFamilySourceSignatureTests: XCTestCase {
    func test_boundedAllFilesRejectsFirstFileBeyondReaderLimit() async throws {
        let fixture = try AgentSnapshotFixture()
        defer { fixture.remove() }
        let sessions = fixture.root.appendingPathComponent("pi-sessions")
        try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
        try Data("{}\n".utf8).write(to: sessions.appendingPathComponent("first.jsonl"))
        try Data("{}\n".utf8).write(to: sessions.appendingPathComponent("second.jsonl"))
        let builder = AgentSnapshotBuilder(
            home: fixture.root,
            environment: [:],
            readerDescriptors: [descriptor(sessions: sessions, maximumFileCount: 1)])

        do {
            _ = try await builder.sourceSignature(
                configuration: fixture.configuration,
                now: fixture.now)
            XCTFail("Expected the second source file to exceed the signature limit")
        } catch {
            guard case .sourceInspectionFailed? = error as? AgentSnapshotBuilderError else {
                return XCTFail("Expected sourceInspectionFailed, got \(error)")
            }
        }
    }

    func test_sourceSignaturePropagatesPreexistingCancellation() async throws {
        let fixture = try AgentSnapshotFixture()
        defer { fixture.remove() }
        let sessions = fixture.root.appendingPathComponent("pi-sessions")
        let builder = AgentSnapshotBuilder(
            home: fixture.root,
            environment: [:],
            readerDescriptors: [descriptor(sessions: sessions, maximumFileCount: 1)])
        let task = Task { () throws -> String? in
            withUnsafeCurrentTask { $0?.cancel() }
            return try await builder.sourceSignature(
                configuration: fixture.configuration,
                now: fixture.now)
        }

        do {
            _ = try await task.value
            XCTFail("Expected cancellation to propagate")
        } catch is CancellationError {
            // Expected.
        } catch {
            XCTFail("Expected CancellationError, got \(error)")
        }
    }

    private func descriptor(
        sessions: URL,
        maximumFileCount: Int) -> LocalUsageReaderDescriptor {
        LocalUsageReaderDescriptor(
            reader: FixedTokenReader(name: PiReader.sourceName, usage: RawTokenUsage()),
            sourceLocations: [.directory(sessions, extensions: ["jsonl"])],
            sourceSignatureStrategy: .boundedAllFiles(maximumFileCount: maximumFileCount))
    }
}
