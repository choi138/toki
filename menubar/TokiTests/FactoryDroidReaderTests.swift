import Foundation
import TokiUsageCore
import XCTest
@testable import TokiUsageReaders

final class FactoryDroidReaderTests: XCTestCase {
    func test_currentSettingsSummaryMapsUsageAndAttribution() async throws {
        let fixture = try FactoryDroidFixture()
        defer { fixture.remove() }
        let settings = try fixture.writeSession(
            id: "droid-session-a",
            model: "custom:Claude-Opus-4.5-Thinking-[Anthropic]-0",
            provider: "anthropic",
            tokenUsage: [
                "inputTokens": 120,
                "outputTokens": 30,
                "cacheReadTokens": 40,
                "cacheCreationTokens": 10,
                "thinkingTokens": 7,
            ],
            transcriptLines: [
                #"{"type":"session_start","id":"droid-session-a","cwd":"/Users/example/Toki"}"#,
                #"{"type":"message","id":"assistant-a","timestamp":"2026-08-20T12:00:00Z","# +
                    #""message":{"role":"assistant"}}"#,
            ])
        try fixture.setModificationDate("2026-08-20T12:05:00Z", for: settings)

        let usage = try await fixture.reader.readUsage(
            from: fixture.date("2026-08-20T00:00:00Z"),
            to: fixture.date("2026-08-21T00:00:00Z"))

        XCTAssertEqual(usage.inputTokens, 120)
        XCTAssertEqual(usage.outputTokens, 30)
        XCTAssertEqual(usage.cacheReadTokens, 40)
        XCTAssertEqual(usage.cacheWriteTokens, 10)
        XCTAssertEqual(usage.reasoningTokens, 7)
        XCTAssertEqual(usage.totalTokens, 207)
        XCTAssertEqual(usage.cost, 0)
        XCTAssertEqual(usage.tokenEvents.count, 1)
        XCTAssertEqual(usage.tokenEvents.first?.source, "Factory Droid")
        XCTAssertEqual(
            usage.tokenEvents.first?.model,
            "custom:Claude-Opus-4.5-Thinking-[Anthropic]-0")
        XCTAssertEqual(usage.tokenEvents.first?.provider, "anthropic")
        XCTAssertEqual(usage.tokenEvents.first?.costIsKnown, false)
        XCTAssertEqual(usage.tokenEvents.first?.attribution?.sessionID, "droid-session-a")
        XCTAssertEqual(usage.tokenEvents.first?.attribution?.projectPath, "/Users/example/Toki")
        XCTAssertEqual(usage.tokenEvents.first?.attribution?.projectName, "Toki")
        XCTAssertEqual(usage.tokenEvents.first?.attribution?.quality, .exact)
        XCTAssertEqual(usage.perModel.keys.sorted(), [
            "custom:Claude-Opus-4.5-Thinking-[Anthropic]-0",
        ])
        XCTAssertEqual(usage.perModel.values.first?.sources, ["Factory Droid"])
    }

    func test_transcriptUsageAndDuplicateAssistantRecordsDoNotDoubleCountSummary() async throws {
        let fixture = try FactoryDroidFixture()
        defer { fixture.remove() }
        let settings = try fixture.writeSession(
            id: "droid-session-dedup",
            model: "claude-sonnet-4-6",
            provider: nil,
            tokenUsage: [
                "inputTokens": 100,
                "outputTokens": 20,
            ],
            transcriptLines: [
                #"{"type":"session_start","id":"droid-session-dedup","cwd":"/tmp/project"}"#,
                #"{"type":"message","id":"assistant-1","timestamp":"2026-08-20T10:00:00Z","# +
                    #""message":{"role":"assistant","usage":{"inputTokens":100,"outputTokens":20}}}"#,
                #"{"type":"message","id":"assistant-1","timestamp":"2026-08-20T10:00:00Z","# +
                    #""message":{"role":"assistant","usage":{"inputTokens":100,"outputTokens":20}}}"#,
            ])
        try fixture.setModificationDate("2026-08-20T10:01:00Z", for: settings)

        let usage = try await fixture.reader.readUsage(
            from: fixture.date("2026-08-20T00:00:00Z"),
            to: fixture.date("2026-08-21T00:00:00Z"))

        XCTAssertEqual(usage.totalTokens, 120)
        XCTAssertEqual(usage.tokenEvents.count, 1)
        XCTAssertEqual(usage.activityEvents.count, 1)
        XCTAssertEqual(usage.tokenEvents.first?.provider, "anthropic")
    }

