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
}
