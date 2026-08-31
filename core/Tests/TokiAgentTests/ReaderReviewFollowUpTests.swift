import Foundation
import TokiUsageCore
import XCTest
@testable import TokiUsageReaders

final class ReaderReviewFollowUpTests: XCTestCase {
    func test_ampPreservesRepeatedIdlessEventsWithIdenticalContent() async throws {
        let root = try temporaryDirectory("amp-repeated")
        defer { try? FileManager.default.removeItem(at: root) }
        let usage: [String: Any] = [
            "model": "gpt-5.4",
            "timestamp": "2026-08-20T11:00:00Z",
            "inputTokens": 5,
            "outputTokens": 1,
        ]
        let thread: [String: Any] = [
            "id": "repeated",
            "messages": [
                ["role": "assistant", "usage": usage],
                ["role": "assistant", "usage": usage],
            ],
        ]
        try JSONSerialization.data(withJSONObject: thread)
            .write(to: root.appendingPathComponent("thread.json"))

        let result = try await AmpReader(threadsURLOverride: root).readUsage(
            from: date("2026-08-20T00:00:00Z"),
            to: date("2026-08-21T00:00:00Z"))

        XCTAssertEqual(result.totalTokens, 12)
        XCTAssertEqual(result.tokenEvents.count, 2)
    }

    func test_newReadersDistinguishMissingRootsFromNonDirectories() async throws {
        let root = try temporaryDirectory("reader-discovery")
        defer { try? FileManager.default.removeItem(at: root) }
        let missing = root.appendingPathComponent("missing")
        let file = root.appendingPathComponent("not-a-directory")
        try Data().write(to: file)
        let range = (date("2026-08-20T00:00:00Z"), date("2026-08-21T00:00:00Z"))

        let ampMissing = try await AmpReader(threadsURLOverride: missing)
            .readUsage(from: range.0, to: range.1)
        let droidMissing = try await FactoryDroidReader(sessionsURLOverride: missing)
            .readUsage(from: range.0, to: range.1)
        XCTAssertEqual(ampMissing.totalTokens, 0)
        XCTAssertEqual(droidMissing.totalTokens, 0)

        await XCTAssertThrowsErrorAsync {
            _ = try await AmpReader(threadsURLOverride: file)
                .readUsage(from: range.0, to: range.1)
        }
        await XCTAssertThrowsErrorAsync {
            _ = try await FactoryDroidReader(sessionsURLOverride: file)
                .readUsage(from: range.0, to: range.1)
        }
    }

    func test_throwingDiscoverySkipsHiddenDirectories() throws {
        let root = try temporaryDirectory("hidden-discovery")
        defer { try? FileManager.default.removeItem(at: root) }
        let visible = root.appendingPathComponent("visible.jsonl")
        let hiddenDirectory = root.appendingPathComponent(".hidden")
        try FileManager.default.createDirectory(at: hiddenDirectory, withIntermediateDirectories: true)
        try Data("{}\n".utf8).write(to: visible)
        try Data("{}\n".utf8).write(to: hiddenDirectory.appendingPathComponent("secret.jsonl"))

        XCTAssertEqual(
            try findFilesThrowing(in: root, withExtension: "jsonl").map(\.lastPathComponent),
            ["visible.jsonl"])
    }

