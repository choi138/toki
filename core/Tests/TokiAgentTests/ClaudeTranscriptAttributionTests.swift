import Foundation
import TokiUsageCore
import TokiUsageReaders
import XCTest

final class ClaudeTranscriptAttributionTests: XCTestCase {
    func testTranscriptRootProvenancePreservesUnknownAndExactAttributionAcrossCaches() async throws {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("claude-attribution-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: home) }
        let projects = home.appendingPathComponent(".claude/projects")
        let encodedHome = home.path.replacingOccurrences(of: "/", with: "-")
        let projectFile = projects.appendingPathComponent("\(encodedHome)-transcripts/project.jsonl")
        try writeRecord(at: projectFile, session: "project")

        for rootName in ["transcripts", "arbitrary-storage"] {
            let transcripts = home.appendingPathComponent(rootName)
            try writeRecord(at: transcripts.appendingPathComponent("direct.jsonl"), session: "direct")
            try writeRecord(at: transcripts.appendingPathComponent("nested/deep.jsonl"), session: "nested")
            try writeRecord(
                at: transcripts.appendingPathComponent("exact.jsonl"),
                session: "exact", cwd: "/synthetic/work/real-project")
            let cacheURL = home.appendingPathComponent("\(rootName)-cache/usage.json")
            let cache = ClaudeUsageCache(cacheURL: cacheURL)
            // First read is cold, second uses memory, third reloads the private disk cache.
            for activeCache in [cache, cache, ClaudeUsageCache(cacheURL: cacheURL)] {
                let reader = ClaudeCodeReader(
                    projectsURLOverride: projects, usageCache: activeCache,
                    transcriptsURLOverride: transcripts, attributionHomeDirectory: home)
                let usage = try await reader.readUsage(
                    from: Date(timeIntervalSince1970: 0), to: .distantFuture)
                XCTAssertEqual(usage.inputTokens, 40)
                XCTAssertEqual(usage.outputTokens, 8)
                XCTAssertEqual(usage.tokenEvents.count, 4)
                let bySession = Dictionary(uniqueKeysWithValues: usage.tokenEvents.compactMap { event in
                    event.attribution.map { ($0.sessionID ?? "missing", $0) }
                })
                for session in ["direct", "nested"] {
                    let attribution = try XCTUnwrap(bySession[session])
                    XCTAssertNil(attribution.projectName, "Transcript storage must not become a project")
                    XCTAssertNil(attribution.projectPath, "Transcript root provenance must suppress folder fallback")
                    XCTAssertEqual(attribution.quality, .unknown)
                    XCTAssertEqual(attribution.sessionID, session)
                }
                XCTAssertEqual(bySession["exact"]?.projectPath, "/synthetic/work/real-project")
                XCTAssertEqual(bySession["exact"]?.quality, .exact)
                XCTAssertEqual(bySession["exact"]?.sessionID, "exact")
                XCTAssertEqual(bySession["project"]?.projectName, "transcripts")
                XCTAssertEqual(bySession["project"]?.quality, .inferred)
            }
        }
    }

    private func writeRecord(at file: URL, session: String, cwd: String? = nil) throws {
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        var record: [String: Any] = [
            "type": "assistant", "timestamp": "2026-04-10T00:00:00Z", "sessionId": session,
            "requestId": session,
            "message": ["model": "claude-sonnet-4-6", "usage": ["input_tokens": 10, "output_tokens": 2]],
        ]
        record["cwd"] = cwd
        try JSONSerialization.data(withJSONObject: record).write(to: file)
    }
}
