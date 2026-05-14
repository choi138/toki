import XCTest
@testable import Toki

// swiftlint:disable:next type_body_length
final class SecurityAuditScannerTests: XCTestCase {
    private var tempRoot: URL!

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

    func testScannerDetectsAndMasksKnownSecretPatterns() async throws {
        let openAIKey = SecurityAuditTestSecret.openAIKey
        let anthropicKey = SecurityAuditTestSecret.anthropicKey
        let awsKeyID = SecurityAuditTestSecret.awsKeyID
        let privateKeyHeader = SecurityAuditTestSecret.privateKeyHeader
        let file = try writeFixture(
            sourceName: "Claude Code",
            relativePath: "project/session.jsonl",
            lines: [
                #"{"timestamp":"2026-05-12T01:02:03Z","text":"\#(openAIKey)"}"#,
                #"{"timestamp":"2026-05-12T01:02:04Z","text":"\#(anthropicKey)"}"#,
                #"{"timestamp":"2026-05-12T01:02:05Z","text":"\#(awsKeyID)"}"#,
                #"{"timestamp":"2026-05-12T01:02:06Z","text":"\#(privateKeyHeader)"}"#,
            ])

        let result = await scanner(for: ["Claude Code"]).scan()

        XCTAssertEqual(result.scannedFileCount, 1)
        XCTAssertEqual(result.scannedLineCount, 4)
        XCTAssertEqual(Set(result.findings.map(\.ruleName)), [
            "OpenAI API key",
            "Anthropic API key",
            "AWS access key ID",
            "Private key block",
        ])
        XCTAssertTrue(result.findings.allSatisfy { $0.location.filePath == file.standardizedFileURL.path })
        XCTAssertFalse(result.findings.contains { $0.maskedEvidence.contains(openAIKey) })
        XCTAssertFalse(result.findings.contains { $0.maskedEvidence.contains(anthropicKey) })
        XCTAssertFalse(String(describing: result.findings).contains(openAIKey))
        XCTAssertFalse(String(describing: result.findings).contains(anthropicKey))
    }

    func testDefaultRulesStillDetectKnownPatternsAndPreserveTimestamps() async throws {
        let timestamp = "2026-05-12T01:02:03Z"
        let openAIKey = SecurityAuditTestSecret.openAIKey
        let anthropicKey = SecurityAuditTestSecret.anthropicKey
        let googleKey = SecurityAuditTestSecret.googleKey
        let githubToken = SecurityAuditTestSecret.githubToken
        let npmToken = SecurityAuditTestSecret.npmToken
        let slackToken = SecurityAuditTestSecret.slackToken
        let awsKeyID = SecurityAuditTestSecret.awsSessionKeyID
        let jwt = SecurityAuditTestSecret.jwt
        let secretValue = SecurityAuditTestSecret.assignmentValue
        _ = try writeFixture(
            sourceName: "Claude Code",
            relativePath: "project/defaults.jsonl",
            lines: [
                #"{"timestamp":"\#(timestamp)","text":"\#(openAIKey)"}"#,
                #"{"timestamp":"\#(timestamp)","text":"\#(anthropicKey)"}"#,
                #"{"timestamp":"\#(timestamp)","text":"\#(googleKey)"}"#,
                #"{"timestamp":"\#(timestamp)","text":"\#(githubToken)"}"#,
                #"{"timestamp":"\#(timestamp)","text":"\#(npmToken)"}"#,
                #"{"timestamp":"\#(timestamp)","text":"\#(slackToken)"}"#,
                #"{"timestamp":"\#(timestamp)","text":"\#(awsKeyID)"}"#,
                #"{"timestamp":"\#(timestamp)","text":"\#(SecurityAuditTestSecret.privateKeyHeader)"}"#,
                #"{"timestamp":"\#(timestamp)","text":"\#(jwt)"}"#,
                #"{"timestamp":"\#(timestamp)","env":"openai_api_key=\#(secretValue)"}"#,
            ])

        let result = await scanner(for: ["Claude Code"]).scan()

        XCTAssertEqual(Set(result.findings.map(\.ruleName)), [
            "OpenAI API key",
            "Anthropic API key",
            "Google API key",
            "GitHub token",
            "npm token",
            "Slack token",
            "AWS access key ID",
            "Private key block",
            "JWT",
            "Secret assignment",
        ])
        XCTAssertEqual(result.findings.count, 10)
        XCTAssertTrue(result.findings.allSatisfy {
            $0.detectedAt == tokiTestISODate(timestamp)
        })
    }

