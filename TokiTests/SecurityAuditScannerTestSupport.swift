import Foundation
import XCTest
@testable import Toki

class SecurityAuditScannerTestCase: XCTestCase {
    var tempRoot: URL!

    override func setUpWithError() throws {
        tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("TokiSecurityAuditTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: tempRoot,
            withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempRoot)
    }

    func scanner(
        for sourceNames: [String],
        rules: [SecurityAuditRule] = SecurityAuditRules.defaults,
        cacheStore: (any SecurityAuditCacheStoring)? = nil) -> SecurityAuditScanner {
        SecurityAuditScanner(
            sources: sourceDefinitions(for: sourceNames),
            rules: rules,
            cacheStore: cacheStore)
    }

    func sourceDefinitions(for sourceNames: [String]) -> [SecurityAuditFileSource] {
        SecurityAuditScanner.defaultSources(homeDirectory: tempRoot, environment: [:])
            .filter { sourceNames.contains($0.name) }
    }

    @discardableResult
    func writeFixture(
        sourceName: String,
        relativePath: String,
        lines: [String]) throws -> URL {
        let root = SecurityAuditScanner.defaultSources(homeDirectory: tempRoot, environment: [:])
            .first { $0.name == sourceName }!
            .rootURL
        let url = root.appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true)
        try lines.joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    func append(_ text: String, to url: URL) throws {
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(text.utf8))
    }

    func cache() -> SecurityAuditCacheStore {
        SecurityAuditCacheStore(cacheURL: tempRoot.appendingPathComponent("SecurityAuditCache.json"))
    }

    func countingRule(counter: SecurityAuditValidatorCounter) -> SecurityAuditRule {
        SecurityAuditRule(
            name: "Counting test secret",
            severity: .high,
            category: .apiKey,
            pattern: #"cache-secret-[A-Z]{16}"#,
            prefilter: { $0.contains("cache-secret-") },
            validator: { _ in
                counter.count += 1
                return true
            })
    }

    func blockingRule(gate: SecurityAuditValidatorGate) -> SecurityAuditRule {
        SecurityAuditRule(
            name: "Blocking test secret",
            severity: .high,
            category: .apiKey,
            pattern: #"cache-secret-[A-Z]{16}"#,
            prefilter: { $0.contains("cache-secret-") },
            validator: { _ in gate.validate() })
    }

    func inertRule() -> SecurityAuditRule {
        SecurityAuditRule(
            name: "Inactive test secret",
            severity: .high,
            category: .apiKey,
            pattern: #"inactive-secret-[A-Z]{16}"#,
            prefilter: { $0.contains("inactive-secret-") })
    }
}

enum SecurityAuditTestSecret {
    static var openAIKey: String {
        "sk" + "-proj-" + longSecretTail
    }

    static var anthropicKey: String {
        "sk" + "-ant-api03-" + longSecretTail
    }

    static var googleKey: String {
        "AIza" + "abcdefghijklmnopqrstuvwxyzABCDE1234"
    }

    static var githubToken: String {
        "gh" + "p_" + shortTokenTail
    }

    static var npmToken: String {
        "npm" + "_" + shortTokenTail
    }

    static var slackToken: String {
        "xox" + "b-" + "abcdefghijklmnopqrst"
    }

    static var awsKeyID: String {
        "AKIA" + "1234567890ABCDEF"
    }

    static var awsSessionKeyID: String {
        "ASIA" + "1234567890ABCDEF"
    }

    static var privateKeyHeader: String {
        "-----BEGIN " + "OPENSSH PRIVATE KEY" + "-----"
    }

    static var jwt: String {
        [
            "eyJhbGciOiJIUzI1NiJ9",
            "eyJzdWIiOiIxMjM0NTY3ODkwIn0",
            "signature1234567890",
        ].joined(separator: ".")
    }

    static var invalidJWT: String {
        [
            "eyJnotreallyheader",
            "invalidpayload",
            "invalidsignature",
        ].joined(separator: ".")
    }

    static var assignmentValue: String {
        "Actual" + "Secret" + "Value12345"
    }

    private static let longSecretTail = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMN1234567890"
    private static let shortTokenTail = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJ"
}

final class SecurityAuditValidatorCounter {
    var count = 0
}

final class SecurityAuditValidatorGate {
    private let firstValidation = DispatchSemaphore(value: 0)
    private let releaseValidation = DispatchSemaphore(value: 0)
    private let stateQueue = DispatchQueue(label: "toki.tests.security-audit-validator-gate")
    private var didBlock = false

    func validate() -> Bool {
        let shouldBlock = stateQueue.sync {
            guard !didBlock else { return false }
            didBlock = true
            return true
        }

        if shouldBlock {
            firstValidation.signal()
            releaseValidation.wait()
        }
        return true
    }

    func waitForValidation(timeout: TimeInterval = 1) async -> Bool {
        await Task.detached {
            self.waitForValidationSynchronously(timeout: timeout)
        }.value
    }

    func release() {
        releaseValidation.signal()
    }

    private func waitForValidationSynchronously(timeout: TimeInterval) -> Bool {
        let milliseconds = Int(timeout * 1000)
        return firstValidation.wait(timeout: .now() + .milliseconds(milliseconds)) == .success
    }
}
