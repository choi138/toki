import Foundation
import TokiUsageReaders
import XCTest

final class LandingOpenCodeSessionLabelTests: XCTestCase {
    func test_untitledSessionsUseRawIDsWhileExplicitTitlesWin() async throws {
        let fixture = try OpenCodeFixture()
        defer { fixture.remove() }
        let untitled = try OpenCodeTestDatabase(
            at: fixture.root.appendingPathComponent("untitled/opencode.db"))
        for (id, session) in [("first", "raw-session-alpha"), ("second", "raw-session-beta")] {
            try untitled.insert(
                fixture.payload(id: id, sessionID: session),
                id: id,
                session: session)
        }
        let titled = try OpenCodeTestDatabase(
            at: fixture.root.appendingPathComponent("titled/opencode.db"),
            schema: OpenCodeTestDatabase.v2Schema)
        try titled.execute(
            "INSERT INTO session_v2 VALUES ('raw-session-titled', '/synthetic/titled', 'Explicit title')")
        try titled.insert(
            fixture.payload(id: "titled", sessionID: "raw-session-titled", v2: true),
            id: "titled",
            session: "raw-session-titled",
            v2: true)

        let usage = try await OpenCodeReader(databaseURLs: [untitled.url, titled.url]).readUsage(
            from: OpenCodeFixture.date.addingTimeInterval(-1),
            to: OpenCodeFixture.date.addingTimeInterval(120))
        let labels = Set(usage.tokenEvents.compactMap(\.attribution?.sessionLabel))

        XCTAssertEqual(labels, ["raw-session-alpha", "raw-session-beta", "Explicit title"])
        XCTAssertEqual(Set(usage.tokenEvents.compactMap(\.attribution?.sessionID)).count, 3)
        XCTAssertTrue(usage.tokenEvents.allSatisfy {
            $0.attribution?.sessionID?.hasPrefix("opencode:") == true
        })
    }
}
