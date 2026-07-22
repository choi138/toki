import Foundation
import NIOCore
import TokiSyncProtocol
import XCTest
import XCTVapor
@testable import TokiHubCore

/// Keep this integration suite after HubStoreTests: Swift 5.9 FoundationNetworking
/// can otherwise retain Vapor's event loop while later file-only tests execute.
final class HubWebAPIIntegrationTests: XCTestCase {
    func test_managementRequestBodyCollectionIsBounded() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("toki-hub-route-tests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let ownerToken = String(repeating: "o", count: 48)
        let application = try await makeApplication(root: root, ownerToken: ownerToken)

        do {
            XCTAssertEqual(
                application.routes.defaultMaxBodySize,
                ByteCount(value: TokiSyncLimits.maximumManagementResponseBytes))
            let tester = try application.testable(method: .running(port: 0))
            let response = try await tester.sendRequest(
                .POST,
                "/v1/devices",
                headers: ["Authorization": "Bearer \(ownerToken)"],
                body: oversizedManagementBody())
            XCTAssertEqual(response.status, .payloadTooLarge)
            try await application.asyncShutdown()
        } catch {
            try? await application.asyncShutdown()
            throw error
        }
    }

    func test_snapshotRequestBodyUsesEnvelopeCollectionLimit() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("toki-hub-route-tests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let ownerToken = String(repeating: "o", count: 48)
        let device = try await createDeviceDirectly(root: root)
        let application = try await makeApplication(root: root, ownerToken: ownerToken)

        do {
            let tester = try application.testable(method: .running(port: 0))
            let response = try await tester.sendRequest(
                .PUT,
                "/v1/devices/\(device.deviceID)/snapshot",
                headers: [
                    "Authorization": "Bearer \(device.uploadToken)",
                    "Content-Type": "application/json",
                ],
                body: oversizedManagementBody())
            XCTAssertEqual(response.status, .badRequest)
            try await application.asyncShutdown()
        } catch {
            try? await application.asyncShutdown()
            throw error
        }
    }

    func test_provisionUploadFetchDecryptReplayConflictAndRevokeFlow() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("toki-hub-route-tests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let ownerToken = String(repeating: "o", count: 48)
        let application = try await makeApplication(root: root, ownerToken: ownerToken)

        do {
            let device = try await createDevice(application, ownerToken: ownerToken)
            let key = SnapshotCipher.generateKey()
            let snapshot = makeSnapshot(device: device)
            let envelope = try SnapshotCipher.seal(snapshot, sequence: 1, key: key)

            try await upload(envelope, device: device, to: application, expecting: .noContent)
            try await upload(envelope, device: device, to: application, expecting: .noContent)
            let fetched = try await fetchSnapshots(application, ownerToken: ownerToken)
            XCTAssertEqual(fetched, [envelope])
            XCTAssertEqual(try SnapshotCipher.open(XCTUnwrap(fetched.first), key: key), snapshot)
            let fetchedDeviceSnapshot = try await fetchSnapshot(
                application,
                deviceID: device.deviceID,
                ownerToken: ownerToken)
            XCTAssertEqual(fetchedDeviceSnapshot, envelope)

            let conflict = EncryptedUsageEnvelope(
                deviceID: device.deviceID,
                sequence: envelope.sequence,
                generatedAt: envelope.generatedAt,
                payload: Data(repeating: 1, count: 32).base64EncodedString())
            try await upload(conflict, device: device, to: application, expecting: .conflict)

            try await revoke(device, from: application, ownerToken: ownerToken)
            try await revoke(device, from: application, ownerToken: ownerToken)
            let remainingSnapshots = try await fetchSnapshots(application, ownerToken: ownerToken)
            XCTAssertTrue(remainingSnapshots.isEmpty)
            try await assertSnapshotNotFound(
                application,
                deviceID: device.deviceID,
                ownerToken: ownerToken)
            try await upload(envelope, device: device, to: application, expecting: .unauthorized)
            try await application.asyncShutdown()
        } catch {
            try? await application.asyncShutdown()
            throw error
        }
    }

