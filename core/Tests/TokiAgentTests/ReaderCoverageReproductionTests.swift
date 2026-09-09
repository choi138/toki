import Foundation
import TokiUsageCore
import XCTest
@testable import TokiUsageReaders

/// Controls distinguish a malformed PI fixture from registry ownership or parser regression.
final class ReaderCoverageReproductionTests: XCTestCase {
    func test_sharedPIConfigConservesUsageWhenSessionHeaderExists() async throws {
        let fixture = try OpenCodeFixture()
        defer { fixture.remove() }
        let root = fixture.root.appendingPathComponent("shared")
        let file = root.appendingPathComponent("agent/sessions/session.jsonl")
        let header = #"{"type":"session","id":"fixture-session"}"#
        let event = #"{"type":"message","id":"m1","timestamp":"2026-08-20T12:00:00Z","#
            + #""message":{"role":"assistant","model":"fixture-unpriced","usage":{"input":100,"output":20}}}"#
        XCTAssertNoThrow(try JSONSerialization.jsonObject(with: Data(header.utf8)))
        XCTAssertNoThrow(try JSONSerialization.jsonObject(with: Data(event.utf8)))
        let end = OpenCodeFixture.date.addingTimeInterval(60)
        let headerless = OMPReader.usage(
            fromJSONLLines: [event],
            streamID: file.path,
            from: OpenCodeFixture.date,
            to: end)
        let valid = OMPReader.usage(
            fromJSONLLines: [header, event],
            streamID: file.path,
            from: OpenCodeFixture.date,
            to: end)
        XCTAssertEqual(headerless.totalTokens, 0, "OMP deliberately requires a session header")
        XCTAssertEqual(valid.totalTokens, 120, "Adding only the required header makes parsing succeed")
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data((header + "\n" + event + "\n").utf8).write(to: file)
        let readers = LocalUsageReaderRegistry.readers(home: fixture.root, environment: ["PI_CONFIG_DIR": root.path])
            .filter { [OMPReader.sourceName, GJCReader.sourceName].contains($0.name) }
        XCTAssertEqual(readers.count, 2)
        var totals: [String: Int] = [:]
        for reader in readers {
            totals[reader.name] = try await reader.readUsage(from: OpenCodeFixture.date, to: end).totalTokens
        }
        XCTAssertEqual(totals[OMPReader.sourceName], 120)
        XCTAssertEqual(totals[GJCReader.sourceName], 0)
        XCTAssertEqual(totals.values.reduce(0, +), 120)
    }
}
