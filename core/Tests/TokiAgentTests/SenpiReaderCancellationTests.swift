import Foundation
import TokiUsageCore
import XCTest
@testable import TokiUsageReaders

final class SenpiReaderCancellationTests: XCTestCase {
    func test_cancelledReadStopsBeforeSessionDiscovery() async {
        let missingRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let reader = SenpiReader(sessionRootsOverride: [missingRoot])
        let task = Task { () throws -> RawTokenUsage in
            withUnsafeCurrentTask { currentTask in
                currentTask?.cancel()
            }
            return try await reader.readUsage(
                from: Date(timeIntervalSince1970: 0),
                to: Date())
        }

        do {
            _ = try await task.value
            XCTFail("Expected cancellation before session discovery")
        } catch is CancellationError {
            // Expected.
        } catch {
            XCTFail("Expected CancellationError, received \(error)")
        }
    }

    func test_discoveryChecksCancellationAfterTraversalBegins() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("toki-senpi-cancellation-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        for index in 0..<3 {
            try Data("{}\n".utf8).write(
                to: root.appendingPathComponent("session-\(index).jsonl"))
        }
        var checkpointCount = 0

        XCTAssertThrowsError(try findFiles(
            in: root,
            withExtension: "jsonl",
            cancellationCheck: {
                checkpointCount += 1
                if checkpointCount == 2 {
                    throw CancellationError()
                }
            })) { error in
                guard error is CancellationError else {
                    return XCTFail("Expected CancellationError, received \(error)")
                }
            }
        XCTAssertEqual(checkpointCount, 2)
    }
}
