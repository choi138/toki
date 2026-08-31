import Foundation
import TokiUsageCore
import XCTest
@testable import TokiUsageReaders

final class PiFamilyFollowUpTests: XCTestCase {
    func test_ompDefaultProfileHonorsAgentAndConfigRelocation() {
        let home = URL(fileURLWithPath: "/tmp/toki-home")
        let agentOverride = LocalUsageReaderPaths(
            homeDirectory: home,
            environment: ["PI_CODING_AGENT_DIR": "/tmp/omp-agent"])
        let configOverride = LocalUsageReaderPaths(
            homeDirectory: home,
            environment: ["PI_CONFIG_DIR": ".custom-omp"])

        XCTAssertEqual(agentOverride.ompSessions.path, "/tmp/omp-agent/sessions")
        XCTAssertEqual(
            configOverride.ompSessions.path,
            "/tmp/toki-home/.custom-omp/agent/sessions")
    }

    func test_ompNamedProfileRelocatesAndIgnoresAgentOverride() {
        let home = URL(fileURLWithPath: "/tmp/toki-home")
        let named = LocalUsageReaderPaths(
            homeDirectory: home,
            environment: [
                "OMP_PROFILE": "work",
                "PI_CODING_AGENT_DIR": "/tmp/ignored-agent",
            ])
        let legacy = LocalUsageReaderPaths(
            homeDirectory: home,
            environment: ["PI_PROFILE": "legacy"])
        let explicitDefault = LocalUsageReaderPaths(
            homeDirectory: home,
            environment: [
                "OMP_PROFILE": "",
                "PI_PROFILE": "ignored",
            ])

        XCTAssertEqual(
            named.ompSessions.path,
            "/tmp/toki-home/.omp/profiles/work/agent/sessions")
        XCTAssertEqual(
            legacy.ompSessions.path,
            "/tmp/toki-home/.omp/profiles/legacy/agent/sessions")
        XCTAssertEqual(
            explicitDefault.ompSessions.path,
            "/tmp/toki-home/.omp/agent/sessions")
    }

    func test_sharedPiAndOMPDirectoryRegistersNeutralReader() {
        let readers = LocalUsageReaderRegistry.readers(
            home: URL(fileURLWithPath: "/tmp/toki-home"),
            environment: ["PI_CODING_AGENT_DIR": "/tmp/shared-agent"])
        let familyNames = readers.map(\.name).filter {
            [
                PiReader.sourceName,
                OMPReader.sourceName,
                SharedPiOMPReader.sourceName,
                KimchiReader.sourceName,
            ].contains($0)
        }

        XCTAssertEqual(familyNames, [SharedPiOMPReader.sourceName, KimchiReader.sourceName])
    }

    func test_ompAutoDetectionRequiresSessionsAndExplicitConfigWins() throws {
        let root = temporaryRoot("toki-omp-paths")
        defer { try? FileManager.default.removeItem(at: root) }
        let home = root.appendingPathComponent("home")
        let xdgData = root.appendingPathComponent("data")
        try FileManager.default.createDirectory(
            at: xdgData.appendingPathComponent("omp"),
            withIntermediateDirectories: true)

        let legacy = LocalUsageReaderPaths(
            homeDirectory: home,
            environment: ["XDG_DATA_HOME": xdgData.path])
        XCTAssertEqual(legacy.ompSessions.path, home.appendingPathComponent(".omp/agent/sessions").path)

        let xdgSessions = xdgData.appendingPathComponent("omp/sessions")
        try FileManager.default.createDirectory(at: xdgSessions, withIntermediateDirectories: true)
        let xdg = LocalUsageReaderPaths(
            homeDirectory: home,
            environment: ["XDG_DATA_HOME": xdgData.path])
        XCTAssertEqual(xdg.ompSessions.path, xdgSessions.path)

        let configured = LocalUsageReaderPaths(
            homeDirectory: home,
            environment: [
                "XDG_DATA_HOME": xdgData.path,
                "PI_CONFIG_DIR": ".custom-omp",
            ])
        XCTAssertEqual(
            configured.ompSessions.path,
            home.appendingPathComponent(".custom-omp/agent/sessions").path)
    }

