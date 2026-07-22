import Foundation
import TokiSyncProtocol

enum RemoteConditionalResult<Value> {
    case modified(Value, entityTag: String)
    case notModified(entityTag: String)
}

protocol RemoteHubClientProtocol {
    func fetchSnapshotManifest(
        configuration: RemoteHubConfiguration,
        ifNoneMatch: String?) async throws -> RemoteConditionalResult<[RemoteDeviceSummary]>
    func fetchSnapshot(
        configuration: RemoteHubConfiguration,
        deviceID: String) async throws -> EncryptedUsageEnvelope
    func createDevice(
        name: String,
        syncIntervalSeconds: Int,
        configuration: RemoteHubConfiguration) async throws -> CreateRemoteDeviceResponse
    func fetchDevices(configuration: RemoteHubConfiguration) async throws -> [RemoteDeviceSummary]
    func revokeDevice(id: String, configuration: RemoteHubConfiguration) async throws
}

struct RemoteHubClient: RemoteHubClientProtocol {
    private let sessionConfiguration: URLSessionConfiguration

    init(sessionConfiguration: URLSessionConfiguration = .ephemeral) {
        self.sessionConfiguration = sessionConfiguration
    }

    func fetchSnapshotManifest(
        configuration: RemoteHubConfiguration,
        ifNoneMatch: String?) async throws -> RemoteConditionalResult<[RemoteDeviceSummary]> {
        let request = ownerRequest(
            url: configuration.hubURL
                .appendingPathComponent("v1")
                .appendingPathComponent("snapshots")
                .appendingPathComponent("manifest"),
            configuration: configuration,
            ifNoneMatch: ifNoneMatch)
        let response = try await perform(
            request,
            maximumBytes: TokiSyncLimits.maximumManagementResponseBytes,
            allowedStatusCodes: ifNoneMatch == nil ? [200] : [200, 304],
            emptyBodyStatusCodes: ifNoneMatch == nil ? [] : [304])
        let entityTag = try Self.validatedEntityTag(response.response)
        if response.response.statusCode == 304 {
            guard response.data.isEmpty else { throw RemoteHubClientError.invalidResponse }
            return .notModified(entityTag: entityTag)
        }
        let devices = try TokiSyncCoding.makeDecoder()
            .decode(RemoteSnapshotManifestResponse.self, from: response.data).devices
        return try .modified(Self.validatedDeviceList(devices), entityTag: entityTag)
    }

    func fetchSnapshot(
        configuration: RemoteHubConfiguration,
        deviceID: String) async throws -> EncryptedUsageEnvelope {
        guard TokiSyncValidation.isSafeDeviceID(deviceID) else {
            throw RemoteHubClientError.invalidPayload
        }
        let request = ownerRequest(
            url: configuration.hubURL
                .appendingPathComponent("v1")
                .appendingPathComponent("snapshots")
                .appendingPathComponent(deviceID),
            configuration: configuration)
        let response = try await perform(
            request,
            maximumBytes: TokiSyncLimits.maximumSingleSnapshotResponseBytes,
            allowedStatusCodes: [200])
        _ = try Self.validatedEntityTag(response.response)
        let snapshot = try TokiSyncCoding.makeDecoder()
            .decode(RemoteSnapshotResponse.self, from: response.data).snapshot
        guard snapshot.deviceID == deviceID else {
            throw RemoteHubClientError.invalidPayload
        }
        return snapshot
    }

    func createDevice(
        name: String,
        syncIntervalSeconds: Int,
        configuration: RemoteHubConfiguration) async throws -> CreateRemoteDeviceResponse {
        var request = ownerRequest(
            url: configuration.hubURL
                .appendingPathComponent("v1")
                .appendingPathComponent("devices"),
            configuration: configuration)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try TokiSyncCoding.makeEncoder().encode(
            CreateRemoteDeviceRequest(name: name, syncIntervalSeconds: syncIntervalSeconds))
        let response = try await perform(
            request,
            maximumBytes: TokiSyncLimits.maximumManagementResponseBytes,
            allowedStatusCodes: [201])
        let device = try TokiSyncCoding.makeDecoder().decode(CreateRemoteDeviceResponse.self, from: response.data)
        try Self.validateCreatedDevice(device)
        return device
    }

    func fetchDevices(configuration: RemoteHubConfiguration) async throws -> [RemoteDeviceSummary] {
        let request = ownerRequest(
            url: configuration.hubURL
                .appendingPathComponent("v1")
                .appendingPathComponent("devices"),
            configuration: configuration)
        let response = try await perform(
            request,
            maximumBytes: TokiSyncLimits.maximumManagementResponseBytes,
            allowedStatusCodes: [200])
        let devices = try TokiSyncCoding.makeDecoder()
            .decode(RemoteDeviceListResponse.self, from: response.data).devices
        return try Self.validatedDeviceList(devices)
    }