    func test_malformedMiddleAndTruncatedTrailingTranscriptRecordsAreIgnored() async throws {
        let fixture = try FactoryDroidFixture()
        defer { fixture.remove() }
        let settings = try fixture.writeSession(
            id: "droid-session-malformed",
            model: "gpt-5.4",
            provider: "openai",
            tokenUsage: [
                "inputTokens": 80,
                "outputTokens": 10,
            ],
            transcriptLines: [
                #"{"type":"session_start","id":"droid-session-malformed","# +
                    #""cwd":"/tmp/workspace"}"#,
                #"{"type":"message","id":"assistant-valid","timestamp":"2026-08-20T09:00:00Z","# +
                    #""message":{"role":"assistant"}}"#,
                "{malformed",
                #"{"type":"message","id":"assistant-truncated","timestamp":"2026-08-20T09:05:00Z""#,
            ])
        try fixture.setModificationDate("2026-08-20T09:06:00Z", for: settings)

        let usage = try await fixture.reader.readUsage(
            from: fixture.date("2026-08-20T00:00:00Z"),
            to: fixture.date("2026-08-21T00:00:00Z"))

        XCTAssertEqual(usage.totalTokens, 90)
        XCTAssertEqual(usage.activityEvents.count, 1)
        XCTAssertEqual(usage.tokenEvents.first?.attribution?.projectPath, "/tmp/workspace")
    }

    func test_malformedOptionalSettingsMetadataDoesNotDropValidUsage() async throws {
        let fixture = try FactoryDroidFixture()
        defer { fixture.remove() }
        let settingsURL = fixture.root.appendingPathComponent("lossy.settings.json")
        try JSONSerialization.data(withJSONObject: [
            "model": ["unexpected": true],
            "providerLock": 42,
            "tokenUsage": [
                "inputTokens": 12,
                "outputTokens": 3,
            ],
        ])
        .write(to: settingsURL)
        try fixture.setModificationDate("2026-08-20T08:00:00Z", for: settingsURL)

        let usage = try await fixture.reader.readUsage(
            from: fixture.date("2026-08-20T00:00:00Z"),
            to: fixture.date("2026-08-21T00:00:00Z"))

        XCTAssertEqual(usage.totalTokens, 15)
        XCTAssertNil(usage.tokenEvents.first?.model)
        XCTAssertNil(usage.tokenEvents.first?.provider)
    }

    func test_malformedOptionalTokenCounterDoesNotDropValidUsage() async throws {
        let fixture = try FactoryDroidFixture()
        defer { fixture.remove() }
        let settingsURL = fixture.root.appendingPathComponent("lossy-counter.settings.json")
        try JSONSerialization.data(withJSONObject: [
            "model": "gpt-5.4",
            "tokenUsage": [
                "inputTokens": 12,
                "outputTokens": 3,
                "thinkingTokens": "not-a-number",
            ],
        ])
        .write(to: settingsURL)
        try fixture.setModificationDate("2026-08-20T08:00:00Z", for: settingsURL)

        let usage = try await fixture.reader.readUsage(
            from: fixture.date("2026-08-20T00:00:00Z"),
            to: fixture.date("2026-08-21T00:00:00Z"))

        XCTAssertEqual(usage.totalTokens, 15)
        XCTAssertEqual(usage.tokenEvents.count, 1)
    }

    func test_dateRangeIsStartInclusiveAndEndExclusive() async throws {
        let fixture = try FactoryDroidFixture()
        defer { fixture.remove() }
        let start = fixture.date("2026-08-20T00:00:00Z")
        let end = fixture.date("2026-08-21T00:00:00Z")
        let atStart = try fixture.writeSession(
            id: "at-start",
            model: "gpt-5.4",
            provider: "openai",
            tokenUsage: ["inputTokens": 10])
        let atEnd = try fixture.writeSession(
            id: "at-end",
            model: "gpt-5.4",
            provider: "openai",
            tokenUsage: ["inputTokens": 100])
        try FileManager.default.setAttributes([.modificationDate: start], ofItemAtPath: atStart.path)
        try FileManager.default.setAttributes([.modificationDate: end], ofItemAtPath: atEnd.path)

        let usage = try await fixture.reader.readUsage(from: start, to: end)

        XCTAssertEqual(usage.inputTokens, 10)
        XCTAssertEqual(usage.tokenEvents.map(\.attribution?.sessionID), ["at-start"])
    }