    func test_uploadAuthenticatesBeforeParsingRequestBody() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("toki-hub-route-tests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let ownerToken = String(repeating: "o", count: 48)
        let device = try await createDeviceDirectly(root: root)
        let configuration = try HubConfiguration(environment: [
            "TOKI_HUB_OWNER_TOKEN": ownerToken,
            "TOKI_HUB_STORAGE_PATH": root.path,
            "TOKI_HUB_HOST": "127.0.0.1",
            "PORT": "8080",
        ])
        let application = try await Application.make(.testing)

        do {
            try configureHub(application, configuration: configuration)
            let path = "/v1/devices/\(device.deviceID)/snapshot"
            let unauthorizedRequest: (inout XCTHTTPRequest) async throws -> Void = { request in
                request.headers.bearerAuthorization = .init(token: String(repeating: "x", count: 48))
                request.headers.contentType = .json
                request.body.writeString("not-json")
            }
            let expectUnauthorized: (XCTHTTPResponse) async throws -> Void = { response in
                XCTAssertEqual(response.status, .unauthorized)
            }
            try await application.test(
                .PUT,
                path,
                beforeRequest: unauthorizedRequest,
                afterResponse: expectUnauthorized)

            let authorizedRequest: (inout XCTHTTPRequest) async throws -> Void = { request in
                request.headers.bearerAuthorization = .init(token: device.uploadToken)
                request.headers.contentType = .json
                request.body.writeString("not-json")
            }
            let expectBadRequest: (XCTHTTPResponse) async throws -> Void = { response in
                XCTAssertEqual(response.status, .badRequest)
            }
            try await application.test(
                .PUT,
                path,
                beforeRequest: authorizedRequest,
                afterResponse: expectBadRequest)
            try await application.asyncShutdown()
        } catch {
            try? await application.asyncShutdown()
            throw error
        }
    }
}

extension HubWebAPIIntegrationTests {
    func test_heartbeatManifestAndSnapshotConditionalRequests() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("toki-hub-route-tests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let ownerToken = String(repeating: "o", count: 48)
        let application = try await makeApplication(root: root, ownerToken: ownerToken)

        do {
            let device = try await createDevice(
                application,
                ownerToken: ownerToken,
                syncIntervalSeconds: TokiSyncLimits.minimumSyncIntervalSeconds)
            let key = SnapshotCipher.generateKey()
            let envelope = try SnapshotCipher.seal(makeSnapshot(device: device), sequence: 1, key: key)
            try await upload(envelope, device: device, to: application, expecting: .noContent)

            var manifestTag: String?
            let authorizeOwner: (inout XCTHTTPRequest) async throws -> Void = { request in
                request.headers.bearerAuthorization = .init(token: ownerToken)
            }
            try await application.test(
                .GET,
                "/v1/snapshots/manifest",
                beforeRequest: authorizeOwner) { response async throws in
                    XCTAssertEqual(response.status, .ok)
                    XCTAssertEqual(response.headers.first(name: "Cache-Control"), "no-store")
                    manifestTag = response.headers.first(name: .eTag)
                    let manifest = try Self.decodeJSON(RemoteSnapshotManifestResponse.self, from: response)
                    XCTAssertEqual(
                        manifest.devices.first?.syncIntervalSeconds,
                        TokiSyncLimits.minimumSyncIntervalSeconds)
                    XCTAssertEqual(manifest.devices.first?.latestSequence, 1)
                }
            let originalManifestTag = try XCTUnwrap(manifestTag)

            var snapshotTag: String?
            try await application.test(
                .GET,
                "/v1/snapshots",
                beforeRequest: authorizeOwner) { response async throws in
                    XCTAssertEqual(response.status, .ok)
                    snapshotTag = response.headers.first(name: .eTag)
                    XCTAssertEqual(
                        try Self.decodeJSON(RemoteSnapshotListResponse.self, from: response).snapshots,
                        [envelope])
                }
            let originalSnapshotTag = try XCTUnwrap(snapshotTag)

            try await assertNotModified(
                application,
                path: "/v1/snapshots/manifest",
                ownerToken: ownerToken,
                entityTag: originalManifestTag)
            try await assertNotModified(
                application,
                path: "/v1/snapshots",
                ownerToken: ownerToken,
                entityTag: originalSnapshotTag)

            try await Task.sleep(nanoseconds: 2_000_000)
            try await heartbeat(envelope, device: device, to: application, expecting: .noContent)

            var refreshedManifestTag: String?
            try await application.test(
                .GET,
                "/v1/snapshots/manifest",
                beforeRequest: { request async throws in
                    request.headers.bearerAuthorization = .init(token: ownerToken)
                    request.headers.replaceOrAdd(name: "If-None-Match", value: originalManifestTag)
                }) { response async throws in
                    XCTAssertEqual(response.status, .ok)
                    refreshedManifestTag = response.headers.first(name: .eTag)
                }
            XCTAssertNotEqual(try XCTUnwrap(refreshedManifestTag), originalManifestTag)
            try await assertNotModified(
                application,
                path: "/v1/snapshots",
                ownerToken: ownerToken,
                entityTag: originalSnapshotTag)

            try await application.asyncShutdown()
        } catch {
            try? await application.asyncShutdown()
            throw error
        }
    }
}