    func revokeDevice(id: String, configuration: RemoteHubConfiguration) async throws {
        guard TokiSyncValidation.isSafeDeviceID(id) else {
            throw RemoteHubClientError.invalidPayload
        }
        var request = ownerRequest(
            url: configuration.hubURL
                .appendingPathComponent("v1")
                .appendingPathComponent("devices")
                .appendingPathComponent(id),
            configuration: configuration)
        request.httpMethod = "DELETE"
        _ = try await perform(
            request,
            maximumBytes: TokiSyncLimits.maximumManagementResponseBytes,
            allowedStatusCodes: [204],
            emptyBodyStatusCodes: [204])
    }

    static func validateCreatedDevice(_ device: CreateRemoteDeviceResponse) throws {
        guard TokiSyncValidation.isSafeDeviceID(device.deviceID),
              TokiSyncValidation.normalizedDeviceName(device.deviceName) == device.deviceName,
              TokiSyncValidation.isSafeCredential(device.uploadToken) else {
            throw RemoteHubClientError.invalidPayload
        }
    }

    static func validatedDeviceList(
        _ devices: [RemoteDeviceSummary],
        now: Date = Date()) throws -> [RemoteDeviceSummary] {
        try RemoteSnapshotManifestValidation.validated(devices, now: now)
    }

    static func validateDeviceList(_ devices: [RemoteDeviceSummary]) throws {
        _ = try validatedDeviceList(devices)
    }

    private static func validatedEntityTag(_ response: HTTPURLResponse) throws -> String {
        guard let entityTag = response.value(forHTTPHeaderField: "ETag"),
              RemoteEntityTag.isValid(entityTag) else {
            throw RemoteHubClientError.invalidResponse
        }
        return entityTag
    }

    private func ownerRequest(
        url: URL,
        configuration: RemoteHubConfiguration,
        ifNoneMatch: String? = nil) -> URLRequest {
        var request = URLRequest(url: url)
        request.setValue("Bearer \(configuration.ownerToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let ifNoneMatch, RemoteEntityTag.isValid(ifNoneMatch) {
            request.setValue(ifNoneMatch, forHTTPHeaderField: "If-None-Match")
        }
        request.cachePolicy = .reloadIgnoringLocalCacheData
        return request
    }

    private func perform(
        _ request: URLRequest,
        maximumBytes: Int,
        allowedStatusCodes: Set<Int>,
        emptyBodyStatusCodes: Set<Int> = []) async throws -> RemoteBoundedHTTPResponse {
        let loader = RemoteBoundedResponseLoader(
            expectedURL: request.url,
            maximumBytes: maximumBytes,
            allowedStatusCodes: allowedStatusCodes,
            emptyBodyStatusCodes: emptyBodyStatusCodes,
            sessionConfiguration: sessionConfiguration)
        return try await loader.load(request)
    }
}

struct RemoteBoundedHTTPResponse {
    let data: Data
    let response: HTTPURLResponse
}

struct RemoteResponseAccumulator {
    private let expectedURL: URL?
    private let maximumBytes: Int
    private let allowedStatusCodes: Set<Int>
    private let emptyBodyStatusCodes: Set<Int>
    private(set) var data = Data()
    private(set) var response: HTTPURLResponse?

    init(
        expectedURL: URL?,
        maximumBytes: Int,
        allowedStatusCodes: Set<Int>,
        emptyBodyStatusCodes: Set<Int> = []) {
        precondition(maximumBytes >= 0 && !allowedStatusCodes.isEmpty)
        precondition(emptyBodyStatusCodes.isSubset(of: allowedStatusCodes))
        self.expectedURL = expectedURL
        self.maximumBytes = maximumBytes
        self.allowedStatusCodes = allowedStatusCodes
        self.emptyBodyStatusCodes = emptyBodyStatusCodes
    }

    mutating func receive(_ response: HTTPURLResponse) throws {
        guard self.response == nil else { throw RemoteHubClientError.invalidResponse }
        guard response.url == expectedURL else { throw RemoteHubClientError.redirectedResponse }
        guard allowedStatusCodes.contains(response.statusCode) else {
            throw RemoteHubClientError.httpStatus(response.statusCode)
        }
        let expectedLength = response.expectedContentLength
        guard !emptyBodyStatusCodes.contains(response.statusCode) || expectedLength <= 0 else {
            throw RemoteHubClientError.invalidResponse
        }
        guard expectedLength <= 0 || expectedLength <= Int64(maximumBytes) else {
            throw RemoteHubClientError.responseTooLarge
        }
        if expectedLength > 0 {
            data.reserveCapacity(Int(expectedLength))
        }
        self.response = response
    }

    mutating func receive(_ chunk: Data) throws {
        guard let response else { throw RemoteHubClientError.invalidResponse }
        guard chunk.isEmpty || !emptyBodyStatusCodes.contains(response.statusCode) else {
            throw RemoteHubClientError.invalidResponse
        }
        guard chunk.count <= maximumBytes - data.count else {
            throw RemoteHubClientError.responseTooLarge
        }
        data.append(chunk)
    }

