import XCTest
@testable import Toki

final class SecurityAuditScannerRuleTests: SecurityAuditScannerTestCase {
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

    func testDefaultSourcesIncludeAllUsageReaders() {
        let sourceNames = SecurityAuditScanner.defaultSources(
            homeDirectory: tempRoot,
            environment: [:])
            .map(\.name)

        XCTAssertEqual(
            sourceNames,
            ["Claude Code", "Codex", "Cursor", "Gemini CLI", "OpenCode", "OpenClaw"])
    }

    func testDefaultSourcesUseInjectedOpenCodeDataDirectory() throws {
        let xdgDataDirectory = tempRoot.appendingPathComponent("xdg-data", isDirectory: true)
        let source = try XCTUnwrap(
            SecurityAuditScanner.defaultSources(
                homeDirectory: tempRoot,
                environment: ["XDG_DATA_HOME": xdgDataDirectory.path])
                .first { $0.name == "OpenCode" })

        XCTAssertEqual(
            source.rootURL.standardizedFileURL.path,
            xdgDataDirectory.appendingPathComponent("opencode").standardizedFileURL.path)
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
}
