import Foundation

#if canImport(FoundationNetworking)
    import FoundationNetworking
#endif

import XCTest
@testable import TokiAgentCore

final class AgentHubClientTests: XCTestCase {
    func test_responseValidatorAcceptsChunkedResponseAtLimit() throws {
        let url = try XCTUnwrap(URL(string: "https://hub.example.test/upload"))
        var validator = makeValidator(url: url)

        try validator.receive(responseURL: url, statusCode: 200, expectedContentLength: -1)
        try validator.receive(Data(repeating: 0x61, count: 32))
        try validator.receive(Data(repeating: 0x61, count: 32))

        XCTAssertNoThrow(try validator.validateCompletion())
    }

    func test_responseValidatorRejectsChunkedResponseOverLimit() throws {
        let url = try XCTUnwrap(URL(string: "https://hub.example.test/upload"))
        var validator = makeValidator(url: url)
        try validator.receive(responseURL: url, statusCode: 200, expectedContentLength: -1)
        try validator.receive(Data(repeating: 0x61, count: 32))

        XCTAssertThrowsError(try validator.receive(Data(repeating: 0x61, count: 33))) { error in
            guard let clientError = error as? AgentHubClientError,
                  case .responseTooLarge = clientError else {
                return XCTFail("Expected responseTooLarge, got \(error)")
            }
        }
    }

    func test_responseValidatorRejectsOversizedDeclaredLength() throws {
        let url = try XCTUnwrap(URL(string: "https://hub.example.test/upload"))
        var validator = makeValidator(url: url)

        XCTAssertThrowsError(
            try validator.receive(responseURL: url, statusCode: 200, expectedContentLength: 65)) { error in
                guard let clientError = error as? AgentHubClientError,
                      case .responseTooLarge = clientError else {
                    return XCTFail("Expected responseTooLarge, got \(error)")
                }
            }
    }

    func test_responseValidatorRejectsUnexpectedResponseURL() throws {
        let expectedURL = try XCTUnwrap(URL(string: "https://hub.example.test/upload"))
        let redirectedURL = try XCTUnwrap(URL(string: "https://other.example.test/upload"))
        var validator = makeValidator(url: expectedURL)

        XCTAssertThrowsError(
            try validator.receive(responseURL: redirectedURL, statusCode: 200, expectedContentLength: -1)) { error in
                guard let clientError = error as? AgentHubClientError,
                      case .redirectedResponse = clientError else {
                    return XCTFail("Expected redirectedResponse, got \(error)")
                }
            }
    }

    func test_boundedLoaderAcceptsChunkedResponseAtLimit() async throws {
        let server = try LoopbackHTTPServer(
            response: .chunked(body: Data(repeating: 0x61, count: 64)))
        defer { server.stop() }

        let response = try await makeLoader(url: server.url, maximumBytes: 64)
            .load(URLRequest(url: server.url))

        XCTAssertEqual(response.statusCode, 200)
    }

    func test_boundedLoaderRejectsChunkedResponseOverLimit() async throws {
        let server = try LoopbackHTTPServer(
            response: .chunked(body: Data(repeating: 0x61, count: 65)))
        defer { server.stop() }

        do {
            _ = try await makeLoader(url: server.url, maximumBytes: 64)
                .load(URLRequest(url: server.url))
            XCTFail("Expected the oversized response to fail")
        } catch let error as AgentHubClientError {
            guard case .responseTooLarge = error else {
                return XCTFail("Expected responseTooLarge, got \(error)")
            }
        }
    }

    func test_boundedLoaderRejectsRedirect() async throws {
        let redirect = Data(
            "HTTP/1.1 302 Found\r\nLocation: http://127.0.0.1:1/redirected\r\nContent-Length: 0\r\n\r\n".utf8)
        let server = try LoopbackHTTPServer(response: .raw(redirect))
        defer { server.stop() }

        do {
            _ = try await makeLoader(url: server.url, maximumBytes: 64)
                .load(URLRequest(url: server.url))
            XCTFail("Expected the redirect to fail")
        } catch let error as AgentHubClientError {
            guard case .redirectedResponse = error else {
                return XCTFail("Expected redirectedResponse, got \(error)")
            }
        }
    }

    func test_boundedLoaderCancellationCompletesPromptly() async throws {
        let server = try LoopbackHTTPServer(response: .holdOpen)
        defer { server.stop() }
        let task = Task {
            try await makeLoader(url: server.url, maximumBytes: 64)
                .load(URLRequest(url: server.url))
        }
        XCTAssertTrue(server.waitUntilAccepted())

        task.cancel()

        do {
            _ = try await task.value
            XCTFail("Expected cancellation")
        } catch is CancellationError {}
    }

    func test_responseValidatorRejectsUnexpectedSuccessfulStatus() throws {
        let url = try XCTUnwrap(URL(string: "https://hub.example.test/upload"))
        var validator = makeValidator(url: url, allowedStatusCodes: [204], emptyBodyStatusCodes: [204])

        XCTAssertThrowsError(
            try validator.receive(responseURL: url, statusCode: 200, expectedContentLength: 0)) { error in
                guard let clientError = error as? AgentHubClientError,
                      case .httpStatus(200) = clientError else {
                    return XCTFail("Expected httpStatus(200), got \(error)")
                }
            }
    }

    func test_responseValidatorRejectsBodyForNoContentStatus() throws {
        let url = try XCTUnwrap(URL(string: "https://hub.example.test/upload"))
        var validator = makeValidator(url: url, allowedStatusCodes: [204], emptyBodyStatusCodes: [204])
        try validator.receive(responseURL: url, statusCode: 204, expectedContentLength: -1)

        XCTAssertThrowsError(try validator.receive(Data("unexpected".utf8))) { error in
            guard let clientError = error as? AgentHubClientError,
                  case .invalidResponse = clientError else {
                return XCTFail("Expected invalidResponse, got \(error)")
            }
        }
    }

    private func makeLoader(url: URL, maximumBytes: Int) -> AgentBoundedResponseLoader {
        AgentBoundedResponseLoader(
            expectedURL: url,
            maximumBytes: maximumBytes,
            allowedStatusCodes: [200],
            emptyBodyStatusCodes: [])
    }

    private func makeValidator(
        url: URL,
        allowedStatusCodes: Set<Int> = [200],
        emptyBodyStatusCodes: Set<Int> = []) -> AgentResponseValidator {
        AgentResponseValidator(
            expectedURL: url,
            maximumBytes: 64,
            allowedStatusCodes: allowedStatusCodes,
            emptyBodyStatusCodes: emptyBodyStatusCodes)
    }
}
