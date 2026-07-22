import XCTest
@testable import Toki

final class SecurityAuditScannerCancellationTests: SecurityAuditScannerTestCase {
    func testCanceledFullFileScanDoesNotCachePartialResult() async throws {
        let cacheStore = cache()
        _ = try writeFixture(
            sourceName: "Codex",
            relativePath: "2026/05/12/session.jsonl",
            lines: [
                #"{"text":"cache-secret-ABCDEFGHIJKLMNOP"}"#,
                #"{"text":"cache-secret-ZYXWVUTSRQPONMLK"}"#,
            ])
        let gate = SecurityAuditValidatorGate()
        let cancelingScanner = scanner(
            for: ["Codex"],
            rules: [blockingRule(gate: gate)],
            cacheStore: cacheStore)

        let canceledScan = Task {
            await cancelingScanner.scan()
        }
        let didReachValidation = await gate.waitForValidation()
        XCTAssertTrue(didReachValidation)
        canceledScan.cancel()
        gate.release()
        _ = await canceledScan.value

        let result = await scanner(
            for: ["Codex"],
            rules: [countingRule(counter: SecurityAuditValidatorCounter())],
            cacheStore: cacheStore)
            .scan()

        XCTAssertEqual(result.findings.map(\.location.lineNumber), [1, 2])
    }

    func testCanceledAppendedScanDoesNotCachePartialResult() async throws {
        let cacheStore = cache()
        let file = try writeFixture(
            sourceName: "Codex",
            relativePath: "2026/05/12/session.jsonl",
            lines: [#"{"text":"cache-secret-ABCDEFGHIJKLMNOP"}"#])
        try append("\n", to: file)
        let initialResult = await scanner(
            for: ["Codex"],
            rules: [countingRule(counter: SecurityAuditValidatorCounter())],
            cacheStore: cacheStore)
            .scan()
        XCTAssertEqual(initialResult.findings.count, 1)

        try append(#"{"text":"cache-secret-ZYXWVUTSRQPONMLK"}"# + "\n", to: file)
        try append(#"{"text":"cache-secret-QWERTYUIOPASDFGH"}"# + "\n", to: file)
        let gate = SecurityAuditValidatorGate()
        let cancelingScanner = scanner(
            for: ["Codex"],
            rules: [blockingRule(gate: gate)],
            cacheStore: cacheStore)

        let canceledScan = Task {
            await cancelingScanner.scan()
        }
        let didReachValidation = await gate.waitForValidation()
        XCTAssertTrue(didReachValidation)
        canceledScan.cancel()
        gate.release()
        _ = await canceledScan.value

        let result = await scanner(
            for: ["Codex"],
            rules: [countingRule(counter: SecurityAuditValidatorCounter())],
            cacheStore: cacheStore)
            .scan()

        XCTAssertEqual(result.findings.map(\.location.lineNumber), [1, 2, 3])
    }
}
