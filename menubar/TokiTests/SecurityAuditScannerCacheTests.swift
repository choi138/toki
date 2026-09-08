import XCTest
@testable import Toki

final class SecurityAuditScannerDiscoveryTests: SecurityAuditScannerTestCase {
    func testSymlinkedClaudeRootsAreScannedOnce() async throws {
        let config = tempRoot.appendingPathComponent("aliased-claude")
        let projects = config.appendingPathComponent("projects")
        let file = projects.appendingPathComponent("project/session.jsonl")
        try FileManager.default.createDirectory(
            at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "cache-secret-ABCDEFGHIJKLMNOP".write(to: file, atomically: true, encoding: .utf8)
        try FileManager.default.createSymbolicLink(
            at: config.appendingPathComponent("transcripts"), withDestinationURL: projects)
        let counter = SecurityAuditValidatorCounter()
        let store = cache()
        let scanner = SecurityAuditScanner(
            sources: SecurityAuditScanner.defaultSources(
                homeDirectory: tempRoot, environment: ["CLAUDE_CONFIG_DIR": config.path]),
            rules: [countingRule(counter: counter)], cacheStore: store)

        for _ in 0..<2 {
            let result = await scanner.scan()
            XCTAssertEqual(result.scannedFileCount, 1)
            XCTAssertEqual(result.findings.count, 1)
            XCTAssertEqual(store.load().entriesByPath.count, 1)
        }
        XCTAssertEqual(counter.count, 1)
    }

    func testCustomClaudeTranscriptsAreScannedAndCachedWithProjects() async throws {
        let config = tempRoot.appendingPathComponent("custom-claude")
        let paths = ["projects/project/session.jsonl", "transcripts/nested/session.jsonl"]
        let files = try paths.map { path in
            let file = config.appendingPathComponent(path)
            try FileManager.default.createDirectory(
                at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try "cache-secret-ABCDEFGHIJKLMNOP".write(to: file, atomically: true, encoding: .utf8)
            return file.standardizedFileURL.path
        }
        let counter = SecurityAuditValidatorCounter()
        let store = cache()
        let scanner = SecurityAuditScanner(
            sources: SecurityAuditScanner.defaultSources(
                homeDirectory: tempRoot, environment: ["CLAUDE_CONFIG_DIR": config.path]),
            rules: [countingRule(counter: counter)],
            cacheStore: store)

        for _ in 0..<2 {
            let result = await scanner.scan()
            XCTAssertEqual(result.scannedFileCount, 2, "Both Claude roots must be scanned")
            XCTAssertEqual(Set(result.findings.map(\.location.filePath)), Set(files))
            XCTAssertEqual(result.findings.count, 2)
            XCTAssertTrue(result.findings.allSatisfy { $0.sourceName == "Claude Code" })
            XCTAssertFalse(String(describing: result.findings).contains("cache-secret-ABCDEFGHIJKLMNOP"))
            XCTAssertEqual(Set(store.load().entriesByPath.keys), Set(files))
        }
        XCTAssertEqual(counter.count, 2, "Same-name roots must both survive cache reconciliation")
        let disabled = await scanner.scan(request: SecurityAuditRequest(enabledSourceNames: ["Claude Code": false]))
        XCTAssertEqual(disabled.scannedFileCount, 0)
        XCTAssertTrue(disabled.findings.isEmpty)
        XCTAssertEqual(disabled.skippedSourceNames, ["Claude Code"])
        XCTAssertEqual(Set(store.load().entriesByPath.keys), Set(files))
    }
}

final class SecurityAuditScannerCacheTests: SecurityAuditScannerTestCase {
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

    func testScannerDoesNotAdvanceCacheForInvalidUTF8Append() async throws {
        let file = try writeFixture(
            sourceName: "Codex",
            relativePath: "2026/05/12/session.jsonl",
            lines: [#"{"text":"cache-secret-ABCDEFGHIJKLMNOP"}"#])
        try append("\n", to: file)
        let cacheStore = cache()
        let scanner = scanner(
            for: ["Codex"],
            rules: [countingRule(counter: SecurityAuditValidatorCounter())],
            cacheStore: cacheStore)

        let firstResult = await scanner.scan()
        let path = file.standardizedFileURL.path
        let initialOffset = try XCTUnwrap(cacheStore.load().entriesByPath[path]?.byteOffset)
        let handle = try FileHandle(forWritingTo: file)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data([0xFF]))
        try handle.close()

        let secondResult = await scanner.scan()
        let offsetAfterFailedAppend = try XCTUnwrap(cacheStore.load().entriesByPath[path]?.byteOffset)

        XCTAssertEqual(firstResult.findings.count, 1)
        XCTAssertEqual(secondResult.findings, firstResult.findings)
        XCTAssertEqual(offsetAfterFailedAppend, initialOffset)
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
}
