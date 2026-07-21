import Foundation
import TokiSyncProtocol
import Vapor

func configureHub(_ application: Application, configuration: HubConfiguration) throws {
    let store = try HubStore(directory: configuration.storageDirectory)
    switch configuration.bindTarget {
    case let .tcp(hostname, port):
        application.http.server.configuration.address = .hostname(hostname, port: port)
    case let .unixSocket(url):
        try prepareSocketDirectory(for: url)
        application.http.server.configuration.address = .unixDomainSocket(path: url.path)
    }
    application.routes.defaultMaxBodySize = ByteCount(
        value: TokiSyncLimits.maximumManagementResponseBytes)

    registerHealthRoute(application)
    registerDeviceManagementRoutes(application, store: store, ownerToken: configuration.ownerToken)
    registerAgentRoutes(application, store: store)
    registerSnapshotRoutes(application, store: store, ownerToken: configuration.ownerToken)
}

private func registerHealthRoute(_ application: Application) {
    application.get("health") { _ async throws -> Response in
        try jsonResponse(HubHealthResponse())
    }
}

private func registerDeviceManagementRoutes(
    _ application: Application,
    store: HubStore,
    ownerToken: String) {
    application.post("v1", "devices") { request async throws -> Response in
        try requireOwner(request, token: ownerToken)
        let input = try decodeContent(
            CreateRemoteDeviceRequest.self,
            from: request,
            maximumBytes: TokiSyncLimits.maximumManagementResponseBytes)
        do {
            return try await jsonResponse(
                store.createDevice(
                    name: input.name,
                    syncIntervalSeconds: input.syncIntervalSeconds),
                status: .created)
        } catch {
            throw abort(for: error)
        }
    }

    application.get("v1", "devices") { request async throws -> Response in
        try requireOwner(request, token: ownerToken)
        return try await jsonResponse(RemoteDeviceListResponse(devices: store.devices()))
    }

    application.delete("v1", "devices", ":deviceID") { request async throws -> HTTPStatus in
        try requireOwner(request, token: ownerToken)
        guard let deviceID = request.parameters.get("deviceID") else {
            throw Abort(.badRequest)
        }
        do {
            try await store.revokeDevice(deviceID)
            return .noContent
        } catch {
            throw abort(for: error)
        }
    }
}

private func registerAgentRoutes(_ application: Application, store: HubStore) {
    application.on(
        .PUT,
        "v1",
        "devices",
        ":deviceID",
        "snapshot",
        body: .collect(maxSize: ByteCount(value: TokiSyncLimits
                .maximumEnvelopeBytes))) { request async throws -> HTTPStatus in
        guard let deviceID = request.parameters.get("deviceID"),
              let uploadToken = request.headers.bearerAuthorization?.token else {
            throw Abort(.unauthorized)
        }
        do {
            try await store.authorizeDevice(deviceID, uploadToken: uploadToken)
        } catch {
            throw abort(for: error)
        }
        let envelope = try decodeContent(
            EncryptedUsageEnvelope.self,
            from: request,
            maximumBytes: TokiSyncLimits.maximumEnvelopeBytes)
        do {
            try await store.store(envelope, deviceID: deviceID, uploadToken: uploadToken)
            return .noContent
        } catch {
            throw abort(for: error)
        }
    }

    application.put("v1", "devices", ":deviceID", "heartbeat") { request async throws -> HTTPStatus in
        guard let deviceID = request.parameters.get("deviceID"),
              let uploadToken = request.headers.bearerAuthorization?.token else {
            throw Abort(.unauthorized)
        }
        do {
            try await store.authorizeDevice(deviceID, uploadToken: uploadToken)
        } catch {
            throw abort(for: error)
        }
        let heartbeat = try decodeContent(
            AgentHeartbeatRequest.self,
            from: request,
            maximumBytes: TokiSyncLimits.maximumAgentResponseBytes)
        do {
            try await store.heartbeat(
                deviceID: deviceID,
                uploadToken: uploadToken,
                latestSequence: heartbeat.latestSequence)
            return .noContent
        } catch {
            throw abort(for: error)
        }
    }
}