    func test_missingModelAndWorkspaceKeepTokenUsage() async throws {
        let fixture = try FactoryDroidFixture()
        defer { fixture.remove() }
        let settingsURL = fixture.root.appendingPathComponent("unattributed.settings.json")
        try JSONSerialization.data(withJSONObject: [
            "tokenUsage": [
                "inputTokens": 12,
                "outputTokens": 3,
            ],
        ])
        .write(to: settingsURL)
        try fixture.setModificationDate("2026-08-20T08:00:00Z", for: settingsURL)

        let usage = try await fixture.reader.readUsage(
            from: fixture.date("2026-08-20T00:00:00Z"),
            to: fixture.date("2026-08-21T00:00:00Z"))

        XCTAssertEqual(usage.totalTokens, 15)
        XCTAssertNil(usage.tokenEvents.first?.model)
        XCTAssertNil(usage.tokenEvents.first?.attribution?.projectPath)
        XCTAssertEqual(usage.tokenEvents.first?.attribution?.sessionID, "unattributed")
    }

    func test_rootOverrideSkipsCanonicalDuplicateSymlink() async throws {
        let fixture = try FactoryDroidFixture()
        defer { fixture.remove() }
        let settings = try fixture.writeSession(
            id: "canonical",
            model: "gpt-5.4",
            provider: "openai",
            tokenUsage: ["inputTokens": 25])
        try fixture.setModificationDate("2026-08-20T08:00:00Z", for: settings)
        let duplicate = fixture.root.appendingPathComponent("duplicate.settings.json")
        try FileManager.default.createSymbolicLink(at: duplicate, withDestinationURL: settings)

        let usage = try await fixture.reader.readUsage(
            from: fixture.date("2026-08-20T00:00:00Z"),
            to: fixture.date("2026-08-21T00:00:00Z"))

        XCTAssertEqual(usage.inputTokens, 25)
        XCTAssertEqual(usage.tokenEvents.count, 1)
    }
}

extension FactoryDroidReaderTests {
    func test_logicalSessionChoosesRepresentativeBeforeDateFiltering() async throws {
        let fixture = try FactoryDroidFixture()
        defer { fixture.remove() }
        let original = try fixture.writeSession(
            id: "representative",
            model: "gpt-5.4",
            provider: "openai",
            tokenUsage: ["inputTokens": 10],
            transcriptLines: [
                #"{"type":"session_start","id":"logical-session","cwd":"/tmp/project"}"#,
            ])
        try fixture.setModificationDate("2026-08-20T11:00:00Z", for: original)
        let copiedRoot = fixture.root.appendingPathComponent("copy")
        try FileManager.default.createDirectory(at: copiedRoot, withIntermediateDirectories: true)
        let copiedSettings = copiedRoot.appendingPathComponent(original.lastPathComponent)
        try FileManager.default.copyItem(at: original, to: copiedSettings)
        try FileManager.default.copyItem(
            at: fixture.root.appendingPathComponent("representative.jsonl"),
            to: copiedRoot.appendingPathComponent("representative.jsonl"))
        try fixture.setModificationDate("2026-08-21T11:00:00Z", for: copiedSettings)

        let firstDay = try await fixture.reader.readUsage(
            from: fixture.date("2026-08-20T00:00:00Z"),
            to: fixture.date("2026-08-21T00:00:00Z"))
        let secondDay = try await fixture.reader.readUsage(
            from: fixture.date("2026-08-21T00:00:00Z"),
            to: fixture.date("2026-08-22T00:00:00Z"))

        XCTAssertEqual(firstDay.totalTokens, 0)
        XCTAssertTrue(firstDay.tokenEvents.isEmpty)
        XCTAssertEqual(secondDay.totalTokens, 10)
        XCTAssertEqual(secondDay.tokenEvents.count, 1)
    }