    func test_ompNamedProfileRequiresSessionsAndExplicitConfigWins() throws {
        let root = temporaryRoot("toki-omp-profile-paths")
        defer { try? FileManager.default.removeItem(at: root) }
        let home = root.appendingPathComponent("home")
        let xdgData = root.appendingPathComponent("data")
        let xdgProfile = xdgData.appendingPathComponent("omp/profiles/work")
        try FileManager.default.createDirectory(at: xdgProfile, withIntermediateDirectories: true)

        let legacy = LocalUsageReaderPaths(
            homeDirectory: home,
            environment: [
                "XDG_DATA_HOME": xdgData.path,
                "OMP_PROFILE": "work",
            ])
        XCTAssertEqual(
            legacy.ompSessions.path,
            home.appendingPathComponent(".omp/profiles/work/agent/sessions").path)

        let xdgSessions = xdgProfile.appendingPathComponent("sessions")
        try FileManager.default.createDirectory(at: xdgSessions, withIntermediateDirectories: true)
        let configured = LocalUsageReaderPaths(
            homeDirectory: home,
            environment: [
                "XDG_DATA_HOME": xdgData.path,
                "OMP_PROFILE": "work",
                "PI_CONFIG_DIR": ".custom-omp",
            ])
        XCTAssertEqual(
            configured.ompSessions.path,
            home.appendingPathComponent(".custom-omp/profiles/work/agent/sessions").path)
    }

    func test_symlinkedPiAndOMPDirectoriesRegisterOneNeutralReader() throws {
        let home = temporaryRoot("toki-pi-omp-alias")
        defer { try? FileManager.default.removeItem(at: home) }
        let shared = home.appendingPathComponent("shared-sessions")
        let piSessions = home.appendingPathComponent(".pi/agent/sessions")
        let ompSessions = home.appendingPathComponent(".omp/agent/sessions")
        try FileManager.default.createDirectory(at: shared, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: piSessions.deletingLastPathComponent(),
            withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: ompSessions.deletingLastPathComponent(),
            withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: piSessions, withDestinationURL: shared)
        try FileManager.default.createSymbolicLink(at: ompSessions, withDestinationURL: shared)

        let names = LocalUsageReaderRegistry.readers(home: home, environment: [:]).map(\.name)

        XCTAssertTrue(names.contains(SharedPiOMPReader.sourceName))
        XCTAssertFalse(names.contains(PiReader.sourceName))
        XCTAssertFalse(names.contains(OMPReader.sourceName))
    }

    func test_recordedZeroAndInvalidNegativeCostRemainDistinct() {
        let zero = KimchiReader.usage(
            fromJSONLLines: [
                #"{"type":"session","id":"kimchi-zero"}"#,
                costMessage(id: "zero", total: "0"),
            ],
            streamID: "kimchi-zero",
            from: date("2026-08-20T00:00:00Z"),
            to: date("2026-08-21T00:00:00Z"))
        let negative = KimchiReader.usage(
            fromJSONLLines: [
                #"{"type":"session","id":"kimchi-negative"}"#,
                costMessage(id: "negative", total: "-0.01"),
            ],
            streamID: "kimchi-negative",
            from: date("2026-08-20T00:00:00Z"),
            to: date("2026-08-21T00:00:00Z"))

        XCTAssertEqual(zero.tokenEvents.first?.cost, 0)
        XCTAssertEqual(zero.tokenEvents.first?.costIsKnown, true)
        XCTAssertEqual(negative.tokenEvents.first?.cost, 0)
        XCTAssertEqual(negative.tokenEvents.first?.costIsKnown, false)
    }

