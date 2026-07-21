import Foundation
import XCTest
@testable import TokiSyncProtocol

final class SyncSecurityTests: XCTestCase {
    func test_hubURLRequiresHTTPSExceptForLoopback() throws {
        XCTAssertTrue(try TokiSyncValidation.isAllowedHubURL(XCTUnwrap(URL(string: "https://hub.example.test"))))
        XCTAssertTrue(try TokiSyncValidation.isAllowedHubURL(XCTUnwrap(URL(string: "http://127.0.0.1:8080"))))
        XCTAssertFalse(try TokiSyncValidation.isAllowedHubURL(XCTUnwrap(URL(string: "http://hub.example.test"))))
        XCTAssertFalse(try TokiSyncValidation.isAllowedHubURL(XCTUnwrap(URL(string: "https://user@hub.example.test"))))
        XCTAssertFalse(try TokiSyncValidation.isAllowedHubURL(XCTUnwrap(URL(string: "https://hub.example.test?q=1"))))
        XCTAssertFalse(try TokiSyncValidation.isAllowedHubURL(XCTUnwrap(URL(string: "https://hub.example.test:0"))))
        XCTAssertFalse(try TokiSyncValidation.isAllowedHubURL(XCTUnwrap(URL(string: "https://hub.example.test:65536"))))
    }

    func test_hubURLRejectsOversizedHost() throws {
        let oversizedHost = String(repeating: "a", count: TokiSyncLimits.maximumHubHostBytes + 1)
        let url = try XCTUnwrap(URL(string: "https://\(oversizedHost)"))

        XCTAssertFalse(TokiSyncValidation.isAllowedHubURL(url))
    }

    func test_credentialsRejectWhitespaceAndUnboundedValues() {
        XCTAssertTrue(TokiSyncValidation.isSafeCredential(String(repeating: "a", count: 32)))
        XCTAssertFalse(TokiSyncValidation.isSafeCredential(String(repeating: "a", count: 31)))
        XCTAssertFalse(TokiSyncValidation.isSafeCredential(String(repeating: " ", count: 32)))
        XCTAssertFalse(TokiSyncValidation.isSafeCredential(String(repeating: "🔑", count: 8)))
        XCTAssertFalse(TokiSyncValidation.isSafeCredential(String(repeating: "a", count: 513)))
    }

    func test_pairingBundleDecoderRejectsOversizedInput() {
        let oversized = String(repeating: "a", count: TokiSyncLimits.maximumPairingBundleBytes + 1)
        XCTAssertThrowsError(try TokiSyncCoding.decodeBundle(AgentPairingBundle.self, from: oversized))
    }

    func test_pairingBundleEncoderRejectsOversizedOutput() {
        let oversized = OversizedEncodable(value: String(
            repeating: "a",
            count: TokiSyncLimits.maximumPairingBundleBytes))

        XCTAssertThrowsError(try TokiSyncCoding.encodeBundle(oversized))
    }

    func test_displayTextRejectsOversizedGraphemeAndDirectionalOverrides() {
        let oversizedGrapheme = "a" + String(repeating: "\u{0301}", count: 400)

        XCTAssertFalse(TokiSyncValidation.isSafeDisplayText(oversizedGrapheme, maximumLength: 80))
        XCTAssertFalse(TokiSyncValidation.isSafeDisplayText("server\u{202E}txt", maximumLength: 80))
        XCTAssertFalse(TokiSyncValidation.isSafeDisplayText("server\n", maximumLength: 80))
        XCTAssertTrue(TokiSyncValidation.isSafeDisplayText("build-server 🐇", maximumLength: 80))
    }

    func test_publicTokenAndFreshnessHelpersSaturateWithoutIntegerOverflow() {
        let event = RemoteTokenEvent(
            timestamp: Date(),
            source: "Codex",
            model: nil,
            inputTokens: Int.max,
            outputTokens: Int.max,
            cacheReadTokens: Int.max,
            cacheWriteTokens: Int.max,
            reasoningTokens: Int.max)

        XCTAssertEqual(event.totalTokens, Int.max)
        XCTAssertEqual(
            TokiSyncLimits.maximumFreshnessAge(syncIntervalSeconds: Int.max),
            TimeInterval(Int.max) * TimeInterval(TokiSyncLimits.staleIntervalMultiplier))
    }

    func test_v1HubPayloadsDefaultMissingSyncIntervals() throws {
        let encoder = TokiSyncCoding.makeEncoder()
        let decoder = TokiSyncCoding.makeDecoder()
        let requestData = try encoder.encode(LegacyCreateRemoteDeviceRequest(name: "ubuntu"))
        let request = try decoder.decode(CreateRemoteDeviceRequest.self, from: requestData)
        let createdAt = Date(timeIntervalSince1970: 1_750_000_000)
        let summaryData = try encoder.encode(LegacyRemoteDeviceSummary(
            id: "device-1",
            name: "ubuntu",
            createdAt: createdAt,
            lastSeenAt: nil,
            latestSequence: nil))
        let summary = try decoder.decode(RemoteDeviceSummary.self, from: summaryData)

        XCTAssertEqual(request.syncIntervalSeconds, TokiSyncLimits.defaultSyncIntervalSeconds)
        XCTAssertEqual(summary.createdAt, createdAt)
        XCTAssertEqual(summary.syncIntervalSeconds, TokiSyncLimits.defaultSyncIntervalSeconds)
    }

    func test_v1PairingBundleDefaultsMissingRetentionAndSyncInterval() throws {
        let hubURL = try XCTUnwrap(URL(string: "https://hub.example.test"))
        let data = try TokiSyncCoding.makeEncoder().encode(LegacyAgentPairingBundle(
            schemaVersion: TokiSyncProtocolVersion.current,
            hubURL: hubURL,
            deviceID: "device-1",
            deviceName: "ubuntu",
            uploadToken: String(repeating: "u", count: 32),
            encryptionKey: Data(repeating: 0x42, count: 32).base64EncodedString()))

        let bundle = try TokiSyncCoding.makeDecoder().decode(AgentPairingBundle.self, from: data)

        XCTAssertEqual(bundle.hubURL, hubURL)
        XCTAssertEqual(bundle.retentionDays, TokiSyncLimits.defaultRetentionDays)
        XCTAssertEqual(bundle.syncIntervalSeconds, TokiSyncLimits.defaultSyncIntervalSeconds)
    }
}

private struct OversizedEncodable: Encodable {
    let value: String
}

private struct LegacyCreateRemoteDeviceRequest: Encodable {
    let name: String
}

private struct LegacyRemoteDeviceSummary: Encodable {
    let id: String
    let name: String
    let createdAt: Date
    let lastSeenAt: Date?
    let latestSequence: UInt64?
}

private struct LegacyAgentPairingBundle: Encodable {
    let schemaVersion: Int
    let hubURL: URL
    let deviceID: String
    let deviceName: String
    let uploadToken: String
    let encryptionKey: String
}