    func test_copiedPhysicalSessionFilesAreDeduplicatedByLogicalIDs() async throws {
        let fixture = try FactoryDroidFixture()
        defer { fixture.remove() }
        let settings = try fixture.writeSession(
            id: "copied-session",
            model: "gpt-5.4",
            provider: "openai",
            tokenUsage: ["inputTokens": 10],
            transcriptLines: [
                #"{"type":"session_start","id":"logical-session","cwd":"/tmp/project"}"#,
                #"{"type":"message","id":"assistant-1","timestamp":"2026-08-20T11:00:00Z","# +
                    #""message":{"role":"assistant"}}"#,
            ])
        try fixture.setModificationDate("2026-08-20T11:01:00Z", for: settings)
        let copiedRoot = fixture.root.appendingPathComponent("copy")
        try FileManager.default.createDirectory(at: copiedRoot, withIntermediateDirectories: true)
        let copiedSettings = copiedRoot.appendingPathComponent(settings.lastPathComponent)
        try FileManager.default.copyItem(at: settings, to: copiedSettings)
        try FileManager.default.copyItem(
            at: fixture.root.appendingPathComponent("copied-session.jsonl"),
            to: copiedRoot.appendingPathComponent("copied-session.jsonl"))

        let usage = try await fixture.reader.readUsage(
            from: fixture.date("2026-08-20T00:00:00Z"),
            to: fixture.date("2026-08-21T00:00:00Z"))

        XCTAssertEqual(usage.totalTokens, 10)
        XCTAssertEqual(usage.tokenEvents.count, 1)
        XCTAssertEqual(usage.activityEvents.count, 1)
    }

    func test_transcriptActivityUsesItsOwnTimestampWhenSettingsChangeLater() async throws {
        let fixture = try FactoryDroidFixture()
        defer { fixture.remove() }
        let settings = try fixture.writeSession(
            id: "later-settings",
            model: "gpt-5.4",
            provider: "openai",
            tokenUsage: ["inputTokens": 10],
            transcriptLines: [
                #"{"type":"session_start","id":"later-settings","cwd":"/tmp/project"}"#,
                #"{"type":"message","id":"assistant-in-range","timestamp":"2026-08-20T23:59:00Z","# +
                    #""message":{"role":"assistant"}}"#,
            ])
        try fixture.setModificationDate("2026-08-21T00:01:00Z", for: settings)

        let usage = try await fixture.reader.readUsage(
            from: fixture.date("2026-08-20T00:00:00Z"),
            to: fixture.date("2026-08-21T00:00:00Z"))

        XCTAssertEqual(usage.totalTokens, 0)
        XCTAssertTrue(usage.tokenEvents.isEmpty)
        XCTAssertEqual(usage.activityEvents.count, 1)
        XCTAssertEqual(
            usage.activityEvents.first?.timestamp,
            fixture.date("2026-08-20T23:59:00Z"))
    }
}

private struct FactoryDroidFixture {
    let root: URL

    init() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("toki-droid-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    var reader: FactoryDroidReader {
        FactoryDroidReader(sessionsURLOverride: root)
    }

    func writeSession(
        id: String,
        model: String,
        provider: String?,
        tokenUsage: [String: Int],
        transcriptLines: [String] = []) throws -> URL {
        var settings: [String: Any] = [
            "model": model,
            "tokenUsage": tokenUsage,
        ]
        if let provider {
            settings["providerLock"] = provider
        }
        let settingsURL = root.appendingPathComponent("\(id).settings.json")
        let data = try JSONSerialization.data(withJSONObject: settings, options: [.sortedKeys])
        try data.write(to: settingsURL)
        if !transcriptLines.isEmpty {
            try Data((transcriptLines.joined(separator: "\n") + "\n").utf8)
                .write(to: root.appendingPathComponent("\(id).jsonl"))
        }
        return settingsURL
    }

    func setModificationDate(_ value: String, for url: URL) throws {
        try FileManager.default.setAttributes(
            [.modificationDate: date(value)],
            ofItemAtPath: url.path)
    }

    func date(_ value: String) -> Date {
        ISO8601DateFormatter().date(from: value)!
    }

    func remove() {
        try? FileManager.default.removeItem(at: root)
    }
}