private func registerSnapshotRoutes(
    _ application: Application,
    store: HubStore,
    ownerToken: String) {
    application.get("v1", "snapshots", "manifest") { request async throws -> Response in
        try requireOwner(request, token: ownerToken)
        let entityTag = await makeEntityTag(store.manifestVersionTag())
        if request.headers.first(name: "If-None-Match") == entityTag {
            return emptyResponse(status: .notModified, entityTag: entityTag)
        }
        return try await jsonResponse(
            RemoteSnapshotManifestResponse(devices: store.devices()),
            maximumBytes: TokiSyncLimits.maximumManagementResponseBytes,
            entityTag: entityTag)
    }

    application.get("v1", "snapshots") { request async throws -> Response in
        try requireOwner(request, token: ownerToken)
        do {
            let entityTag = await makeEntityTag(store.snapshotVersionTag())
            if request.headers.first(name: "If-None-Match") == entityTag {
                return emptyResponse(status: .notModified, entityTag: entityTag)
            }
            return try await jsonResponse(
                RemoteSnapshotListResponse(snapshots: store.snapshots()),
                maximumBytes: TokiSyncLimits.maximumSnapshotResponseBytes,
                entityTag: entityTag)
        } catch {
            throw abort(for: error)
        }
    }

    application.get("v1", "snapshots", ":deviceID") { request async throws -> Response in
        try requireOwner(request, token: ownerToken)
        guard let deviceID = request.parameters.get("deviceID") else {
            throw Abort(.badRequest)
        }
        do {
            let snapshot = try await store.snapshot(deviceID: deviceID)
            let entityTag = makeEntityTag(SnapshotCipher.digest("\(snapshot.deviceID):\(snapshot.sequence)"))
            return try jsonResponse(
                RemoteSnapshotResponse(snapshot: snapshot),
                maximumBytes: TokiSyncLimits.maximumSingleSnapshotResponseBytes,
                entityTag: entityTag)
        } catch {
            throw abort(for: error)
        }
    }
}

private func prepareSocketDirectory(for socketURL: URL) throws {
    let directory = socketURL.deletingLastPathComponent()
    try FileManager.default.createDirectory(
        at: directory,
        withIntermediateDirectories: true,
        attributes: [.posixPermissions: NSNumber(value: 0o700)])
    let attributes = try FileManager.default.attributesOfItem(atPath: directory.path)
    guard attributes[.type] as? FileAttributeType == .typeDirectory,
          let permissions = attributes[.posixPermissions] as? NSNumber,
          permissions.intValue & 0o022 == 0,
          !FileManager.default.fileExists(atPath: socketURL.path) else {
        throw HubConfigurationError.invalidSocketPath
    }
}

private func requireOwner(_ request: Request, token expectedToken: String) throws {
    guard let suppliedToken = request.headers.bearerAuthorization?.token,
          TokiSyncValidation.isSafeCredential(suppliedToken),
          SnapshotCipher.constantTimeEqual(
              SnapshotCipher.digest(suppliedToken),
              SnapshotCipher.digest(expectedToken)) else {
        throw Abort(.unauthorized)
    }
}

private func decodeContent<Value: Decodable>(
    _ type: Value.Type,
    from request: Request,
    maximumBytes: Int) throws -> Value {
    do {
        guard let body = request.body.data,
              body.readableBytes <= maximumBytes else {
            throw Abort(.badRequest, reason: "The request body is not valid Toki JSON.")
        }
        return try TokiSyncCoding.makeDecoder().decode(type, from: Data(body.readableBytesView))
    } catch {
        throw Abort(.badRequest, reason: "The request body is not valid Toki JSON.")
    }
}

private func jsonResponse(
    _ value: some Encodable,
    status: HTTPResponseStatus = .ok,
    maximumBytes: Int? = nil,
    entityTag: String? = nil) throws -> Response {
    let data = try TokiSyncCoding.makeEncoder().encode(value)
    if let maximumBytes, data.count > maximumBytes {
        throw HubStoreError.storageQuotaExceeded
    }
    var headers = securityHeaders(entityTag: entityTag)
    headers.contentType = .json
    return Response(status: status, headers: headers, body: .init(data: data))
}

private func emptyResponse(status: HTTPResponseStatus, entityTag: String) -> Response {
    Response(status: status, headers: securityHeaders(entityTag: entityTag))
}

private func securityHeaders(entityTag: String?) -> HTTPHeaders {
    var headers = HTTPHeaders()
    headers.replaceOrAdd(name: .cacheControl, value: "no-store")
    headers.replaceOrAdd(name: "X-Content-Type-Options", value: "nosniff")
    headers.replaceOrAdd(name: "Referrer-Policy", value: "no-referrer")
    if let entityTag {
        headers.replaceOrAdd(name: .eTag, value: entityTag)
    }
    return headers
}

private func makeEntityTag(_ digest: String) -> String {
    "\"\(digest)\""
}

private func abort(for error: Error) -> Abort {
    guard let storeError = error as? HubStoreError else {
        return Abort(.internalServerError)
    }
    switch storeError {
    case .unauthorized:
        return Abort(.unauthorized)
    case .deviceNotFound:
        return Abort(.notFound)
    case .payloadTooLarge:
        return Abort(.payloadTooLarge)
    case .storageQuotaExceeded:
        return Abort(.insufficientStorage, reason: storeError.localizedDescription)
    case .tooManyDevices, .staleSequence, .sequenceConflict:
        return Abort(.conflict, reason: storeError.localizedDescription)
    case .invalidDeviceName,
         .invalidSyncInterval,
         .unsupportedVersion,
         .deviceMismatch,
         .invalidTimestamp:
        return Abort(.badRequest, reason: storeError.localizedDescription)
    case .storageDurabilityUnconfirmed:
        return Abort(.serviceUnavailable)
    case .corruptedStorage:
        return Abort(.internalServerError)
    }
}