extension HubWebAPIIntegrationTests {
    private func oversizedManagementBody() -> ByteBuffer {
        var body = ByteBufferAllocator().buffer(
            capacity: TokiSyncLimits.maximumManagementResponseBytes + 1)
        body.writeRepeatingByte(
            0x61,
            count: TokiSyncLimits.maximumManagementResponseBytes + 1)
        return body
    }

    private func makeApplication(root: URL, ownerToken: String) async throws -> Application {
        let configuration = try HubConfiguration(environment: [
            "TOKI_HUB_OWNER_TOKEN": ownerToken,
            "TOKI_HUB_STORAGE_PATH": root.path,
            "TOKI_HUB_HOST": "127.0.0.1",
            "PORT": "8080",
        ])
        let application = try await Application.make(.testing)
        try configureHub(application, configuration: configuration)
        return application
    }

    private func createDeviceDirectly(root: URL) async throws -> CreateRemoteDeviceResponse {
        let store = try HubStore(directory: root)
        return try await store.createDevice(name: "ubuntu")
    }

    private func createDevice(
        _ application: Application,
        ownerToken: String,
        syncIntervalSeconds: Int = TokiSyncLimits.defaultSyncIntervalSeconds) async throws
        -> CreateRemoteDeviceResponse {
        var createdDevice: CreateRemoteDeviceResponse?
        let beforeRequest: (inout XCTHTTPRequest) async throws -> Void = { request in
            request.headers.bearerAuthorization = .init(token: ownerToken)
            try Self.writeJSON(
                CreateRemoteDeviceRequest(name: "ubuntu", syncIntervalSeconds: syncIntervalSeconds),
                to: &request)
        }
        let afterResponse: (XCTHTTPResponse) async throws -> Void = { response in
            XCTAssertEqual(response.status, .created)
            createdDevice = try Self.decodeJSON(CreateRemoteDeviceResponse.self, from: response)
        }
        try await application.test(
            .POST,
            "/v1/devices",
            beforeRequest: beforeRequest,
            afterResponse: afterResponse)
        return try XCTUnwrap(createdDevice)
    }

    private func upload(
        _ envelope: EncryptedUsageEnvelope,
        device: CreateRemoteDeviceResponse,
        to application: Application,
        expecting expectedStatus: HTTPStatus) async throws {
        let beforeRequest: (inout XCTHTTPRequest) async throws -> Void = { request in
            request.headers.bearerAuthorization = .init(token: device.uploadToken)
            try Self.writeJSON(envelope, to: &request)
        }
        let afterResponse: (XCTHTTPResponse) async throws -> Void = { response in
            XCTAssertEqual(response.status, expectedStatus)
        }
        try await application.test(
            .PUT,
            "/v1/devices/\(device.deviceID)/snapshot",
            beforeRequest: beforeRequest,
            afterResponse: afterResponse)
    }

    private func heartbeat(
        _ envelope: EncryptedUsageEnvelope,
        device: CreateRemoteDeviceResponse,
        to application: Application,
        expecting expectedStatus: HTTPStatus) async throws {
        try await application.test(
            .PUT,
            "/v1/devices/\(device.deviceID)/heartbeat",
            beforeRequest: { request async throws in
                request.headers.bearerAuthorization = .init(token: device.uploadToken)
                try Self.writeJSON(AgentHeartbeatRequest(latestSequence: envelope.sequence), to: &request)
            }) { response async throws in
                XCTAssertEqual(response.status, expectedStatus)
            }
    }

