import Foundation
import TokiSyncProtocol
import TokiUsageCore
import XCTest
@testable import TokiAgentCore
@testable import TokiUsageReaders

final class AgentSnapshotCostCompatibilityTests: XCTestCase {
    func test_snapshotSerializesKnownZeroCostForOlderReceivers() async throws {
        let now = Date(timeIntervalSince1970: 1_784_200_000)
        var usage = RawTokenUsage()
        usage.inputTokens = 30
        usage.recordTokenEvent(
            timestamp: now.addingTimeInterval(-60),
            source: FactoryDroidReader.sourceName,
            model: "known-zero-model",
            inputTokens: 10,
            outputTokens: 0,
            cost: 0,
            costIsKnown: true)
        usage.recordTokenEvent(
            timestamp: now.addingTimeInterval(-30),
            source: CopilotCLIReader.sourceName,
            model: "unknown-cost-model",
            provider: "kimchi-dev",
            inputTokens: 20,
            outputTokens: 0,
            cost: 0,
            costIsKnown: false)
        let descriptor = LocalUsageReaderDescriptor(
            reader: FixedTokenReader(
                name: FactoryDroidReader.sourceName,
                usage: usage),
            sourceLocations: [])
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("toki-known-zero-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let hubURL = try XCTUnwrap(URL(string: "https://hub.example.test"))
        let bundle = AgentPairingBundle(
            hubURL: hubURL,
            deviceID: "known-zero-device",
            deviceName: "build-server",
            uploadToken: SnapshotCipher.randomToken(),
            encryptionKey: SnapshotCipher.generateKey())
        let builder = AgentSnapshotBuilder(
            home: root,
            readerDescriptors: [descriptor])
        let configuration = try AgentConfiguration(bundle: bundle)

        let snapshot = try await builder.build(
            configuration: configuration,
            now: now)
        let knownZero = try XCTUnwrap(
            snapshot.tokenEvents.first { $0.model == "known-zero-model" })
        let unknown = try XCTUnwrap(
            snapshot.tokenEvents.first { $0.model == "unknown-cost-model" })

        XCTAssertEqual(knownZero.cost, 0)
        XCTAssertEqual(knownZero.costIsKnown, true)
        XCTAssertEqual(unknown.cost, 0)
        XCTAssertEqual(unknown.costIsKnown, false)
        XCTAssertEqual(unknown.provider, "kimchi-dev")
    }
}
