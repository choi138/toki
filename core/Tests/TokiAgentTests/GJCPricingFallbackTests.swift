import Foundation
import XCTest
@testable import TokiUsageReaders

final class GJCPricingFallbackTests: XCTestCase {
    func test_costlessUsagePreservesPricingFallbackState() {
        let lines = [
            #"{"type":"session","id":"priceable-gjc","timestamp":"2026-08-01T08:00:00Z"}"#,
            [
                #"{"type":"message","id":"priceable-message","#,
                #""timestamp":"2026-08-01T12:00:00Z","message":{"role":"assistant","#,
                #""model":"gpt-5","provider":"openai","usage":{"input":7,"output":5}}}"#,
            ].joined(),
        ]
        let usage = GJCReader.usage(
            fromJSONLLines: lines,
            streamID: "/tmp/priceable-gjc.jsonl",
            from: gjcTestDate("2026-08-01T00:00:00Z"),
            to: gjcTestDate("2026-08-02T00:00:00Z"))

        XCTAssertNil(usage.tokenEvents.first?.costIsKnown)
        XCTAssertEqual(usage.tokenEvents.first?.cost, 0)
    }
}

private func gjcTestDate(_ value: String) -> Date {
    ISO8601DateFormatter().date(from: value)!
}
