import Foundation
import TokiUsageCore
import XCTest
@testable import TokiUsageReaders

final class HermesDelegateFailureTests: XCTestCase {
    func testUnreadableWorkerPreservesNativeAndValidDelegatedUsageAndRecovers() async throws {
        for name in ["Codex", "Claude Code"] {
            let fixture = try DelegateUsageFixture()
            defer { fixture.remove() }
            try writeUsage(fixture, name: name)
            let broken = "broken/events.jsonl"
            try fixture.writeCodex(broken, session: "native")
            try Data([0xFF, 0x0A]).write(to: fixture.delegates.appendingPathComponent(broken))
            let reader = try fixture.reader(name)
            for _ in 0..<2 {
                let usage = try await reader.readUsage(from: fixture.start, to: fixture.end)
                try assertPartialUsage(usage, name: name)
            }
            try fixture.writeCodex(broken, session: "repaired")
            let repaired = try await reader.readUsage(from: fixture.start, to: fixture.end)
            XCTAssertEqual(repaired.totalTokens, name == "Codex" ? 252 : 162)
            XCTAssertTrue(repaired.supplemental.isEmpty)
        }
    }

    func testUnsafeWorkerMetadataIsIsolatedFromOtherUsage() async throws {
        for marker in ["meta.json", "status.json", "ended_at", "symlink", "directory"] {
            let fixture = try DelegateUsageFixture()
            defer { fixture.remove() }
            try writeUsage(fixture, name: "Codex")
            try fixture.writeCodex("broken/events.jsonl", session: "native")
            let directory = fixture.delegates.appendingPathComponent("broken")
            switch marker {
            case "symlink", "directory":
                let ended = directory.appendingPathComponent("ended_at")
                try FileManager.default.removeItem(at: ended)
                if marker == "symlink" {
                    try FileManager.default.createSymbolicLink(
                        at: ended, withDestinationURL: directory.appendingPathComponent("meta.json"))
                } else {
                    try FileManager.default.createDirectory(at: ended, withIntermediateDirectories: false)
                }
            default:
                let bytes = marker == "ended_at" ? 128 : 1024 * 1024 + 1
                try Data(repeating: 0x20, count: bytes).write(to: directory.appendingPathComponent(marker))
            }
            let usage = try await fixture.reader("Codex").readUsage(from: fixture.start, to: fixture.end)
            try assertPartialUsage(usage, name: "Codex")
        }
    }

    func testSourceCancellationStillPropagates() async throws {
        let fixture = try DelegateUsageFixture()
        defer { fixture.remove() }
        try fixture.writeCodex("run/events.jsonl", session: "worker")
        let source = HermesDelegateUsageSource(root: fixture.delegates, provider: .codex)
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await source.read()
        }
        do {
            _ = try await task.value
            XCTFail("Cancellation must not become a partial usage result.")
        } catch is CancellationError {}
    }

    func testGlobalEventLimitStillFailsInsteadOfReturningPartialUsage() async throws {
        let fixture = try DelegateUsageFixture()
        defer { fixture.remove() }
        try fixture.writeCodex("first/events.jsonl", session: "first")
        try fixture.writeCodex("second/events.jsonl", session: "second")
        let limits = PiCompatibleReadLimits(
            maximumFileCount: 2, maximumFileBytes: 1024, maximumLineBytes: 1024,
            maximumEventCount: 1, maximumEntryCount: 100)
        do {
            _ = try await HermesDelegateUsageSource(root: fixture.delegates, provider: .codex).read(limits: limits)
            XCTFail("A global event bound must not be swallowed as an unreadable log.")
        } catch is HermesDelegateReadError {}
    }

    private func writeUsage(_ fixture: DelegateUsageFixture, name: String) throws {
        if name == "Codex" {
            try fixture.writeNativeCodex(session: "native")
            try fixture.writeCodex("valid/events.jsonl", session: "worker")
        } else {
            try fixture.writeNativeClaude(session: "native")
            try fixture.writeClaude("valid/claude.out", session: "worker", completed: true)
        }
    }

    private func assertPartialUsage(_ usage: RawTokenUsage, name: String) throws {
        let expected = name == "Codex" ? 132 : 162
        XCTAssertEqual(usage.totalTokens, expected)
        XCTAssertEqual(usage.tokenEvents.reduce(0) { $0 + $1.totalTokens }, expected)
        XCTAssertEqual(usage.perModel.values.reduce(0) { $0 + $1.totalTokens }, expected)
        let diagnostic = try XCTUnwrap(usage.supplemental.first)
        XCTAssertEqual(usage.supplemental.count, 1)
        XCTAssertEqual(diagnostic.label, "Delegated logs that could not be read")
        XCTAssertEqual(diagnostic.value, 1)
        XCTAssertEqual(diagnostic.source, name)
        XCTAssertEqual(diagnostic.quality, .contextOnly)
        XCTAssertFalse(diagnostic.includedInTotals)
    }
}
