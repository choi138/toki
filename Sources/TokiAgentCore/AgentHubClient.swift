import Foundation

#if canImport(FoundationNetworking)
    import FoundationNetworking
#endif

import TokiSyncProtocol

protocol AgentHubClientProtocol {
    func upload(_ envelope: EncryptedUsageEnvelope, configuration: AgentConfiguration) async throws
    func heartbeat(configuration: AgentConfiguration, latestSequence: UInt64) async throws
}

struct AgentHubClient: AgentHubClientProtocol {
    func upload(_ envelope: EncryptedUsageEnvelope, configuration: AgentConfiguration) async throws {
        let url = configuration.hubURL
            .appendingPathComponent("v1")
            .appendingPathComponent("devices")
            .appendingPathComponent(configuration.deviceID)
            .appendingPathComponent("snapshot")
        var request = URLRequest(url: url)
        request.httpMethod = "PUT"
        request.setValue("Bearer \(configuration.uploadToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let requestBody = try TokiSyncCoding.makeEncoder().encode(envelope)
        guard requestBody.count <= TokiSyncLimits.maximumEnvelopeBytes else {
            throw AgentHubClientError.requestTooLarge
        }
        request.httpBody = requestBody

        let loader = AgentBoundedResponseLoader(
            expectedURL: url,
            maximumBytes: TokiSyncLimits.maximumAgentResponseBytes,
            allowedStatusCodes: [204],
            emptyBodyStatusCodes: [204])
        _ = try await loader.load(request)
    }

    func heartbeat(configuration: AgentConfiguration, latestSequence: UInt64) async throws {
        guard latestSequence > 0 else {
            throw AgentHubClientError.invalidHeartbeat
        }
        let url = configuration.hubURL
            .appendingPathComponent("v1")
            .appendingPathComponent("devices")
            .appendingPathComponent(configuration.deviceID)
            .appendingPathComponent("heartbeat")
        var request = URLRequest(url: url)
        request.httpMethod = "PUT"
        request.setValue("Bearer \(configuration.uploadToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try TokiSyncCoding.makeEncoder().encode(
            AgentHeartbeatRequest(latestSequence: latestSequence))

        let loader = AgentBoundedResponseLoader(
            expectedURL: url,
            maximumBytes: TokiSyncLimits.maximumAgentResponseBytes,
            allowedStatusCodes: [204],
            emptyBodyStatusCodes: [204])
        _ = try await loader.load(request)
    }
}

enum AgentHubClientError: LocalizedError {
    case invalidResponse
    case redirectedResponse
    case requestTooLarge
    case responseTooLarge
    case invalidHeartbeat
    case httpStatus(Int)

    var errorDescription: String? {
        switch self {
        case .invalidResponse:
            "The Hub returned a non-HTTP response."
        case .redirectedResponse:
            "The Hub attempted to redirect an authenticated upload."
        case .requestTooLarge:
            "The encrypted snapshot exceeds the 8 MiB upload limit."
        case .responseTooLarge:
            "The Hub response exceeds the 64 KiB safety limit."
        case .invalidHeartbeat:
            "The Agent cannot send a heartbeat before its first snapshot."
        case let .httpStatus(status):
            "The Hub rejected the snapshot with HTTP status \(status)."
        }
    }
}

struct AgentResponseValidator {
    private let expectedURL: URL
    private let maximumBytes: Int
    private let allowedStatusCodes: Set<Int>
    private let emptyBodyStatusCodes: Set<Int>
    private var hasReceivedResponse = false
    private var statusCode: Int?
    private var responseByteCount = 0

    init(
        expectedURL: URL,
        maximumBytes: Int,
        allowedStatusCodes: Set<Int>,
        emptyBodyStatusCodes: Set<Int>) {
        precondition(maximumBytes >= 0 && !allowedStatusCodes.isEmpty)
        precondition(emptyBodyStatusCodes.isSubset(of: allowedStatusCodes))
        self.expectedURL = expectedURL
        self.maximumBytes = maximumBytes
        self.allowedStatusCodes = allowedStatusCodes
        self.emptyBodyStatusCodes = emptyBodyStatusCodes
    }