    private func assertNotModified(
        _ application: Application,
        path: String,
        ownerToken: String,
        entityTag: String) async throws {
        try await application.test(
            .GET,
            path,
            beforeRequest: { request async throws in
                request.headers.bearerAuthorization = .init(token: ownerToken)
                request.headers.replaceOrAdd(name: "If-None-Match", value: entityTag)
            }) { response async throws in
                XCTAssertEqual(response.status, .notModified)
                XCTAssertEqual(response.headers.first(name: .eTag), entityTag)
                XCTAssertEqual(response.body.readableBytes, 0)
            }
    }

    private func fetchSnapshots(
        _ application: Application,
        ownerToken: String) async throws -> [EncryptedUsageEnvelope] {
        var snapshots: [EncryptedUsageEnvelope]?
        let beforeRequest: (inout XCTHTTPRequest) async throws -> Void = { request in
            request.headers.bearerAuthorization = .init(token: ownerToken)
        }
        let afterResponse: (XCTHTTPResponse) async throws -> Void = { response in
            XCTAssertEqual(response.status, .ok)
            snapshots = try Self.decodeJSON(RemoteSnapshotListResponse.self, from: response).snapshots
        }
        try await application.test(
            .GET,
            "/v1/snapshots",
            beforeRequest: beforeRequest,
            afterResponse: afterResponse)
        return try XCTUnwrap(snapshots)
    }

    private func fetchSnapshot(
        _ application: Application,
        deviceID: String,
        ownerToken: String) async throws -> EncryptedUsageEnvelope {
        var snapshot: EncryptedUsageEnvelope?
        try await application.test(
            .GET,
            "/v1/snapshots/\(deviceID)",
            beforeRequest: { request async throws in
                request.headers.bearerAuthorization = .init(token: ownerToken)
            }) { response async throws in
                XCTAssertEqual(response.status, .ok)
                XCTAssertNotNil(response.headers.first(name: .eTag))
                snapshot = try Self.decodeJSON(RemoteSnapshotResponse.self, from: response).snapshot
            }
        return try XCTUnwrap(snapshot)
    }

    private func assertSnapshotNotFound(
        _ application: Application,
        deviceID: String,
        ownerToken: String) async throws {
        try await application.test(
            .GET,
            "/v1/snapshots/\(deviceID)",
            beforeRequest: { request async throws in
                request.headers.bearerAuthorization = .init(token: ownerToken)
            }) { response async throws in
                XCTAssertEqual(response.status, .notFound)
            }
    }

    private func revoke(
        _ device: CreateRemoteDeviceResponse,
        from application: Application,
        ownerToken: String) async throws {
        let beforeRequest: (inout XCTHTTPRequest) async throws -> Void = { request in
            request.headers.bearerAuthorization = .init(token: ownerToken)
        }
        let afterResponse: (XCTHTTPResponse) async throws -> Void = { response in
            XCTAssertEqual(response.status, .noContent)
        }
        try await application.test(
            .DELETE,
            "/v1/devices/\(device.deviceID)",
            beforeRequest: beforeRequest,
            afterResponse: afterResponse)
    }

    private func makeSnapshot(device: CreateRemoteDeviceResponse) -> RemoteUsageSnapshot {
        let generatedAt = Date(timeIntervalSince1970: 1_750_000_000)
        return RemoteUsageSnapshot(
            device: RemoteDeviceDescriptor(id: device.deviceID, name: device.deviceName, platform: "linux"),
            generatedAt: generatedAt,
            coveredFrom: generatedAt.addingTimeInterval(-60),
            coveredTo: generatedAt.addingTimeInterval(1),
            tokenEvents: [
                RemoteTokenEvent(
                    timestamp: generatedAt.addingTimeInterval(-1),
                    source: "Codex",
                    model: "gpt-test",
                    inputTokens: 1,
                    outputTokens: 2,
                    cacheReadTokens: 0,
                    cacheWriteTokens: 0,
                    reasoningTokens: 0),
            ],
            activityEvents: [])
    }

    private static func writeJSON(_ value: some Encodable, to request: inout XCTHTTPRequest) throws {
        request.headers.contentType = .json
        try request.body.writeBytes(TokiSyncCoding.makeEncoder().encode(value))
    }

    private static func decodeJSON<Value: Decodable>(
        _ type: Value.Type,
        from response: XCTHTTPResponse) throws -> Value {
        try TokiSyncCoding.makeDecoder().decode(type, from: Data(response.body.readableBytesView))
    }
}
