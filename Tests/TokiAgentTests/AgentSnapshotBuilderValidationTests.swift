import Foundation
import TokiSyncProtocol
import TokiUsageCore
import XCTest
@testable import TokiAgentCore
@testable import TokiUsageReaders

final class AgentSnapshotBuilderValidationTests: XCTestCase {
    func test_snapshotDropsOutOfRangeTokenBucketsWithoutDroppingValidEvents() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("toki-agent-token-validation-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let now = try Self.date("2026-07-16T12:00:00Z")
        let eventDate = now.addingTimeInterval(-60)
        let maximum = RemoteUsageSnapshotValidator.maximumTokenCountPerBucket
        var usage = RawTokenUsage()
        usage.tokenEvents = [
            TokenUsageEvent(
                timestamp: eventDate,
                source: "Custom Reader",
                model: nil,
                inputTokens: maximum + 1,
                outputTokens: 0,
                cacheReadTokens: 0,
                cacheWriteTokens: 0,
                reasoningTokens: 0,
                cost: 0),
            TokenUsageEvent(
                timestamp: eventDate,
                source: "Custom Reader",
                model: nil,
                inputTokens: -1,
                outputTokens: 2,
                cacheReadTokens: 0,
                cacheWriteTokens: 0,
                reasoningTokens: 0,
                cost: 0),
            TokenUsageEvent(
                timestamp: eventDate,
                source: "Custom Reader",
                model: nil,
                inputTokens: 10,
                outputTokens: 5,
                cacheReadTokens: 0,
                cacheWriteTokens: 0,
                reasoningTokens: 0,
                cost: 0),
        ]
        let builder = AgentSnapshotBuilder(
            home: root,
            readerDescriptors: [
                LocalUsageReaderDescriptor(
                    reader: ValidationTokenReader(usage: usage),
                    sourceLocations: []),
            ])
        let configuration = try AgentConfiguration(bundle: AgentPairingBundle(
            hubURL: XCTUnwrap(URL(string: "https://hub.example.test")),
            deviceID: "validation-device",
            deviceName: "validation-device",
            uploadToken: SnapshotCipher.randomToken(),
            encryptionKey: SnapshotCipher.generateKey(),
            retentionDays: 7,
            syncIntervalSeconds: 900))

        let snapshot = try await builder.build(configuration: configuration, now: now)

        XCTAssertEqual(snapshot.tokenEvents.map(\.inputTokens), [10])
        XCTAssertNoThrow(try RemoteUsageSnapshotValidator.validate(snapshot, now: now))
    }

    func test_sourceSignatureIgnoresSymlinkedCodexRollouts() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("toki-agent-codex-symlink-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let archiveDirectory = root.appendingPathComponent(".codex/archived_sessions")
        try FileManager.default.createDirectory(at: archiveDirectory, withIntermediateDirectories: true)
        let targetURL = root.appendingPathComponent("outside-rollout.jsonl")
        let linkURL = archiveDirectory.appendingPathComponent("linked-rollout.jsonl")
        try Data("{\"value\":1}\n".utf8).write(to: targetURL)
        try FileManager.default.createSymbolicLink(at: linkURL, withDestinationURL: targetURL)
        let builder = AgentSnapshotBuilder(home: root)
        let configuration = try AgentConfiguration(bundle: AgentPairingBundle(
            hubURL: XCTUnwrap(URL(string: "https://hub.example.test")),
            deviceID: "validation-device",
            deviceName: "validation-device",
            uploadToken: SnapshotCipher.randomToken(),
            encryptionKey: SnapshotCipher.generateKey(),
            retentionDays: 7,
            syncIntervalSeconds: 900))
        let now = try Self.date("2026-07-16T12:00:00Z")

        let before = try await builder.sourceSignature(configuration: configuration, now: now)
        try Data("{\"value\":2}\n".utf8).write(to: targetURL)
        let after = try await builder.sourceSignature(configuration: configuration, now: now)

        XCTAssertEqual(before, after)
    }

    func test_snapshotDropsUnsafeModelFieldsWithoutDroppingEvents() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("toki-agent-validation-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let now = try Self.date("2026-07-16T12:00:00Z")
        let eventDate = now.addingTimeInterval(-60)
        var usage = RawTokenUsage()
        usage.recordTokenEvent(
            timestamp: eventDate,
            source: "Custom Reader",
            model: String(repeating: "m", count: RemoteUsageSnapshotValidator.maximumModelLength + 1),
            inputTokens: 10,
            outputTokens: 5)
        usage.activityEvents = [
            ActivityTimeEvent(
                streamID: "unsafe-model-stream",
                timestamp: eventDate,
                key: "unsafe\nmodel"),
        ]
        let builder = AgentSnapshotBuilder(
            home: root,
            readerDescriptors: [
                LocalUsageReaderDescriptor(
                    reader: ValidationTokenReader(usage: usage),
                    sourceLocations: []),
            ])
        let configuration = try AgentConfiguration(bundle: AgentPairingBundle(
            hubURL: XCTUnwrap(URL(string: "https://hub.example.test")),
            deviceID: "validation-device",
            deviceName: "validation-device",
            uploadToken: SnapshotCipher.randomToken(),
            encryptionKey: SnapshotCipher.generateKey(),
            retentionDays: 7,
            syncIntervalSeconds: 900))

        let snapshot = try await builder.build(configuration: configuration, now: now)

        XCTAssertEqual(snapshot.tokenEvents.count, 1)
        XCTAssertEqual(snapshot.activityEvents.count, 1)
        XCTAssertNil(snapshot.tokenEvents.first?.model)
        XCTAssertNil(snapshot.activityEvents.first?.model)
        XCTAssertNoThrow(try RemoteUsageSnapshotValidator.validate(snapshot, now: now))
    }

    private static func date(_ value: String) throws -> Date {
        try XCTUnwrap(ISO8601DateFormatter().date(from: value))
    }
}

private struct ValidationTokenReader: TokenReader {
    let name = "Custom Reader"
    let usage: RawTokenUsage

    func readUsage(from _: Date, to _: Date) async throws -> RawTokenUsage {
        usage
    }
}