    mutating func receive(
        responseURL: URL?,
        statusCode: Int,
        expectedContentLength: Int64) throws {
        guard !hasReceivedResponse else {
            throw AgentHubClientError.invalidResponse
        }
        guard responseURL == expectedURL else {
            throw AgentHubClientError.redirectedResponse
        }
        guard allowedStatusCodes.contains(statusCode) else {
            throw AgentHubClientError.httpStatus(statusCode)
        }
        guard !emptyBodyStatusCodes.contains(statusCode) || expectedContentLength <= 0 else {
            throw AgentHubClientError.invalidResponse
        }
        guard expectedContentLength <= 0 || expectedContentLength <= Int64(maximumBytes) else {
            throw AgentHubClientError.responseTooLarge
        }
        hasReceivedResponse = true
        self.statusCode = statusCode
    }

    mutating func receive(_ data: Data) throws {
        guard hasReceivedResponse else {
            throw AgentHubClientError.invalidResponse
        }
        guard data.isEmpty || statusCode.map({ !emptyBodyStatusCodes.contains($0) }) == true else {
            throw AgentHubClientError.invalidResponse
        }
        guard data.count <= maximumBytes - responseByteCount else {
            throw AgentHubClientError.responseTooLarge
        }
        responseByteCount += data.count
    }

    func validateCompletion() throws {
        guard hasReceivedResponse else {
            throw AgentHubClientError.invalidResponse
        }
        guard statusCode.map({ !emptyBodyStatusCodes.contains($0) }) == true || responseByteCount == 0 else {
            throw AgentHubClientError.invalidResponse
        }
    }
}

final class AgentBoundedResponseLoader: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private typealias ResponseContinuation = CheckedContinuation<HTTPURLResponse, Error>

    private let sessionConfiguration: URLSessionConfiguration
    private let lock = NSLock()
    private var responseValidator: AgentResponseValidator
    private var cancellationRequested = false
    private var completed = false
    private var continuation: ResponseContinuation?
    private var receivedResponse: HTTPURLResponse?
    private var session: URLSession?
    private var task: URLSessionDataTask?

    init(
        expectedURL: URL,
        maximumBytes: Int,
        allowedStatusCodes: Set<Int>,
        emptyBodyStatusCodes: Set<Int>,
        sessionConfiguration: URLSessionConfiguration = .ephemeral) {
        responseValidator = AgentResponseValidator(
            expectedURL: expectedURL,
            maximumBytes: maximumBytes,
            allowedStatusCodes: allowedStatusCodes,
            emptyBodyStatusCodes: emptyBodyStatusCodes)
        self.sessionConfiguration = sessionConfiguration
    }

    func load(_ request: URLRequest) async throws -> HTTPURLResponse {
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
        let hasContinuation = continuation != nil
        lock.unlock()

        if hasContinuation {
            finish(.failure(CancellationError()))
        }
    }

    private func finish(_ result: Result<HTTPURLResponse, Error>) {
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
        guard let httpResponse = response as? HTTPURLResponse else {
            completionHandler(.cancel)
            finish(.failure(AgentHubClientError.invalidResponse))
            return
        }

        lock.lock()
        guard !completed else {
            lock.unlock()
            completionHandler(.cancel)
            return
        }
        do {
            try responseValidator.receive(
                responseURL: httpResponse.url,
                statusCode: httpResponse.statusCode,
                expectedContentLength: httpResponse.expectedContentLength)
            receivedResponse = httpResponse
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
            try responseValidator.receive(data)
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
        let result: Result<HTTPURLResponse, Error>
        do {
            try responseValidator.validateCompletion()
            guard let receivedResponse else {
                throw AgentHubClientError.invalidResponse
            }
            result = .success(receivedResponse)
        } catch {
            result = .failure(error)
        }
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
        finish(.failure(AgentHubClientError.redirectedResponse))
        task.cancel()
    }
}