    func testScannerAvoidsCommonPlaceholdersAndInvalidJWTs() async throws {
        _ = try writeFixture(
            sourceName: "Codex",
            relativePath: "2026/05/12/session.jsonl",
            lines: [
                #"{"timestamp":"2026-05-12T01:02:03Z","env":"OPENAI_API_KEY=your_api_key_here"}"#,
                #"{"timestamp":"2026-05-12T01:02:04Z","env":"GITHUB_TOKEN=test-token-value"}"#,
                #"{"timestamp":"2026-05-12T01:02:05Z","text":"\#(SecurityAuditTestSecret.invalidJWT)"}"#,
            ])

        let result = await scanner(for: ["Codex"]).scan()

        XCTAssertTrue(result.findings.isEmpty)
        XCTAssertEqual(result.scannedLineCount, 3)
    }

    func testScannerRespectsDisabledSources() async throws {
        let codexToken = SecurityAuditTestSecret.githubToken
        let claudeToken = SecurityAuditTestSecret.npmToken
        _ = try writeFixture(
            sourceName: "Codex",
            relativePath: "2026/05/12/session.jsonl",
            lines: [#"{"text":"\#(codexToken)"}"#])
        _ = try writeFixture(
            sourceName: "Claude Code",
            relativePath: "project/session.jsonl",
            lines: [#"{"text":"\#(claudeToken)"}"#])

        let result = await scanner(for: ["Codex", "Claude Code"]).scan(
            request: SecurityAuditRequest(enabledSourceNames: ["Claude Code": false]))

        XCTAssertEqual(result.skippedSourceNames, ["Claude Code"])
        XCTAssertEqual(result.findings.map(\.sourceName), ["Codex"])
        XCTAssertEqual(result.findings.first?.ruleName, "GitHub token")
    }

    func testScannerReportsLineLocationAndEventDate() async throws {
        let githubToken = SecurityAuditTestSecret.githubToken
        _ = try writeFixture(
            sourceName: "OpenClaw",
            relativePath: "agent/run.jsonl",
            lines: [
                #"{"timestamp":"2026-05-12T01:02:03Z","text":"ordinary line"}"#,
                #"{"timestamp":"2026-05-12T01:02:04Z","text":"token \#(githubToken)"}"#,
            ])

        let result = await scanner(for: ["OpenClaw"]).scan()

        XCTAssertEqual(result.scannedLineCount, 2)
        XCTAssertEqual(result.findings.count, 1)
        XCTAssertEqual(result.findings[0].location.lineNumber, 2)
        XCTAssertEqual(result.findings[0].sourceName, "OpenClaw")
        XCTAssertEqual(result.findings[0].detectedAt, tokiTestISODate("2026-05-12T01:02:04Z"))
    }

    func testScannerReportsFileProgress() async throws {
        _ = try writeFixture(
            sourceName: "Codex",
            relativePath: "2026/05/12/first.jsonl",
            lines: [#"{"text":"ordinary line"}"#])
        _ = try writeFixture(
            sourceName: "Codex",
            relativePath: "2026/05/12/second.jsonl",
            lines: [#"{"text":"cache-secret-ABCDEFGHIJKLMNOP"}"#])
        var updates: [SecurityAuditProgress] = []

        let result = await scanner(
            for: ["Codex"],
            rules: [countingRule(counter: SecurityAuditValidatorCounter())],
            cacheStore: cache())
            .scan(progress: { updates.append($0) })

        XCTAssertEqual(result.scannedFileCount, 2)
        XCTAssertEqual(updates.last?.phase, .finished)
        XCTAssertEqual(updates.last?.completedFileCount, 2)
        XCTAssertEqual(updates.last?.totalFileCount, 2)
        XCTAssertTrue(updates.contains { $0.phase == .discovering })
        XCTAssertTrue(updates.contains { $0.phase == .scanning && $0.completedFileCount == 1 })
    }

    func testScannerReusesCachedFindingsForUnchangedFiles() async throws {
        let counter = SecurityAuditValidatorCounter()
        let file = try writeFixture(
            sourceName: "Codex",
            relativePath: "2026/05/12/session.jsonl",
            lines: [#"{"text":"cache-secret-ABCDEFGHIJKLMNOP"}"#])
        let scanner = scanner(
            for: ["Codex"],
            rules: [countingRule(counter: counter)],
            cacheStore: cache())

        let firstResult = await scanner.scan()
        let secondResult = await scanner.scan()

        XCTAssertEqual(firstResult.findings.count, 1)
        XCTAssertEqual(secondResult.findings, firstResult.findings)
        XCTAssertEqual(counter.count, 1)
        XCTAssertEqual(secondResult.findings.first?.location.filePath, file.standardizedFileURL.path)
    }

    func testScannerInvalidatesCacheWhenRuleSetChanges() async throws {
        let counter = SecurityAuditValidatorCounter()
        _ = try writeFixture(
            sourceName: "Codex",
            relativePath: "2026/05/12/session.jsonl",
            lines: [#"{"text":"cache-secret-ABCDEFGHIJKLMNOP"}"#])
        let cacheStore = cache()

        let firstScanner = scanner(
            for: ["Codex"],
            rules: [inertRule()],
            cacheStore: cacheStore)
        let secondScanner = scanner(
            for: ["Codex"],
            rules: [countingRule(counter: counter)],
            cacheStore: cacheStore)

        let firstResult = await firstScanner.scan()
        let secondResult = await secondScanner.scan()

        XCTAssertTrue(firstResult.findings.isEmpty)
        XCTAssertEqual(secondResult.findings.count, 1)
        XCTAssertEqual(counter.count, 1)
    }

    func testScannerRescansChangedFiles() async throws {
        let counter = SecurityAuditValidatorCounter()
        let file = try writeFixture(
            sourceName: "Codex",
            relativePath: "2026/05/12/session.jsonl",
            lines: [#"{"text":"cache-secret-ABCDEFGHIJKLMNOP"}"#])
        let scanner = scanner(
            for: ["Codex"],
            rules: [countingRule(counter: counter)],
            cacheStore: cache())

        _ = await scanner.scan()
        try #"{"text":"cache-secret-ZYXWVUTSRQPONMLK"}"#.write(to: file, atomically: true, encoding: .utf8)

        let result = await scanner.scan()

        XCTAssertEqual(counter.count, 2)
        XCTAssertEqual(result.findings.count, 1)
        XCTAssertTrue(result.findings[0].maskedEvidence.hasSuffix("MLK"))
    }

    func testScannerRescansSameSizeFilesWhenSignatureChanges() async throws {
        let counter = SecurityAuditValidatorCounter()
        let benignLine = #"{"text":"cache-public-ABCDEFGHIJKLMNOP"}"#
        let secretLine = #"{"text":"cache-secret-ABCDEFGHIJKLMNOP"}"#
        XCTAssertEqual(benignLine.utf8.count, secretLine.utf8.count)

        let file = try writeFixture(
            sourceName: "Codex",
            relativePath: "2026/05/12/session.jsonl",
            lines: [benignLine])
        let modificationDate = try XCTUnwrap(
            FileManager.default.attributesOfItem(atPath: file.path)[.modificationDate] as? Date)
        let scanner = scanner(
            for: ["Codex"],
            rules: [countingRule(counter: counter)],
            cacheStore: cache())

        let firstResult = await scanner.scan()
        try secretLine.write(to: file, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.modificationDate: modificationDate],
            ofItemAtPath: file.path)
        let secondResult = await scanner.scan()

        XCTAssertTrue(firstResult.findings.isEmpty)
        XCTAssertEqual(secondResult.findings.count, 1)
        XCTAssertEqual(counter.count, 1)
    }

    func testScannerScansOnlyAppendedJSONLBytesWhenPrefixMatches() async throws {
        let counter = SecurityAuditValidatorCounter()
        let file = try writeFixture(
            sourceName: "Codex",
            relativePath: "2026/05/12/session.jsonl",
            lines: [#"{"text":"cache-secret-ABCDEFGHIJKLMNOP"}"#])
        try append("\n", to: file)
        let scanner = scanner(
            for: ["Codex"],
            rules: [countingRule(counter: counter)],
            cacheStore: cache())

        let firstResult = await scanner.scan()
        try append(#"{"text":"cache-secret-ZYXWVUTSRQPONMLK"}"# + "\n", to: file)
        let secondResult = await scanner.scan()

        XCTAssertEqual(firstResult.findings.count, 1)
        XCTAssertEqual(secondResult.findings.count, 2)
        XCTAssertEqual(counter.count, 2)
    }

    func testScannerFullyRescansAppendedFileWhenCachedPrefixChanged() async throws {
        let counter = SecurityAuditValidatorCounter()
        let benignMiddle = #"{"text":"cache-public-ABCDEFGHIJKLMNOP"}"#
        let secretMiddle = #"{"text":"cache-secret-ABCDEFGHIJKLMNOP"}"#
        XCTAssertEqual(benignMiddle.utf8.count, secretMiddle.utf8.count)

        let file = try writeFixture(
            sourceName: "Codex",
            relativePath: "2026/05/12/session.jsonl",
            lines: [
                String(repeating: "A", count: 5000),
                benignMiddle,
                String(repeating: "B", count: 5000),
            ])
        try append("\n", to: file)
        let scanner = scanner(
            for: ["Codex"],
            rules: [countingRule(counter: counter)],
            cacheStore: cache())

        let firstResult = await scanner.scan()
        try [
            String(repeating: "A", count: 5000),
            secretMiddle,
            String(repeating: "B", count: 5000),
        ]
        .joined(separator: "\n")
        .appending("\n")
        .write(to: file, atomically: true, encoding: .utf8)
        try append(#"{"text":"cache-secret-ZYXWVUTSRQPONMLK"}"# + "\n", to: file)

        let secondResult = await scanner.scan()

        XCTAssertTrue(firstResult.findings.isEmpty)
        XCTAssertEqual(secondResult.findings.count, 2)
        XCTAssertEqual(counter.count, 2)
    }

    func testScannerRemovesCachedFindingsForDeletedFiles() async throws {
        let file = try writeFixture(
            sourceName: "Claude Code",
            relativePath: "project/session.jsonl",
            lines: [#"{"text":"\#(SecurityAuditTestSecret.openAIKey)"}"#])
        let cacheStore = cache()
        let scanner = scanner(for: ["Claude Code"], cacheStore: cacheStore)

        let firstResult = await scanner.scan()
        try FileManager.default.removeItem(at: file)
        let secondResult = await scanner.scan()

        XCTAssertEqual(firstResult.findings.count, 1)
        XCTAssertTrue(secondResult.findings.isEmpty)
        XCTAssertEqual(cacheStore.load().entriesByPath.count, 0)
    }

    func testScannerFullyRescansTruncatedFiles() async throws {
        let file = try writeFixture(
            sourceName: "Claude Code",
            relativePath: "project/session.jsonl",
            lines: [
                #"{"text":"\#(SecurityAuditTestSecret.openAIKey)"}"#,
                #"{"text":"\#(SecurityAuditTestSecret.anthropicKey)"}"#,
            ])
        let scanner = scanner(for: ["Claude Code"], cacheStore: cache())

        let firstResult = await scanner.scan()
        try #"{"text":"\#(SecurityAuditTestSecret.openAIKey)"}"#.write(
            to: file,
            atomically: true,
            encoding: .utf8)
        let secondResult = await scanner.scan()

        XCTAssertEqual(firstResult.findings.count, 2)
        XCTAssertEqual(secondResult.findings.count, 1)
        XCTAssertEqual(secondResult.findings[0].ruleName, "OpenAI API key")
        XCTAssertEqual(secondResult.scannedLineCount, 1)
    }

    private func scanner(
        for sourceNames: [String],
        rules: [SecurityAuditRule] = SecurityAuditRules.defaults,
        cacheStore: (any SecurityAuditCacheStoring)? = nil) -> SecurityAuditScanner {
        SecurityAuditScanner(
            sources: sourceDefinitions(for: sourceNames),
            rules: rules,
            cacheStore: cacheStore)
    }

    private func sourceDefinitions(for sourceNames: [String]) -> [SecurityAuditFileSource] {
        SecurityAuditScanner.defaultSources(homeDirectory: tempRoot)
            .filter { sourceNames.contains($0.name) }
    }

    @discardableResult
    private func writeFixture(
        sourceName: String,
        relativePath: String,
        lines: [String]) throws -> URL {
        let root = SecurityAuditScanner.defaultSources(homeDirectory: tempRoot)
            .first { $0.name == sourceName }!
            .rootURL
        let url = root.appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true)
        try lines.joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    private func append(_ text: String, to url: URL) throws {
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(text.utf8))
    }

    private func cache() -> SecurityAuditCacheStore {
        SecurityAuditCacheStore(cacheURL: tempRoot.appendingPathComponent("SecurityAuditCache.json"))
    }

    private func countingRule(counter: SecurityAuditValidatorCounter) -> SecurityAuditRule {
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

    private func inertRule() -> SecurityAuditRule {
        SecurityAuditRule(
            name: "Inactive test secret",
            severity: .high,
            category: .apiKey,
            pattern: #"inactive-secret-[A-Z]{16}"#,
            prefilter: { $0.contains("inactive-secret-") })
    }
}

private enum SecurityAuditTestSecret {
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

private final class SecurityAuditValidatorCounter {
    var count = 0
}
