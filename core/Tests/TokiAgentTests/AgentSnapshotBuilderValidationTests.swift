import Foundation
import TokiSyncProtocol
import TokiUsageCore
import XCTest
@testable import TokiAgentCore
@testable import TokiUsageReaders

final class AgentSnapshotBuilderValidationTests: XCTestCase {
    func test_futureEventsAreDeferredAndIncludedWhenTheirTimestampArrives() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("toki-agent-deferred-event-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let now = try Self.date("2026-07-16T12:00:00Z")
        let future = now.addingTimeInterval(60)
        var usage = RawTokenUsage()
        usage.recordTokenEvent(
            timestamp: future,
            source: "Custom Reader",
            model: "gpt-5",
            inputTokens: 10,
            outputTokens: 5)
        usage.activityEvents = [ActivityTimeEvent(
            streamID: "future-stream",
            timestamp: future,
            key: "gpt-5")]
        let deferredEventRecheck = AgentDeferredEventRecheck()
        let builder = AgentSnapshotBuilder(
            home: root,
            readerDescriptors: [LocalUsageReaderDescriptor(
                reader: ValidationTokenReader(usage: usage),
                sourceLocations: [])],
            deferredEventRecheck: deferredEventRecheck)
        let configuration = try AgentConfiguration(bundle: AgentPairingBundle(
            hubURL: XCTUnwrap(URL(string: "https://hub.example.test")),
            deviceID: "validation-device",
            deviceName: "validation-device",
            uploadToken: SnapshotCipher.randomToken(),
            encryptionKey: SnapshotCipher.generateKey(),
            retentionDays: 7,
            syncIntervalSeconds: 900))
        let initialSignature = try await builder.sourceSignature(
            configuration: configuration,
            now: now)

        let deferredSnapshot = try await builder.build(configuration: configuration, now: now)
        let deferredSignature = try await builder.sourceSignature(
            configuration: configuration,
            now: now)
        let maturedSnapshot = try await builder.build(configuration: configuration, now: future)
        let maturedSignature = try await builder.sourceSignature(
            configuration: configuration,
            now: future)

        XCTAssertTrue(deferredSnapshot.tokenEvents.isEmpty)
        XCTAssertTrue(deferredSnapshot.activityEvents.isEmpty)
        XCTAssertNotEqual(initialSignature, deferredSignature)
        XCTAssertEqual(maturedSnapshot.tokenEvents.count, 1)
        XCTAssertEqual(maturedSnapshot.activityEvents.count, 1)
        XCTAssertEqual(initialSignature, maturedSignature)
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
        try Data("{\"value\":2}\n{\"value\":3}\n".utf8).write(to: targetURL)
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