    func test_revisionMergePreservesFallbackProviderAndKnownCostInBothOrders() {
        let larger = usageRecord(
            inputTokens: 100,
            provider: nil,
            cost: 0,
            costIsKnown: false)
        let enriched = usageRecord(
            inputTokens: 90,
            provider: "openai",
            cost: 0.25,
            costIsKnown: true)

        for merged in [larger.merged(with: enriched), enriched.merged(with: larger)] {
            XCTAssertEqual(merged.inputTokens, 100)
            XCTAssertEqual(merged.provider, "openai")
            XCTAssertEqual(merged.cost, 0.25, accuracy: 0.000001)
            XCTAssertTrue(merged.costIsKnown)
        }
    }
}

extension PiFamilyFollowUpTests {
    func test_revisionMergeIsDeterministicAcrossAllOrders() {
        let records = [
            usageRecord(
                inputTokens: 100,
                provider: nil,
                cost: 0,
                costIsKnown: false,
                timestamp: date("2026-08-20T12:00:00Z")),
            usageRecord(
                inputTokens: 90,
                provider: "openai",
                cost: 0.25,
                costIsKnown: true,
                timestamp: date("2026-08-20T12:01:00Z")),
            usageRecord(
                inputTokens: 80,
                provider: "azure",
                cost: 0.30,
                costIsKnown: true,
                timestamp: date("2026-08-20T12:02:00Z")),
        ]
        let orders = [
            [0, 1, 2], [0, 2, 1], [1, 0, 2],
            [1, 2, 0], [2, 0, 1], [2, 1, 0],
        ]

        for order in orders {
            let merged = order.dropFirst().reduce(records[order[0]]) {
                $0.merged(with: records[$1])
            }
            XCTAssertEqual(merged.inputTokens, 100)
            XCTAssertEqual(merged.provider, "azure")
            XCTAssertEqual(merged.cost, 0.30, accuracy: 0.000001)
            XCTAssertTrue(merged.costIsKnown)
        }
    }

    func test_idlessRevisionMetadataEnrichmentMergesOneResponse() {
        let usage = PiReader.usage(
            fromJSONLLines: [
                #"{"type":"session","id":"revision-session"}"#,
                """
                {"type":"message","timestamp":"2026-08-20T12:00:00Z","message":\
                {"role":"assistant","responseId":"revision-response","model":"gpt-5",\
                "usage":{"input":7,"output":3}}}
                """,
                """
                {"type":"message","timestamp":"2026-08-20T12:00:01Z","message":\
                {"role":"assistant","responseId":"revision-response","model":"gpt-5",\
                "provider":"azure","usage":{"input":7,"output":3,"cost":{"total":0.25}}}}
                """,
            ],
            streamID: "/tmp/revision.jsonl",
            from: date("2026-08-20T00:00:00Z"),
            to: date("2026-08-21T00:00:00Z"))

        XCTAssertEqual(usage.totalTokens, 10)
        XCTAssertEqual(usage.cost, 0.25, accuracy: 0.000001)
        XCTAssertEqual(usage.tokenEvents.count, 1)
        XCTAssertEqual(usage.tokenEvents.first?.provider, "azure")
    }

    func test_idlessRowsAtSameTimestampRemainDistinct() {
        let usage = PiReader.usage(
            fromJSONLLines: [
                #"{"type":"session","id":"same-time"}"#,
                idlessPayload(timestamp: "2026-08-20T12:00:00Z", input: 3, output: 2),
                idlessPayload(timestamp: "2026-08-20T12:00:00Z", input: 7, output: 4),
            ],
            streamID: "/tmp/same-time.jsonl",
            from: date("2026-08-20T00:00:00Z"),
            to: date("2026-08-21T00:00:00Z"))

        XCTAssertEqual(usage.totalTokens, 16)
        XCTAssertEqual(usage.tokenEvents.count, 2)
    }
}

