import Foundation
import TokiSyncProtocol
import XCTest
@testable import Toki

final class RemoteSyncTransportRegressionTests: XCTestCase {
    func test_conditionalManifestRejectsMismatchedResponseEntityTag() async throws {
        let configuration = try RemoteHubConfiguration(
            hubURL: XCTUnwrap(URL(string: "https://hub.example.test")),
            ownerToken: String(repeating: "o", count: 32))
        let sessionConfiguration = URLSessionConfiguration.ephemeral
        sessionConfiguration.protocolClasses = [RemoteHubURLProtocolStub.self]
        let conditionalEntityTag = entityTag("a")
        RemoteHubURLProtocolStub.install { request in
            XCTAssertEqual(request.value(forHTTPHeaderField: "If-None-Match"), conditionalEntityTag)
            let response = try XCTUnwrap(HTTPURLResponse(
                url: XCTUnwrap(request.url),
                statusCode: 304,
                httpVersion: nil,
                headerFields: ["ETag": entityTag("b")]))
            return (response, Data())
        }
        defer { RemoteHubURLProtocolStub.reset() }

        do {
            _ = try await RemoteHubClient(sessionConfiguration: sessionConfiguration)
                .fetchSnapshotManifest(configuration: configuration, ifNoneMatch: conditionalEntityTag)
            XCTFail("Expected a mismatched 304 entity tag to be rejected")
        } catch let error as RemoteHubClientError {
            guard case .invalidResponse = error else {
                return XCTFail("Expected invalidResponse, got \(error)")
            }
        }
    }

    func test_snapshotFetchRejectsMalformedEnvelopeFields() async throws {
        let configuration = try RemoteHubConfiguration(
            hubURL: XCTUnwrap(URL(string: "https://hub.example.test")),
            ownerToken: String(repeating: "o", count: 32))
        let sessionConfiguration = URLSessionConfiguration.ephemeral
        sessionConfiguration.protocolClasses = [RemoteHubURLProtocolStub.self]
        let validPayload = Data(repeating: 1, count: 32).base64EncodedString()
        let invalidEnvelopes = [
            EncryptedUsageEnvelope(
                schemaVersion: TokiSyncProtocolVersion.current + 1,
                deviceID: "device-1",
                sequence: 1,
                generatedAt: Date(),
                payload: validPayload),
            EncryptedUsageEnvelope(
                deviceID: "device-1",
                sequence: 0,
                generatedAt: Date(),
                payload: validPayload),
            EncryptedUsageEnvelope(
                deviceID: "device-1",
                sequence: 1,
                generatedAt: Date(),
                payload: ""),
            EncryptedUsageEnvelope(
                deviceID: "device-1",
                sequence: 1,
                generatedAt: Date(),
                payload: "not-base64!"),
        ]
        defer { RemoteHubURLProtocolStub.reset() }

        for envelope in invalidEnvelopes {
            RemoteHubURLProtocolStub.install { request in
                let response = try XCTUnwrap(HTTPURLResponse(
                    url: XCTUnwrap(request.url),
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: ["ETag": entityTag("a")]))
                let body = try TokiSyncCoding.makeEncoder().encode(RemoteSnapshotResponse(snapshot: envelope))
                return (response, body)
            }

            do {
                _ = try await RemoteHubClient(sessionConfiguration: sessionConfiguration)
                    .fetchSnapshot(configuration: configuration, deviceID: "device-1")
                XCTFail("Expected malformed snapshot envelope to be rejected: \(envelope)")
            } catch let error as RemoteHubClientError {
                guard case .invalidPayload = error else {
                    return XCTFail("Expected invalidPayload, got \(error)")
                }
            }
        }
    }

    func test_configurationRejectsPercentEncodedHubPath() throws {
        let encodedPathURL = try XCTUnwrap(URL(string: "https://hub.example.test/%2f"))

        XCTAssertThrowsError(try RemoteHubConfiguration(
            hubURL: encodedPathURL,
            ownerToken: String(repeating: "o", count: 32))) { error in
                guard let configurationError = error as? RemoteSyncConfigurationError,
                      case .insecureHubURL = configurationError else {
                    return XCTFail("Expected insecureHubURL, got \(error)")
                }
            }
    }

    func test_snapshotCacheIdentifierChangesWithOwnerCredential() throws {
        let hubURL = try XCTUnwrap(URL(string: "https://hub.example.test"))
        let first = try RemoteHubConfiguration(
            hubURL: hubURL,
            ownerToken: String(repeating: "a", count: 32))
        let second = try RemoteHubConfiguration(
            hubURL: hubURL,
            ownerToken: String(repeating: "b", count: 32))

        XCTAssertNotEqual(first.snapshotCacheIdentifier, second.snapshotCacheIdentifier)
        XCTAssertFalse(first.snapshotCacheIdentifier.contains(first.ownerToken))
        XCTAssertFalse(second.snapshotCacheIdentifier.contains(second.ownerToken))
    }
}
