import Foundation
@testable import Toki

final class RemoteHubURLProtocolStub: URLProtocol {
    typealias Handler = (URLRequest) throws -> (HTTPURLResponse, Data)

    private static let lock = NSLock()
    private static var handler: Handler?

    static func install(handler: @escaping Handler) {
        lock.withLock { self.handler = handler }
    }

    static func reset() {
        lock.withLock { handler = nil }
    }

    override static func canInit(with _: URLRequest) -> Bool {
        true
    }

    override static func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        guard let handler = Self.lock.withLock({ Self.handler }) else {
            client?.urlProtocol(self, didFailWithError: RemoteSyncTransportTestError.unexpectedCall)
            return
        }

        do {
            let (response, data) = try handler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            if !data.isEmpty {
                client?.urlProtocol(self, didLoad: data)
            }
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}

final class InMemoryKeychainCredentialStore: KeychainCredentialStoring {
    private var values: [String: String] = [:]
    var failingDeleteAccounts: Set<String> = []

    var savedAccounts: [String] {
        values.keys.sorted()
    }

    func save(_ value: String, account: String) throws {
        values[account] = value
    }

    func read(account: String) throws -> String? {
        values[account]
    }

    func delete(account: String) throws {
        if failingDeleteAccounts.contains(account) {
            throw RemoteSyncTransportTestError.temporaryCredentialFailure
        }
        values.removeValue(forKey: account)
    }

    func accounts(withPrefix prefix: String) throws -> [String] {
        values.keys.filter { $0.hasPrefix(prefix) }.sorted()
    }
}

private extension NSLock {
    func withLock<Value>(_ operation: () -> Value) -> Value {
        lock()
        defer { unlock() }
        return operation()
    }
}

private enum RemoteSyncTransportTestError: Error {
    case temporaryCredentialFailure
    case unexpectedCall
}

func entityTag(_ character: Character) -> String {
    "\"\(String(repeating: character, count: 64))\""
}