final class PiFamilyReaderLimitTests: XCTestCase {
    func test_sharedPiAndOMPReaderPreservesSessionLocalMessageIDs() async throws {
        let root = temporaryRoot("toki-pi-omp-shared")
        defer { try? FileManager.default.removeItem(at: root) }
        let agentRoot = root.appendingPathComponent("shared-agent")
        let sessions = agentRoot.appendingPathComponent("sessions")
        try writeSession(
            to: sessions.appendingPathComponent("a.jsonl"),
            sessionID: "session-a",
            messageID: "message-0001",
            input: 1,
            output: 1)
        try writeSession(
            to: sessions.appendingPathComponent("b.jsonl"),
            sessionID: "session-b",
            messageID: "message-0001",
            input: 9,
            output: 9)
        let reader = try XCTUnwrap(LocalUsageReaderRegistry.readers(
            home: root,
            environment: ["PI_CODING_AGENT_DIR": agentRoot.path])
            .first { $0.name == SharedPiOMPReader.sourceName })

        let usage = try await reader.readUsage(
            from: date("2026-08-20T00:00:00Z"),
            to: date("2026-08-21T00:00:00Z"))

        XCTAssertEqual(usage.totalTokens, 20)
        XCTAssertEqual(usage.tokenEvents.count, 2)
        XCTAssertEqual(Set(usage.tokenEvents.map(\.source)), [SharedPiOMPReader.sourceName])
    }

    func test_nonUUIDMessageIDsRemainSessionLocal() async throws {
        let root = temporaryRoot("toki-pi-local-id")
        defer { try? FileManager.default.removeItem(at: root) }
        try writeSession(
            to: root.appendingPathComponent("a.jsonl"),
            sessionID: "session-a",
            messageID: "message-0001",
            input: 1,
            output: 1)
        try writeSession(
            to: root.appendingPathComponent("b.jsonl"),
            sessionID: "session-b",
            messageID: "message-0001",
            input: 9,
            output: 9)

        let usage = try await PiReader(sessionsURLOverride: root).readUsage(
            from: date("2026-08-20T00:00:00Z"),
            to: date("2026-08-21T00:00:00Z"))

        XCTAssertEqual(usage.totalTokens, 20)
        XCTAssertEqual(usage.tokenEvents.count, 2)
    }

