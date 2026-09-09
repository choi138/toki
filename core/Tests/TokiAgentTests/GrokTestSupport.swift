import Foundation
import XCTest

/// Synthetic fixtures, never personal sessions. Layout and field semantics were derived by
/// inspecting a local Grok CLI install (`@xai-official/grok` 1.0.24), which writes
/// `sessions/<percent-encoded cwd>/<session id>/usage.json` alongside `summary.json`.
final class GrokFixture {
    static let date = Date(timeIntervalSince1970: 1_787_227_200) // 2026-08-20 12:00 UTC

    let home: URL

    var sessionsRoot: URL {
        home.appendingPathComponent(".grok/sessions")
    }

    init() throws {
        home = FileManager.default.temporaryDirectory
            .resolvingSymlinksInPath()
            .appendingPathComponent("toki-grok-fixture-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
    }

    func remove() {
        try? FileManager.default.removeItem(at: home)
    }

    static func iso(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }

    /// Grok repeats these field names at the session, turn, and per-model levels.
    func counts(
        input: Int = 1000,
        output: Int = 200,
        cachedRead: Int = 800,
        cacheCreation: Int = 0,
        reasoning: Int = 150,
        ticks: Int64? = 2_500_000_000,
        model: String? = "grok-4.6-build") -> [String: Any] {
        var value: [String: Any] = [
            "inputTokens": input,
            "outputTokens": output,
            "cachedReadTokens": cachedRead,
            "cacheCreationTokens": cacheCreation,
            "reasoningTokens": reasoning,
        ]
        value["costUsdTicks"] = ticks
        value["primaryModelId"] = model
        return value
    }

    func turn(
        endedAt: Date,
        _ base: [String: Any]? = nil,
        modelUsage: [String: [String: Any]]? = nil) -> [String: Any] {
        var value = base ?? counts()
        value["endedAt"] = Self.iso(endedAt)
        value["modelUsage"] = modelUsage
        return value
    }

    @discardableResult
    func writeSession(
        id: String = "session-1",
        cwd: String = "/synthetic/project",
        updatedAt: Date = GrokFixture.date,
        turns: [[String: Any]],
        session: [String: Any]? = nil,
        title: String? = "Synthetic session",
        summaryCWD: String? = nil,
        root: URL? = nil) throws -> URL {
        let directory = (root ?? sessionsRoot)
            .appendingPathComponent(Self.encoded(cwd))
            .appendingPathComponent(id)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var document: [String: Any] = [
            "sessionId": id,
            "updatedAt": Self.iso(updatedAt),
            "turns": turns,
        ]
        document["session"] = session
        try write(document, to: directory.appendingPathComponent("usage.json"))
        if title != nil || summaryCWD != nil {
            var summary: [String: Any] = [:]
            summary["generated_title"] = title
            if let summaryCWD { summary["info"] = ["cwd": summaryCWD] }
            try write(summary, to: directory.appendingPathComponent("summary.json"))
        }
        return directory
    }

    /// Returns the usage.json URL so a test can pin its modification date, which the reader
    /// uses as the fallback timestamp when a record carries no `endedAt` or `updatedAt`.
    @discardableResult
    func writeRawUsage(
        _ contents: String,
        id: String,
        cwd: String = "/synthetic/project",
        modifiedAt: Date? = nil) throws -> URL {
        let directory = sessionsRoot
            .appendingPathComponent(Self.encoded(cwd))
            .appendingPathComponent(id)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("usage.json")
        try Data(contents.utf8).write(to: url)
        if let modifiedAt {
            try FileManager.default.setAttributes(
                [.modificationDate: modifiedAt], ofItemAtPath: url.path)
        }
        return url
    }

    private func write(_ value: [String: Any], to url: URL) throws {
        let data = try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])
        try data.write(to: url)
    }

    private static func encoded(_ cwd: String) -> String {
        cwd.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? cwd
    }
}
