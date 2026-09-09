import Foundation
import XCTest
@testable import TokiUsageReaders

final class SourceCoverageManifestTests: XCTestCase {
    func test_manifestExactlyCoversPinnedRegistryWithoutDuplicateClients() throws {
        let manifest = try load("tokscale-coverage.json")
        let pinned = try load("tokscale-clients.pinned.json")
        let clients = try XCTUnwrap(manifest["clients"] as? [[String: Any]])
        let reference = try XCTUnwrap(pinned["clients"] as? [[String: Any]])
        let ids = clients.compactMap { $0["clientID"] as? String }
        XCTAssertEqual(ids.count, 53)
        XCTAssertEqual(Set(ids).count, ids.count)
        XCTAssertEqual(Set(ids), Set(reference.compactMap { $0["clientID"] as? String }))
        let expectedIDs = Set("""
        opencode claude codex cursor gemini amp droid openclaw pi kimi qwen roocode kilocode mux kilo crush
        hermes copilot goose codebuff antigravity zed kiro trae warp cline gjc grok jcode commandcode micode
        antigravity-cli junie zcode opencodereview codebuddy workbuddy devin-cli devin-desktop senpi augment
        kimchi reasonix prime-agent freebuff cherrystudio dsh mcode fx omp lmstudio unsloth hindsight
        """.split(whereSeparator: { $0.isWhitespace }).map(String.init))
        XCTAssertEqual(
            Set(ids), expectedIDs, "Changing both JSON documents must not silently change the pinned inventory")
        XCTAssertEqual(pinned["pinnedSHA"] as? String, "3bd6dceb98925edab4e149c9bb1cf3fec9123f17")
        XCTAssertEqual(reference.count, 53)
        XCTAssertEqual(reference.compactMap { $0["index"] as? Int }, Array(0..<53))
        for client in clients {
            XCTAssertEqual(client["pinnedSHA"] as? String, "3bd6dceb98925edab4e149c9bb1cf3fec9123f17")
            for field in [
                "os",
                "defaultPaths",
                "overridePaths",
                "formats",
                "modelStatus",
                "tokenStatus",
                "pricingStatus",
                "fixtureEvidence",
                "reader",
                "status",
                "limitations",
            ] {
                XCTAssertNotNil(client[field], "Missing \(field) in \(client["clientID"] ?? "?")")
            }
            XCTAssertTrue(["existing", "planned", "implemented", "verified", "blocked"]
                .contains(client["status"] as? String ?? ""))
            if client["status"] as? String == "verified" {
                XCTAssertFalse((client["fixtureEvidence"] as? [String] ?? []).isEmpty)
                let verification = try XCTUnwrap(client["verification"] as? [String: Any])
                XCTAssertEqual(verification["green"] as? String, "verified")
            }
            for evidence in client["fixtureEvidence"] as? [String] ?? [] {
                XCTAssertTrue(FileManager.default.fileExists(atPath: repository.appendingPathComponent(evidence).path))
            }
        }
    }

    func test_common18MapToAll19RegisteredReadersAndMissing35HaveNone() throws {
        let clients = try XCTUnwrap(load("tokscale-coverage.json")["clients"] as? [[String: Any]])
        let common = clients.filter { !($0["readerNames"] as? [String] ?? []).isEmpty }
        XCTAssertEqual(common.count, 18)
        XCTAssertEqual(clients.count - common.count, 35)
        let names = common.flatMap { $0["readerNames"] as? [String] ?? [] }
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let actual = LocalUsageReaderRegistry.agentDescriptors(home: home, environment: [:]).map(\.name)
        XCTAssertEqual(Set(names), Set(actual))
        XCTAssertEqual(names.count, actual.count)
        XCTAssertEqual(
            common.first { $0["clientID"] as? String == "kimi" }?["readerNames"] as? [String],
            ["Kimi CLI", "Kimi Code"])
        for client in common {
            for path in client["reader"] as? [String] ?? [] {
                XCTAssertTrue(
                    FileManager.default.fileExists(atPath: repository.appendingPathComponent(path).path), path)
            }
        }
        for client in clients where (client["readerNames"] as? [String] ?? []).isEmpty {
            XCTAssertEqual(client["status"] as? String, "planned")
            XCTAssertEqual(client["disposition"] as? String, "deferred-new-client")
            XCTAssertEqual(client["reader"] as? [String], [])
            XCTAssertFalse((client["limitations"] as? [String] ?? []).isEmpty)
        }
    }

    private var repository: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
    }

    private func load(_ name: String) throws -> [String: Any] {
        let data = try Data(contentsOf: repository.appendingPathComponent("docs/compatibility/\(name)"))
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }
}