    func test_factoryDroidSkipsInvalidUTF8LineWithoutDroppingNeighbors() async throws {
        let root = try temporaryDirectory("droid-invalid-utf8")
        defer { try? FileManager.default.removeItem(at: root) }
        let settings: [String: Any] = ["model": "gpt-5.4", "tokenUsage": [:]]
        try JSONSerialization.data(withJSONObject: settings)
            .write(to: root.appendingPathComponent("session.settings.json"))
        var transcript = Data(#"{"type":"session_start","id":"session","cwd":"/tmp/project"}"#.utf8)
        transcript.append(0x0A)
        transcript.append(contentsOf: [0xFF, 0xFE, 0x0A])
        let validLine = #"{"type":"message","id":"valid","timestamp":"2026-08-20T12:00:00Z","#
            + #""message":{"role":"assistant","usage":{"inputTokens":7}}}"#
        transcript.append(Data(validLine.utf8))
        transcript.append(0x0A)
        try transcript.write(to: root.appendingPathComponent("session.jsonl"))

        let result = try await FactoryDroidReader(sessionsURLOverride: root).readUsage(
            from: date("2026-08-20T00:00:00Z"),
            to: date("2026-08-21T00:00:00Z"))

        XCTAssertEqual(result.inputTokens, 7)
        XCTAssertEqual(result.tokenEvents.count, 1)
        XCTAssertEqual(result.tokenEvents.first?.attribution?.projectPath, "/tmp/project")
    }

    func test_newReadersPropagatePreexistingCancellation() async throws {
        let root = try temporaryDirectory("reader-cancellation")
        defer { try? FileManager.default.removeItem(at: root) }
        let range = (date("2026-08-20T00:00:00Z"), date("2026-08-21T00:00:00Z"))

        let ampTask = Task {
            try await AmpReader(threadsURLOverride: root).readUsage(from: range.0, to: range.1)
        }
        ampTask.cancel()
        await XCTAssertThrowsErrorAsync { _ = try await ampTask.value }

        let droidTask = Task {
            try await FactoryDroidReader(sessionsURLOverride: root).readUsage(from: range.0, to: range.1)
        }
        droidTask.cancel()
        await XCTAssertThrowsErrorAsync { _ = try await droidTask.value }
    }

    func test_senpiEventLimitCountsRevisionsBeforeDeduplication() async throws {
        let root = try temporaryDirectory("senpi-event-limit")
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("session.jsonl")
        let content = [
            #"{"type":"session","id":"session"}"#,
            senpiRevision(input: 1),
            senpiRevision(input: 2),
        ].joined(separator: "\n")
        try Data(content.utf8).write(to: file)
        let reader = SenpiReader(
            sessionRootsOverride: [root],
            readLimits: PiCompatibleReadLimits(
                maximumFileCount: 1,
                maximumFileBytes: 4096,
                maximumLineBytes: 2048,
                maximumEventCount: 1))

        do {
            _ = try await reader.readUsage(
                from: date("2026-08-20T00:00:00Z"),
                to: date("2026-08-21T00:00:00Z"))
            XCTFail("Expected an event-limit error")
        } catch let error as PiCompatibleReaderError {
            XCTAssertEqual(error, .tooManyEvents(2))
        }
    }

    func test_ampRejectsOversizedFilesAndExcessFileCounts() async throws {
        let root = try temporaryDirectory("amp-limits")
        defer { try? FileManager.default.removeItem(at: root) }
        let oversized = root.appendingPathComponent("oversized.json")
        try Data(String(repeating: "x", count: 65).utf8).write(to: oversized)
        let range = (date("2026-08-20T00:00:00Z"), date("2026-08-21T00:00:00Z"))

        await XCTAssertThrowsReaderError(
            .fileTooLarge(oversized.resolvingSymlinksInPath().standardizedFileURL)) {
                _ = try await AmpReader(
                    threadsURLOverride: root,
                    readLimits: limits(fileBytes: 64)).readUsage(from: range.0, to: range.1)
            }

        try Data("{}".utf8).write(to: oversized)
        try Data("{}".utf8).write(to: root.appendingPathComponent("second.json"))
        await XCTAssertThrowsReaderError(.tooManyFiles(2)) {
            _ = try await AmpReader(
                threadsURLOverride: root,
                readLimits: limits(fileCount: 1)).readUsage(from: range.0, to: range.1)
        }
    }

    func test_factoryDroidRejectsOversizedLinesAndExcessEvents() async throws {
        let root = try temporaryDirectory("droid-limits")
        defer { try? FileManager.default.removeItem(at: root) }
        let settings = root.appendingPathComponent("session.settings.json")
        let transcript = root.appendingPathComponent("session.jsonl")
        try Data("{}".utf8).write(to: settings)
        try Data(String(repeating: "x", count: 65).utf8).write(to: transcript)
        let range = (date("2026-08-20T00:00:00Z"), date("2026-08-21T00:00:00Z"))

        await XCTAssertThrowsReaderError(
            .lineTooLong(transcript.resolvingSymlinksInPath().standardizedFileURL)) {
                _ = try await FactoryDroidReader(
                    sessionsURLOverride: root,
                    readLimits: limits(lineBytes: 64)).readUsage(from: range.0, to: range.1)
            }

        let event = #"{"type":"message","timestamp":"2026-08-20T12:00:00Z","#
            + #""message":{"role":"assistant"}}"#
        try Data([event, event].joined(separator: "\n").utf8).write(to: transcript)
        await XCTAssertThrowsReaderError(.tooManyEvents(2)) {
            _ = try await FactoryDroidReader(
                sessionsURLOverride: root,
                readLimits: limits(events: 1)).readUsage(from: range.0, to: range.1)
        }
    }

    private func temporaryDirectory(_ name: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("toki-\(name)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func date(_ value: String) -> Date {
        ISO8601DateFormatter().date(from: value)!
    }

    private func senpiRevision(input: Int) -> String {
        #"{"type":"message","id":"shared","timestamp":"2026-08-20T12:00:00Z","#
            + #""message":{"role":"assistant","model":"gpt-5.6-sol","#
            + #""usage":{"input":\#(input),"output":0}}}"#
    }

    private func limits(
        fileCount: Int = 10,
        fileBytes: Int = 4096,
        lineBytes: Int = 2048,
        events: Int = 10) -> PiCompatibleReadLimits {
        PiCompatibleReadLimits(
            maximumFileCount: fileCount,
            maximumFileBytes: fileBytes,
            maximumLineBytes: lineBytes,
            maximumEventCount: events)
    }
}

private func XCTAssertThrowsErrorAsync(
    _ expression: () async throws -> Void,
    file: StaticString = #filePath,
    line: UInt = #line) async {
    do {
        try await expression()
        XCTFail("Expected an error", file: file, line: line)
    } catch {}
}

private func XCTAssertThrowsReaderError(
    _ expected: PiCompatibleReaderError,
    _ expression: () async throws -> Void,
    file: StaticString = #filePath,
    line: UInt = #line) async {
    do {
        try await expression()
        XCTFail("Expected \(expected)", file: file, line: line)
    } catch {
        XCTAssertEqual(
            (error as? PiCompatibleReaderError)?.errorDescription,
            expected.errorDescription,
            file: file,
            line: line)
    }
}