    func test_piEventLimitCountsAcceptedRecordsBeforeDeduplication() async throws {
        let root = temporaryRoot("toki-pi-event-limit")
        defer { try? FileManager.default.removeItem(at: root) }
        let repeated = message(
            id: "550e8400-e29b-41d4-a716-446655440000",
            input: 1,
            output: 1)
        try writeLines(
            [#"{"type":"session","id":"limited-session"}"#, repeated, repeated],
            to: root.appendingPathComponent("limited.jsonl"))
        let reader = PiReader(
            sessionsURLOverride: root,
            readLimits: PiCompatibleReadLimits(
                maximumFileCount: 1,
                maximumFileBytes: 10000,
                maximumLineBytes: 1000,
                maximumEventCount: 1))

        do {
            _ = try await reader.readUsage(
                from: date("2026-08-20T00:00:00Z"),
                to: date("2026-08-21T00:00:00Z"))
            XCTFail("Expected the second accepted record to exceed the limit")
        } catch {
            XCTAssertEqual(error as? PiCompatibleReaderError, .tooManyEvents(2))
        }
    }

    func test_piFileLimitStopsAtFirstExcessFile() async throws {
        let root = temporaryRoot("toki-pi-file-limit")
        defer { try? FileManager.default.removeItem(at: root) }
        for index in 1...3 {
            try writeSession(
                to: root.appendingPathComponent("\(index).jsonl"),
                sessionID: "session-\(index)",
                messageID: "message-\(index)",
                input: 1,
                output: 1)
        }
        let reader = PiReader(
            sessionsURLOverride: root,
            readLimits: PiCompatibleReadLimits(
                maximumFileCount: 1,
                maximumFileBytes: 10000,
                maximumLineBytes: 1000,
                maximumEventCount: 10))

        do {
            _ = try await reader.readUsage(
                from: date("2026-08-20T00:00:00Z"),
                to: date("2026-08-21T00:00:00Z"))
            XCTFail("Expected bounded discovery to reject the second file")
        } catch {
            XCTAssertEqual(error as? PiCompatibleReaderError, .tooManyFiles(2))
        }
    }

    func test_piEntryLimitCountsNonUsageFiles() async throws {
        let root = temporaryRoot("toki-pi-entry-limit")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data().write(to: root.appendingPathComponent("first.txt"))
        try Data().write(to: root.appendingPathComponent("second.txt"))
        let reader = PiReader(
            sessionsURLOverride: root,
            readLimits: PiCompatibleReadLimits(
                maximumFileCount: 10,
                maximumFileBytes: 10000,
                maximumLineBytes: 1000,
                maximumEventCount: 10,
                maximumEntryCount: 1))

        do {
            _ = try await reader.readUsage(
                from: date("2026-08-20T00:00:00Z"),
                to: date("2026-08-21T00:00:00Z"))
            XCTFail("Expected the second filesystem entry to exceed the limit")
        } catch {
            XCTAssertEqual(error as? PiCompatibleReaderError, .tooManyEntries(2))
        }
    }
}

extension PiFamilyReaderLimitTests {
    func test_idlessExactCopiesDeduplicateButReusedResponsesRemainDistinct() async throws {
        let root = temporaryRoot("toki-pi-idless")
        defer { try? FileManager.default.removeItem(at: root) }
        let copied = idlessMessage(
            responseID: "response-copy",
            timestamp: "2026-08-20T12:00:00Z",
            input: 3,
            output: 2)
        try writeLines(
            [#"{"type":"session","id":"session-a"}"#, copied],
            to: root.appendingPathComponent("a.jsonl"))
        try writeLines(
            [#"{"type":"session","id":"session-b"}"#, copied],
            to: root.appendingPathComponent("b.jsonl"))
        try writeLines(
            [
                #"{"type":"session","id":"session-c"}"#,
                idlessMessage(
                    responseID: "response-copy",
                    timestamp: "2026-08-20T13:00:00Z",
                    input: 7,
                    output: 4),
            ],
            to: root.appendingPathComponent("c.jsonl"))

        let usage = try await PiReader(sessionsURLOverride: root).readUsage(
            from: date("2026-08-20T00:00:00Z"),
            to: date("2026-08-21T00:00:00Z"))

        XCTAssertEqual(usage.totalTokens, 16)
        XCTAssertEqual(usage.tokenEvents.count, 2)
    }

    func test_copiedResponseKeepsOriginalIdentityAfterEnrichment() async throws {
        let root = temporaryRoot("toki-pi-copy-enrichment")
        defer { try? FileManager.default.removeItem(at: root) }
        let original = idlessMessage(
            responseID: "response-copy",
            timestamp: "2026-08-20T12:00:00Z",
            input: 3,
            output: 2)
        let enriched = """
        {"type":"message","timestamp":"2026-08-20T12:00:01Z","message":\
        {"role":"assistant","responseId":"response-copy","model":"gpt-5",\
        "provider":"azure","usage":{"input":3,"output":2,"cost":{"total":0.25}}}}
        """
        try writeLines(
            [#"{"type":"session","id":"session-a"}"#, original],
            to: root.appendingPathComponent("a.jsonl"))
        try writeLines(
            [#"{"type":"session","id":"session-b"}"#, original, enriched],
            to: root.appendingPathComponent("b.jsonl"))

        let usage = try await PiReader(sessionsURLOverride: root).readUsage(
            from: date("2026-08-20T00:00:00Z"),
            to: date("2026-08-21T00:00:00Z"))

        XCTAssertEqual(usage.totalTokens, 5)
        XCTAssertEqual(usage.tokenEvents.count, 1)
        XCTAssertEqual(usage.cost, 0.25, accuracy: 0.000001)
        XCTAssertEqual(usage.tokenEvents.first?.provider, "azure")
    }

    func test_sameResponseIdentityWithDifferentPayloadsRemainsDistinct() async throws {
        let root = temporaryRoot("toki-pi-copy-payload")
        defer { try? FileManager.default.removeItem(at: root) }
        try writeLines(
            [
                #"{"type":"session","id":"session-a"}"#,
                idlessMessage(
                    responseID: "response-reused",
                    timestamp: "2026-08-20T12:00:00Z",
                    input: 3,
                    output: 2),
            ],
            to: root.appendingPathComponent("a.jsonl"))
        try writeLines(
            [
                #"{"type":"session","id":"session-b"}"#,
                idlessMessage(
                    responseID: "response-reused",
                    timestamp: "2026-08-20T12:00:00Z",
                    input: 7,
                    output: 4),
            ],
            to: root.appendingPathComponent("b.jsonl"))

        let usage = try await PiReader(sessionsURLOverride: root).readUsage(
            from: date("2026-08-20T00:00:00Z"),
            to: date("2026-08-21T00:00:00Z"))

        XCTAssertEqual(usage.totalTokens, 16)
        XCTAssertEqual(usage.tokenEvents.count, 2)
    }
}

private func date(_ value: String) -> Date {
    ISO8601DateFormatter().date(from: value) ?? .distantPast
}

private func temporaryRoot(_ prefix: String) -> URL {
    FileManager.default.temporaryDirectory
        .appendingPathComponent("\(prefix)-\(UUID().uuidString)", isDirectory: true)
}

private func costMessage(id: String, total: String) -> String {
    """
    {"type":"message","id":"\(id)","timestamp":"2026-08-20T12:00:00Z","message":\
    {"role":"assistant","model":"kimi-k2.6","provider":"kimchi-dev",\
    "usage":{"input":9,"output":6,"cost":{"total":\(total)}}}}
    """
}

private func message(id: String, input: Int, output: Int) -> String {
    """
    {"type":"message","id":"\(id)","timestamp":"2026-08-20T12:00:00Z","message":\
    {"role":"assistant","model":"gpt-5","provider":"openai",\
    "usage":{"input":\(input),"output":\(output)}}}
    """
}

private func idlessMessage(
    responseID: String,
    timestamp: String,
    input: Int,
    output: Int) -> String {
    """
    {"type":"message","timestamp":"\(timestamp)","message":\
    {"role":"assistant","responseId":"\(responseID)","model":"gpt-5",\
    "provider":"openai","usage":{"input":\(input),"output":\(output)}}}
    """
}

private func idlessPayload(timestamp: String, input: Int, output: Int) -> String {
    """
    {"type":"message","timestamp":"\(timestamp)","message":\
    {"role":"assistant","model":"gpt-5","provider":"openai",\
    "usage":{"input":\(input),"output":\(output)}}}
    """
}

private func usageRecord(
    inputTokens: Int,
    provider: String?,
    cost: Double,
    costIsKnown: Bool,
    timestamp: Date = date("2026-08-20T12:00:00Z")) -> PiCompatibleUsageRecord {
    PiCompatibleUsageRecord(
        deduplicationKey: .message("shared-revision"),
        timestamp: timestamp,
        model: "gpt-5",
        provider: provider,
        inputTokens: inputTokens,
        outputTokens: 0,
        cacheReadTokens: 0,
        cacheWriteTokens: 0,
        reasoningTokens: 0,
        cost: cost,
        costIsKnown: costIsKnown,
        attribution: UsageAttribution(sessionID: "shared-session", quality: .exact),
        agentKind: .main)
}

private func writeSession(
    to url: URL,
    sessionID: String,
    messageID: String,
    input: Int,
    output: Int) throws {
    try writeLines(
        [
            #"{"type":"session","id":"\#(sessionID)","cwd":"/tmp/project"}"#,
            message(id: messageID, input: input, output: output),
        ],
        to: url)
}

private func writeLines(_ lines: [String], to url: URL) throws {
    try FileManager.default.createDirectory(
        at: url.deletingLastPathComponent(),
        withIntermediateDirectories: true)
    try Data(lines.joined(separator: "\n").utf8).write(to: url)
}
