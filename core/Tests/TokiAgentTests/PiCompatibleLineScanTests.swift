import Foundation
import XCTest
@testable import TokiUsageReaders

final class PiCompatibleLineScanTests: XCTestCase {
    private var url: URL!
    private let limits = PiCompatibleReadLimits(
        maximumFileCount: 10,
        maximumFileBytes: 16 * 1024 * 1024,
        maximumLineBytes: 512 * 1024,
        maximumEventCount: 100)

    override func setUpWithError() throws {
        url = FileManager.default.temporaryDirectory
            .appendingPathComponent("pi-line-scan-\(UUID().uuidString).jsonl")
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: url)
        super.tearDown()
    }

    func test_linesSpanningChunkBoundariesKeepOrderAndIndexes() throws {
        let lines = [
            String(repeating: "a", count: 10),
            String(repeating: "b", count: 64 * 1024 - 1),
            String(repeating: "c", count: 64 * 1024),
            String(repeating: "d", count: 200_000),
            "e",
        ]
        try write(lines.joined(separator: "\n") + "\n")

        XCTAssertEqual(try collect(), lines.enumerated().map { Line(text: $1, index: $0) })
    }

    func test_crlfBlankLinesAndMissingTrailingNewline() throws {
        try write("one\r\n\r\n   \ntwo\nthree")

        XCTAssertEqual(
            try collect(),
            [Line(text: "one", index: 0), Line(text: "two", index: 3), Line(text: "three", index: 4)])
    }

    func test_manyShortLinesInOneChunk() throws {
        let lines = (0..<5000).map { "line-\($0)" }
        try write(lines.joined(separator: "\n") + "\n")

        let result = try collect()
        XCTAssertEqual(result.count, 5000)
        XCTAssertEqual(result.map(\.text), lines)
        XCTAssertEqual(result.map(\.index), Array(0..<5000))
    }

    func test_lineOverLimitThrowsWithOrWithoutNewline() throws {
        let tooLong = String(repeating: "x", count: limits.maximumLineBytes + 1)
        for content in ["ok\n" + tooLong + "\n", "ok\n" + tooLong] {
            try write(content)
            XCTAssertThrowsError(try collect()) { error in
                guard case PiCompatibleReaderError.lineTooLong = error else {
                    return XCTFail("unexpected \(error)")
                }
            }
        }
    }

    func test_lineAtExactLimitIsAccepted() throws {
        let exact = String(repeating: "y", count: limits.maximumLineBytes)
        try write(exact + "\nnext\n")

        XCTAssertEqual(try collect().map(\.text), [exact, "next"])
    }

    private struct Line: Equatable {
        let text: String
        let index: Int
    }

    private func write(_ content: String) throws {
        try Data(content.utf8).write(to: url)
    }

    private func collect() throws -> [Line] {
        var result: [Line] = []
        try forEachBoundedJSONLLine(at: url, limits: limits) { text, index in
            result.append(Line(text: text, index: index))
        }
        return result
    }
}