    func completed() throws -> RemoteBoundedHTTPResponse {
        guard let response else { throw RemoteHubClientError.invalidResponse }
        guard !emptyBodyStatusCodes.contains(response.statusCode) || data.isEmpty else {
            throw RemoteHubClientError.invalidResponse
        }
        return RemoteBoundedHTTPResponse(data: data, response: response)
    }
}

private final class RemoteBoundedResponseLoader: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private typealias ResponseContinuation = CheckedContinuation<RemoteBoundedHTTPResponse, Error>

    private let sessionConfiguration: URLSessionConfiguration
    private let lock = NSLock()
    private var accumulator: RemoteResponseAccumulator
    private var cancellationRequested = false
    private var completed = false
    private var continuation: ResponseContinuation?
    private var session: URLSession?
    private var task: URLSessionDataTask?

    init(
        expectedURL: URL?,
        maximumBytes: Int,
        allowedStatusCodes: Set<Int>,
        emptyBodyStatusCodes: Set<Int>,
        sessionConfiguration: URLSessionConfiguration) {
        accumulator = RemoteResponseAccumulator(
            expectedURL: expectedURL,
            maximumBytes: maximumBytes,
            allowedStatusCodes: allowedStatusCodes,
            emptyBodyStatusCodes: emptyBodyStatusCodes)
        self.sessionConfiguration = sessionConfiguration
    }

    func load(_ request: URLRequest) async throws -> RemoteBoundedHTTPResponse {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                start(request, continuation: continuation)
            }
        } onCancel: {
            cancel()
        }
    }

    private func start(_ request: URLRequest, continuation: ResponseContinuation) {
        lock.lock()
        guard !cancellationRequested else {
            lock.unlock()
            continuation.resume(throwing: CancellationError())
            return
        }
        self.continuation = continuation
        let configuration = sessionConfiguration.copy() as? URLSessionConfiguration ?? sessionConfiguration
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 60
        configuration.httpMaximumConnectionsPerHost = 4
        let session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
        let task = session.dataTask(with: request)
        self.session = session
        self.task = task
        lock.unlock()
        task.resume()
    }

    private func cancel() {
        lock.lock()
        cancellationRequested = true
        let shouldFinish = continuation != nil
        lock.unlock()
        if shouldFinish {
            finish(.failure(CancellationError()))
        }
    }

    private func finish(_ result: Result<RemoteBoundedHTTPResponse, Error>) {
        lock.lock()
        guard !completed, let continuation else {
            lock.unlock()
            return
        }
        completed = true
        self.continuation = nil
        let session = session
        let task = task
        self.session = nil
        self.task = nil
        lock.unlock()

        switch result {
        case .success:
            session?.finishTasksAndInvalidate()
        case .failure:
            task?.cancel()
            session?.invalidateAndCancel()
        }
        continuation.resume(with: result)
    }

    func urlSession(
        _: URLSession,
        dataTask _: URLSessionDataTask,
        didReceive response: URLResponse,
        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        guard let response = response as? HTTPURLResponse else {
            completionHandler(.cancel)
            finish(.failure(RemoteHubClientError.invalidResponse))
            return
        }
        lock.lock()
        guard !completed else {
            lock.unlock()
            completionHandler(.cancel)
            return
        }
        do {
            try accumulator.receive(response)
            lock.unlock()
            completionHandler(.allow)
        } catch {
            lock.unlock()
            completionHandler(.cancel)
            finish(.failure(error))
        }
    }

    func urlSession(_: URLSession, dataTask _: URLSessionDataTask, didReceive data: Data) {
        lock.lock()
        guard !completed else {
            lock.unlock()
            return
        }
        do {
            try accumulator.receive(data)
            lock.unlock()
        } catch {
            lock.unlock()
            finish(.failure(error))
        }
    }

    func urlSession(_: URLSession, task _: URLSessionTask, didCompleteWithError error: Error?) {
        if let error {
            finish(.failure(error))
            return
        }
        lock.lock()
        let result = Result { try accumulator.completed() }
        lock.unlock()
        finish(result)
    }

    func urlSession(
        _: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection _: HTTPURLResponse,
        newRequest _: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
        finish(.failure(RemoteHubClientError.redirectedResponse))
        task.cancel()
    }
}

enum RemoteHubClientError: LocalizedError {
    case invalidResponse
    case invalidPayload
    case redirectedResponse
    case responseTooLarge
    case httpStatus(Int)

    var allowsCachedFallback: Bool {
        switch self {
        case .invalidResponse, .invalidPayload, .redirectedResponse, .responseTooLarge:
            false
        case let .httpStatus(status):
            status == 408 || status == 429 || status >= 500
        }
    }

    var errorDescription: String? {
        switch self {
        case .invalidResponse:
            "The Hub returned an invalid HTTP response."
        case .invalidPayload:
            "The Hub returned invalid remote-sync data."
        case .redirectedResponse:
            "The Hub attempted to redirect an authenticated request."
        case .responseTooLarge:
            "The Hub response exceeded the endpoint safety limit."
        case let .httpStatus(status):
            "The Hub request failed with HTTP status \(status)."
        }
    }
}
