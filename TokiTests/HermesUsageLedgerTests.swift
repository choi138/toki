// swiftlint:disable file_length
import TokiSyncProtocol
import TokiUsageCore
import XCTest
@testable import Toki
@testable import TokiUsageReaders

// swiftlint:disable:next type_body_length
final class HermesUsageLedgerTests: XCTestCase {
    func test_hermesReader_recordsOnlyLongRunningSessionIncrementOnCurrentActivityDay() async throws {
        let fixture = try makeLongRunningHermesFixture()
        defer { try? FileManager.default.removeItem(at: fixture.tempDirectory) }
        let initialReader = HermesReader(
            dbPathOverride: fixture.databaseURL.path,
            usageLedger: fixture.ledger,
            now: { tokiTestISODate("2026-04-09T10:00:00Z") })

        let initial = try await initialReader.readUsage(
            from: tokiTestISODate("2026-04-09T00:00:00Z"),
            to: tokiTestISODate("2026-04-10T00:00:00Z"))
        XCTAssertEqual(initial.totalTokens, 0)
        let initialStatus = try await fixture.ledger.status()
        XCTAssertEqual(initialStatus.accurateSince, tokiTestISODate("2026-04-09T10:00:00Z"))
        XCTAssertEqual(initialStatus.unattributedSessionCount, 1)
        XCTAssertEqual(initialStatus.unattributedTokens, 160)

        let latestActivity = try recordLongRunningHermesIncrement(in: fixture)
        let currentReader = HermesReader(
            dbPathOverride: fixture.databaseURL.path,
            usageLedger: fixture.ledger,
            now: { tokiTestISODate("2026-04-10T10:00:00Z") })
        let current = try await currentReader.readUsage(
            from: tokiTestISODate("2026-04-10T00:00:00Z"),
            to: tokiTestISODate("2026-04-11T00:00:00Z"))

        XCTAssertEqual(current.inputTokens, 60)
        XCTAssertEqual(current.outputTokens, 10)
        XCTAssertEqual(current.cacheReadTokens, 20)
        XCTAssertEqual(current.cacheWriteTokens, 1)
        XCTAssertEqual(current.reasoningTokens, 4)
        XCTAssertEqual(current.totalTokens, 95)
        XCTAssertEqual(current.tokenEvents.map(\.timestamp), [latestActivity])

        let attributesBeforeNoOp = try FileManager.default.attributesOfItem(atPath: fixture.ledgerURL.path)
        let noOp = try await currentReader.readUsage(
            from: tokiTestISODate("2026-04-10T00:00:00Z"),
            to: tokiTestISODate("2026-04-11T00:00:00Z"))
        let attributesAfterNoOp = try FileManager.default.attributesOfItem(atPath: fixture.ledgerURL.path)
        XCTAssertEqual(noOp.totalTokens, 95)
        XCTAssertEqual(
            attributesBeforeNoOp[.systemFileNumber] as? NSNumber,
            attributesAfterNoOp[.systemFileNumber] as? NSNumber)

        let restartedReader = HermesReader(
            dbPathOverride: fixture.databaseURL.path,
            usageLedger: HermesUsageLedger(fileURL: fixture.ledgerURL),
            now: { tokiTestISODate("2026-04-10T10:05:00Z") })
        let afterRestart = try await restartedReader.readUsage(
            from: tokiTestISODate("2026-04-10T00:00:00Z"),
            to: tokiTestISODate("2026-04-11T00:00:00Z"))
        XCTAssertEqual(afterRestart.totalTokens, 95)
        try assertHermesLedgerPrivacy(at: fixture.ledgerURL)
    }

    func test_hermesUsageLedger_splitsMixedModelUsageAndKeepsOnlyResidualUnattributed() async throws {
        let tempDir = try makeHermesTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let ledger = HermesUsageLedger(fileURL: tempDir.appendingPathComponent("hermes-usage-ledger.json"))
        let baselineAt = tokiTestISODate("2026-04-10T08:00:00Z")
        let startedAt = tokiTestISODate("2026-04-10T09:00:00Z")
        let observedAt = tokiTestISODate("2026-04-10T10:00:00Z")
        try await ledger.refresh(observations: [], observedAt: baselineAt)

        try await ledger.refresh(
            observations: [HermesSessionObservation(
                sessionID: "mixed-model-session",
                startedAt: startedAt,
                earliestActivityAt: startedAt,
                latestActivityAt: observedAt,
                model: nil,
                counters: HermesTokenCounters(
                    inputTokens: 150,
                    outputTokens: 0,
                    cacheReadTokens: 0,
                    cacheWriteTokens: 0,
                    reasoningTokens: 0),
                modelCounters: [
                    "gpt-5.6-sol": HermesTokenCounters(
                        inputTokens: 100,
                        outputTokens: 0,
                        cacheReadTokens: 0,
                        cacheWriteTokens: 0,
                        reasoningTokens: 0),
                    "kr/claude-opus-5": HermesTokenCounters(
                        inputTokens: 30,
                        outputTokens: 0,
                        cacheReadTokens: 0,
                        cacheWriteTokens: 0,
                        reasoningTokens: 0),
                ],
                cost: 0,
                projectName: nil,
                attributionQuality: .unknown)],
            observedAt: observedAt)

        let events = try await ledger.events(
            from: baselineAt,
            to: observedAt.addingTimeInterval(1))
        let tokensByModel = events.reduce(into: [String: Int]()) { result, event in
            result[event.model ?? "Mixed / Unattributed", default: 0] += event.counters.totalTokens
        }

        XCTAssertEqual(tokensByModel, [
            "gpt-5.6-sol": 100,
            "kr/claude-opus-5": 30,
            "Mixed / Unattributed": 20,
        ])
        XCTAssertEqual(events.reduce(0) { $0 + $1.counters.totalTokens }, 150)
    }

    func test_hermesUsageLedger_attributesPartialDetailResidualToResolvedModel() async throws {
        let tempDir = try makeHermesTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let ledger = HermesUsageLedger(fileURL: tempDir.appendingPathComponent("hermes-usage-ledger.json"))
        let baselineAt = tokiTestISODate("2026-04-10T08:00:00Z")
        let startedAt = tokiTestISODate("2026-04-10T09:00:00Z")
        let observedAt = tokiTestISODate("2026-04-10T10:00:00Z")
        try await ledger.refresh(observations: [], observedAt: baselineAt)

        // The session counters exceed the partial session_model_usage breakdown, but
        // the session and the detail row agree on one model, so the resolver keeps
        // that model on the observation. The 50-token residual and its share of the
        // cost belong to that model rather than to Mixed / Unattributed.
        try await ledger.refresh(
            observations: [HermesSessionObservation(
                sessionID: "single-model-session",
                startedAt: startedAt,
                earliestActivityAt: startedAt,
                latestActivityAt: observedAt,
                model: "kr/claude-opus-5",
                counters: HermesTokenCounters(
                    inputTokens: 150,
                    outputTokens: 0,
                    cacheReadTokens: 0,
                    cacheWriteTokens: 0,
                    reasoningTokens: 0),
                modelCounters: [
                    "kr/claude-opus-5": HermesTokenCounters(
                        inputTokens: 100,
                        outputTokens: 0,
                        cacheReadTokens: 0,
                        cacheWriteTokens: 0,
                        reasoningTokens: 0),
                ],
                cost: 3,
                projectName: nil,
                attributionQuality: .unknown)],
            observedAt: observedAt)

        let events = try await ledger.events(
            from: baselineAt,
            to: observedAt.addingTimeInterval(1))
        let tokensByModel = events.reduce(into: [String: Int]()) { result, event in
            result[event.model ?? "Mixed / Unattributed", default: 0] += event.counters.totalTokens
        }

        XCTAssertEqual(tokensByModel, ["kr/claude-opus-5": 150])
        XCTAssertFalse(events.contains { $0.model == nil })
        XCTAssertEqual(events.reduce(0) { $0 + $1.counters.totalTokens }, 150)
        XCTAssertEqual(events.reduce(0) { $0 + $1.cost }, 3, accuracy: 0.0001)
    }

    func test_hermesUsageLedger_establishesModelBaselineBeforeSplittingLegacySessionDeltas() async throws {
        let tempDir = try makeHermesTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let ledger = HermesUsageLedger(fileURL: tempDir.appendingPathComponent("hermes-usage-ledger.json"))
        let baselineAt = tokiTestISODate("2026-04-10T08:00:00Z")
        let startedAt = tokiTestISODate("2026-04-09T08:00:00Z")
        try await ledger.refresh(observations: [], observedAt: baselineAt)

        func observation(
            inputTokens: Int,
            modelCounters: [String: HermesTokenCounters]?) -> HermesSessionObservation {
            HermesSessionObservation(
                sessionID: "legacy-mixed-session",
                startedAt: startedAt,
                earliestActivityAt: nil,
                latestActivityAt: nil,
                model: nil,
                counters: HermesTokenCounters(
                    inputTokens: inputTokens,
                    outputTokens: 0,
                    cacheReadTokens: 0,
                    cacheWriteTokens: 0,
                    reasoningTokens: 0),
                modelCounters: modelCounters,
                cost: 0,
                projectName: nil,
                attributionQuality: .unknown)
        }

        try await ledger.refresh(
            observations: [observation(inputTokens: 100, modelCounters: nil)],
            observedAt: tokiTestISODate("2026-04-10T09:00:00Z"))
        try await ledger.refresh(
            observations: [observation(inputTokens: 130, modelCounters: [
                "gpt-5.6-sol": HermesTokenCounters(
                    inputTokens: 80,
                    outputTokens: 0,
                    cacheReadTokens: 0,
                    cacheWriteTokens: 0,
                    reasoningTokens: 0),
                "kr/claude-opus-5": HermesTokenCounters(
                    inputTokens: 50,
                    outputTokens: 0,
                    cacheReadTokens: 0,
                    cacheWriteTokens: 0,
                    reasoningTokens: 0),
            ])],
            observedAt: tokiTestISODate("2026-04-10T10:00:00Z"))
        try await ledger.refresh(
            observations: [observation(inputTokens: 160, modelCounters: [
                "gpt-5.6-sol": HermesTokenCounters(
                    inputTokens: 90,
                    outputTokens: 0,
                    cacheReadTokens: 0,
                    cacheWriteTokens: 0,
                    reasoningTokens: 0),
                "kr/claude-opus-5": HermesTokenCounters(
                    inputTokens: 70,
                    outputTokens: 0,
                    cacheReadTokens: 0,
                    cacheWriteTokens: 0,
                    reasoningTokens: 0),
            ])],
            observedAt: tokiTestISODate("2026-04-10T11:00:00Z"))

        let events = try await ledger.events(
            from: baselineAt,
            to: tokiTestISODate("2026-04-10T12:00:00Z"))
        let tokensByModel = events.reduce(into: [String: Int]()) { result, event in
            result[event.model ?? "Mixed / Unattributed", default: 0] += event.counters.totalTokens
        }

        XCTAssertEqual(tokensByModel, [
            "Mixed / Unattributed": 30,
            "gpt-5.6-sol": 10,
            "kr/claude-opus-5": 20,
        ])
        XCTAssertEqual(events.reduce(0) { $0 + $1.counters.totalTokens }, 60)
    }

    func test_hermesReader_rebaselinesCounterDecreaseWithoutNegativeOrDuplicateUsage() async throws {
        let tempDir = try makeHermesTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let dbURL = tempDir.appendingPathComponent("state.db")
        let ledger = HermesUsageLedger(fileURL: tempDir.appendingPathComponent("hermes-usage-ledger.json"))
        try createHermesStateDB(
            at: dbURL,
            rows: [hermesSingleCounterFixture(id: "reset-session", inputTokens: 100)])
        let firstReader = HermesReader(
            dbPathOverride: dbURL.path,
            usageLedger: ledger,
            now: { tokiTestISODate("2026-04-09T12:00:00Z") })
        _ = try await firstReader.readUsage(
            from: tokiTestISODate("2026-04-09T00:00:00Z"),
            to: tokiTestISODate("2026-04-10T00:00:00Z"))

        try updateHermesSession(
            databaseURL: dbURL,
            id: "reset-session",
            model: "gpt-5.5",
            inputTokens: 0)
        let resetReader = HermesReader(
            dbPathOverride: dbURL.path,
            usageLedger: ledger,
            now: { tokiTestISODate("2026-04-10T09:00:00Z") })
        let resetUsage = try await resetReader.readUsage(
            from: tokiTestISODate("2026-04-10T00:00:00Z"),
            to: tokiTestISODate("2026-04-11T00:00:00Z"))
        XCTAssertEqual(resetUsage.totalTokens, 0)

        try updateHermesSession(
            databaseURL: dbURL,
            id: "reset-session",
            model: "gpt-5.5",
            inputTokens: 25)
        let resumedReader = HermesReader(
            dbPathOverride: dbURL.path,
            usageLedger: ledger,
            now: { tokiTestISODate("2026-04-10T10:00:00Z") })
        let resumedUsage = try await resumedReader.readUsage(
            from: tokiTestISODate("2026-04-10T00:00:00Z"),
            to: tokiTestISODate("2026-04-11T00:00:00Z"))
        XCTAssertEqual(resumedUsage.inputTokens, 25)
        XCTAssertEqual(resumedUsage.totalTokens, 25)
    }

    func test_hermesReader_recordsOnlyModelUsageIncrementAfterRestart() async throws {
        let tempDir = try makeHermesTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let dbURL = tempDir.appendingPathComponent("state.db")
        let ledgerURL = tempDir.appendingPathComponent("hermes-usage-ledger.json")
        try createHermesStateDB(
            at: dbURL,
            rows: [
                HermesSessionFixture(
                    id: "discord-session",
                    startedAt: "2026-04-09T08:00:00Z",
                    model: "gpt-5.5",
                    inputTokens: 0,
                    outputTokens: 0,
                    cacheReadTokens: 0,
                    cacheWriteTokens: 0,
                    reasoningTokens: 0,
                    cwd: nil,
                    gitRepoRoot: nil,
                    estimatedCost: 0,
                    actualCost: nil),
            ])
        try insertHermesModelUsage(
            databaseURL: dbURL,
            rows: [
                HermesModelUsageFixture(
                    sessionID: "discord-session",
                    model: "gpt-5.5",
                    task: "approval",
                    apiCallCount: 1,
                    inputTokens: 100,
                    outputTokens: 0,
                    cacheReadTokens: 0,
                    cacheWriteTokens: 0,
                    reasoningTokens: 0,
                    estimatedCost: 0,
                    actualCost: 0),
            ])
        let initialLedger = HermesUsageLedger(fileURL: ledgerURL)
        let initialReader = HermesReader(
            dbPathOverride: dbURL.path,
            usageLedger: initialLedger,
            now: { tokiTestISODate("2026-04-09T10:00:00Z") })

        let initialUsage = try await initialReader.readUsage(
            from: tokiTestISODate("2026-04-09T00:00:00Z"),
            to: tokiTestISODate("2026-04-10T00:00:00Z"))
        XCTAssertEqual(initialUsage.totalTokens, 0)

        try updateHermesModelUsage(
            databaseURL: dbURL,
            sessionID: "discord-session",
            task: "approval",
            inputTokens: 160)
        let restartedReader = HermesReader(
            dbPathOverride: dbURL.path,
            usageLedger: HermesUsageLedger(fileURL: ledgerURL),
            now: { tokiTestISODate("2026-04-10T10:00:00Z") })

        let increment = try await restartedReader.readUsage(
            from: tokiTestISODate("2026-04-10T00:00:00Z"),
            to: tokiTestISODate("2026-04-11T00:00:00Z"))
        XCTAssertEqual(increment.inputTokens, 60)
        XCTAssertEqual(increment.totalTokens, 60)

        let noOpAfterRestart = try await HermesReader(
            dbPathOverride: dbURL.path,
            usageLedger: HermesUsageLedger(fileURL: ledgerURL),
            now: { tokiTestISODate("2026-04-10T10:05:00Z") })
            .readUsage(
                from: tokiTestISODate("2026-04-10T00:00:00Z"),
                to: tokiTestISODate("2026-04-11T00:00:00Z"))
        XCTAssertEqual(noOpAfterRestart.inputTokens, 60)
        XCTAssertEqual(noOpAfterRestart.totalTokens, 60)
    }

    func test_hermesReader_attributesIncrementToCurrentModelAfterModelChange() async throws {
        let tempDir = try makeHermesTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let dbURL = tempDir.appendingPathComponent("state.db")
        let ledger = HermesUsageLedger(fileURL: tempDir.appendingPathComponent("hermes-usage-ledger.json"))
        try createHermesStateDB(
            at: dbURL,
            rows: [hermesSingleCounterFixture(id: "model-session", inputTokens: 100)])
        let firstReader = HermesReader(
            dbPathOverride: dbURL.path,
            usageLedger: ledger,
            now: { tokiTestISODate("2026-04-09T12:00:00Z") })
        _ = try await firstReader.readUsage(
            from: tokiTestISODate("2026-04-09T00:00:00Z"),
            to: tokiTestISODate("2026-04-10T00:00:00Z"))

        try updateHermesSession(
            databaseURL: dbURL,
            id: "model-session",
            model: "gpt-5.4-mini",
            inputTokens: 150)
        let currentReader = HermesReader(
            dbPathOverride: dbURL.path,
            usageLedger: ledger,
            now: { tokiTestISODate("2026-04-10T09:00:00Z") })
        let usage = try await currentReader.readUsage(
            from: tokiTestISODate("2026-04-10T00:00:00Z"),
            to: tokiTestISODate("2026-04-11T00:00:00Z"))

        XCTAssertEqual(usage.inputTokens, 50)
        XCTAssertEqual(usage.perModel["gpt-5.4-mini"]?.totalTokens, 50)
        XCTAssertNil(usage.perModel["gpt-5.5"])
    }

    func test_hermesUsageLedger_keepsAbsoluteIncrementsSeparateAcrossMidnight() async throws {
        let tempDir = try makeHermesTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let ledger = HermesUsageLedger(fileURL: tempDir.appendingPathComponent("hermes-usage-ledger.json"))
        let startedAt = tokiTestISODate("2026-04-10T20:00:00Z")

        try await ledger.refresh(
            observations: [hermesObservation(
                sessionID: "midnight-session",
                startedAt: startedAt,
                latestActivityAt: tokiTestISODate("2026-04-10T23:58:00Z"),
                inputTokens: 100)],
            observedAt: tokiTestISODate("2026-04-10T23:58:30Z"))
        try await ledger.refresh(
            observations: [hermesObservation(
                sessionID: "midnight-session",
                startedAt: startedAt,
                latestActivityAt: tokiTestISODate("2026-04-10T23:59:00Z"),
                inputTokens: 110)],
            observedAt: tokiTestISODate("2026-04-10T23:59:30Z"))
        try await ledger.refresh(
            observations: [hermesObservation(
                sessionID: "midnight-session",
                startedAt: startedAt,
                latestActivityAt: tokiTestISODate("2026-04-11T00:01:00Z"),
                inputTokens: 120)],
            observedAt: tokiTestISODate("2026-04-11T00:01:30Z"))

        let previousDay = try await ledger.events(
            from: tokiTestISODate("2026-04-10T00:00:00Z"),
            to: tokiTestISODate("2026-04-11T00:00:00Z"))
        let currentDay = try await ledger.events(
            from: tokiTestISODate("2026-04-11T00:00:00Z"),
            to: tokiTestISODate("2026-04-12T00:00:00Z"))
        XCTAssertEqual(previousDay.map(\.counters.inputTokens), [10])
        XCTAssertEqual(currentDay.map(\.counters.inputTokens), [10])
    }
}

extension HermesUsageLedgerTests {
    func test_hermesUsageLedger_recordsSessionCreatedAfterStableObservation() async throws {
        let tempDir = try makeHermesTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let ledger = HermesUsageLedger(fileURL: tempDir.appendingPathComponent("hermes-usage-ledger.json"))
        let firstObservation = tokiTestISODate("2026-04-10T08:00:00Z")
        let startedAt = tokiTestISODate("2026-04-10T08:05:00Z")
        let latestActivityAt = tokiTestISODate("2026-04-10T08:09:00Z")

        try await ledger.refresh(observations: [], observedAt: firstObservation)
        try await ledger.refresh(
            observations: [hermesObservation(
                sessionID: "new-session",
                startedAt: startedAt,
                latestActivityAt: latestActivityAt,
                inputTokens: 75)],
            observedAt: tokiTestISODate("2026-04-10T08:10:00Z"))

        let events = try await ledger.events(
            from: tokiTestISODate("2026-04-10T00:00:00Z"),
            to: tokiTestISODate("2026-04-11T00:00:00Z"))
        let status = try await ledger.status()
        XCTAssertEqual(events.map(\.timestamp), [latestActivityAt])
        XCTAssertEqual(events.map(\.counters.inputTokens), [75])
        XCTAssertEqual(status.unattributedTokens, 0)
    }

    func test_hermesUsageLedger_datesNewSessionAtStartWhenMessageActivityIsUnavailable() async throws {
        let tempDir = try makeHermesTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let ledger = HermesUsageLedger(fileURL: tempDir.appendingPathComponent("hermes-usage-ledger.json"))
        let firstObservation = tokiTestISODate("2026-04-10T08:00:00Z")
        let startedAt = tokiTestISODate("2026-04-10T08:05:00Z")

        try await ledger.refresh(observations: [], observedAt: firstObservation)
        try await ledger.refresh(
            observations: [hermesObservation(
                sessionID: "new-session-without-messages",
                startedAt: startedAt,
                inputTokens: 75)],
            observedAt: tokiTestISODate("2026-04-10T08:10:00Z"))

        let events = try await ledger.events(
            from: tokiTestISODate("2026-04-10T00:00:00Z"),
            to: tokiTestISODate("2026-04-11T00:00:00Z"))
        XCTAssertEqual(events.map(\.timestamp), [startedAt])
        XCTAssertEqual(events.map(\.counters.inputTokens), [75])
    }

    func test_hermesUsageLedger_doesNotMergeAcrossMacDayWhenLinuxUTCDateMatches() async throws {
        let tempDir = try makeHermesTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let ledger = HermesUsageLedger(fileURL: tempDir.appendingPathComponent("hermes-usage-ledger.json"))
        let startedAt = tokiTestISODate("2026-04-10T14:50:00Z")

        try await ledger.refresh(
            observations: [hermesObservation(
                sessionID: "timezone-session",
                startedAt: startedAt,
                latestActivityAt: tokiTestISODate("2026-04-10T14:58:00Z"),
                inputTokens: 100)],
            observedAt: tokiTestISODate("2026-04-10T14:58:30Z"))
        try await ledger.refresh(
            observations: [hermesObservation(
                sessionID: "timezone-session",
                startedAt: startedAt,
                latestActivityAt: tokiTestISODate("2026-04-10T14:59:00Z"),
                inputTokens: 110)],
            observedAt: tokiTestISODate("2026-04-10T14:59:30Z"))
        try await ledger.refresh(
            observations: [hermesObservation(
                sessionID: "timezone-session",
                startedAt: startedAt,
                latestActivityAt: tokiTestISODate("2026-04-10T15:01:00Z"),
                inputTokens: 120)],
            observedAt: tokiTestISODate("2026-04-10T15:01:30Z"))

        let kstApril10 = try await ledger.events(
            from: tokiTestISODate("2026-04-09T15:00:00Z"),
            to: tokiTestISODate("2026-04-10T15:00:00Z"))
        let kstApril11 = try await ledger.events(
            from: tokiTestISODate("2026-04-10T15:00:00Z"),
            to: tokiTestISODate("2026-04-11T15:00:00Z"))
        XCTAssertEqual(kstApril10.map(\.counters.inputTokens), [10])
        XCTAssertEqual(kstApril11.map(\.counters.inputTokens), [10])
    }
}

extension HermesUsageLedgerTests {
    func test_hermesUsageLedger_automaticallyMigratesV1InitialEventToUnattributedBaseline() async throws {
        let tempDir = try makeHermesTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let ledgerURL = tempDir.appendingPathComponent("hermes-usage-ledger.json")
        let key = SnapshotCipher.generateKey()
        let identifier = try SnapshotCipher.opaqueIdentifier(for: "legacy-session", key: key)
        let startedAt = tokiTestISODate("2026-04-09T08:00:00Z")
        let lastObservedAt = tokiTestISODate("2026-04-09T10:00:00Z")
        let counters = HermesTokenCounters(
            inputTokens: 100,
            outputTokens: 0,
            cacheReadTokens: 0,
            cacheWriteTokens: 0,
            reasoningTokens: 0)
        let legacy = HermesUsageLedgerV1Fixture(
            schemaVersion: 1,
            identifierKey: key,
            baselines: [identifier: HermesUsageLedgerV1BaselineFixture(
                startedAt: startedAt,
                lastActivityAt: tokiTestISODate("2026-04-09T09:30:00Z"),
                lastObservedAt: lastObservedAt,
                model: "gpt-5.5",
                counters: counters,
                cost: 0,
                projectName: nil,
                attributionQuality: .unknown)],
            events: [HermesUsageLedgerV1EventFixture(
                sessionIdentifier: identifier,
                timestamp: startedAt,
                model: "gpt-5.5",
                counters: counters,
                cost: 0,
                projectName: nil,
                attributionQuality: .unknown)])
        try writePrivateHermesTestData(JSONEncoder().encode(legacy), to: ledgerURL)
        let ledger = HermesUsageLedger(
            fileURL: ledgerURL,
            automaticallyMigrateLegacy: true)

        let migratedEvents = try await ledger.events(
            from: tokiTestISODate("2026-04-09T00:00:00Z"),
            to: tokiTestISODate("2026-04-10T00:00:00Z"))
        let migratedStatus = try await ledger.status()
        XCTAssertTrue(migratedEvents.isEmpty)
        XCTAssertEqual(migratedStatus.accurateSince, lastObservedAt)
        XCTAssertEqual(migratedStatus.unattributedTokens, 100)

        try await ledger.refresh(
            observations: [hermesObservation(
                sessionID: "legacy-session",
                startedAt: startedAt,
                latestActivityAt: tokiTestISODate("2026-04-09T10:30:00Z"),
                inputTokens: 125)],
            observedAt: tokiTestISODate("2026-04-09T10:31:00Z"))
        let events = try await ledger.events(
            from: tokiTestISODate("2026-04-09T00:00:00Z"),
            to: tokiTestISODate("2026-04-10T00:00:00Z"))
        XCTAssertEqual(events.map(\.counters.inputTokens), [25])
        let persisted = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: Data(contentsOf: ledgerURL)) as? [String: Any])
        XCTAssertEqual(persisted["schemaVersion"] as? Int, 3)
        XCTAssertFalse(FileManager.default.fileExists(atPath: ledgerURL.appendingPathExtension("v1.backup").path))
    }

    func test_hermesUsageLedger_rejectsCorruptOversizedAndSymbolicLinkFiles() async throws {
        let tempDir = try makeHermesTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let corruptURL = tempDir.appendingPathComponent("corrupt.json")
        try writePrivateHermesTestData(Data("{".utf8), to: corruptURL)
        await assertHermesLedgerReadFails(HermesUsageLedger(fileURL: corruptURL))

        let oversizedURL = tempDir.appendingPathComponent("oversized.json")
        FileManager.default.createFile(atPath: oversizedURL.path, contents: Data())
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: oversizedURL.path)
        let oversizedHandle = try FileHandle(forWritingTo: oversizedURL)
        try oversizedHandle.truncate(atOffset: UInt64(16 * 1024 * 1024 + 1))
        try oversizedHandle.close()
        await assertHermesLedgerReadFails(HermesUsageLedger(fileURL: oversizedURL))

        let targetURL = tempDir.appendingPathComponent("target.json")
        try writePrivateHermesTestData(Data("{}".utf8), to: targetURL)
        let symbolicLinkURL = tempDir.appendingPathComponent("link.json")
        try FileManager.default.createSymbolicLink(at: symbolicLinkURL, withDestinationURL: targetURL)
        await assertHermesLedgerReadFails(HermesUsageLedger(fileURL: symbolicLinkURL))
    }
}

extension HermesUsageLedgerTests {
    func test_hermesUsageLedger_usesCompleteLegacyV3PricingCountersAsModelBaseline() async throws {
        let tempDir = try makeHermesTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let ledgerURL = tempDir.appendingPathComponent("hermes-usage-ledger.json")
        let startedAt = tokiTestISODate("2026-04-09T08:00:00Z")
        let initialModelCounters = [
            "legacy-model-a": hermesInputCounters(60),
            "legacy-model-b": hermesInputCounters(40),
        ]
        let ledger = HermesUsageLedger(fileURL: ledgerURL)
        try await ledger.refresh(
            observations: [hermesLegacyV3Observation(
                startedAt: startedAt,
                modelCounters: initialModelCounters,
                modelPricingCounters: initialModelCounters)],
            observedAt: tokiTestISODate("2026-04-09T09:00:00Z"))
        try removeHermesModelCountersFromBaselines(at: ledgerURL)

        let currentModelCounters = [
            "legacy-model-a": hermesInputCounters(80),
            "legacy-model-b": hermesInputCounters(50),
        ]
        let restartedLedger = HermesUsageLedger(fileURL: ledgerURL)
        try await restartedLedger.refresh(
            observations: [hermesLegacyV3Observation(
                startedAt: startedAt,
                modelCounters: currentModelCounters,
                modelPricingCounters: currentModelCounters)],
            observedAt: tokiTestISODate("2026-04-10T10:00:00Z"))
        let events = try await restartedLedger.events(
            from: tokiTestISODate("2026-04-10T00:00:00Z"),
            to: tokiTestISODate("2026-04-11T00:00:00Z"))

        XCTAssertEqual(
            Dictionary(uniqueKeysWithValues: events.map { ($0.model ?? "Mixed", $0.counters.inputTokens) }),
            [
                "legacy-model-a": 20,
                "legacy-model-b": 10,
            ])
    }

    func test_hermesUsageLedger_keepsLegacyV3DeltaMixedWhenPricingCountersArePartial() async throws {
        let tempDir = try makeHermesTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let ledgerURL = tempDir.appendingPathComponent("hermes-usage-ledger.json")
        let startedAt = tokiTestISODate("2026-04-09T08:00:00Z")
        let ledger = HermesUsageLedger(fileURL: ledgerURL)
        try await ledger.refresh(
            observations: [hermesLegacyV3Observation(
                startedAt: startedAt,
                modelCounters: [
                    "legacy-model-a": hermesInputCounters(60),
                    "legacy-model-b": hermesInputCounters(40),
                ],
                modelPricingCounters: [
                    "legacy-model-a": hermesInputCounters(60),
                ])],
            observedAt: tokiTestISODate("2026-04-09T09:00:00Z"))
        try removeHermesModelCountersFromBaselines(at: ledgerURL)

        let restartedLedger = HermesUsageLedger(fileURL: ledgerURL)
        try await restartedLedger.refresh(
            observations: [hermesLegacyV3Observation(
                startedAt: startedAt,
                modelCounters: [
                    "legacy-model-a": hermesInputCounters(80),
                    "legacy-model-b": hermesInputCounters(50),
                ],
                modelPricingCounters: [
                    "legacy-model-a": hermesInputCounters(80),
                ])],
            observedAt: tokiTestISODate("2026-04-10T10:00:00Z"))
        let events = try await restartedLedger.events(
            from: tokiTestISODate("2026-04-10T00:00:00Z"),
            to: tokiTestISODate("2026-04-11T00:00:00Z"))

        XCTAssertEqual(events.count, 1)
        XCTAssertNil(events.first?.model)
        XCTAssertEqual(events.first?.counters.inputTokens, 30)
    }

    func test_hermesUsageLedger_recordsDatedInitialCostOnlyObservation() async throws {
        let tempDir = try makeHermesTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let ledger = HermesUsageLedger(
            fileURL: tempDir.appendingPathComponent("hermes-usage-ledger.json"))
        let baselineAt = tokiTestISODate("2026-04-10T08:00:00Z")
        let startedAt = tokiTestISODate("2026-04-10T09:00:00Z")
        try await ledger.refresh(observations: [], observedAt: baselineAt)

        try await ledger.refresh(
            observations: [hermesCostOnlyObservation(
                sessionID: "dated-cost-only",
                startedAt: startedAt,
                activityAt: startedAt,
                cost: 1.25)],
            observedAt: tokiTestISODate("2026-04-10T10:00:00Z"))
        let events = try await ledger.events(
            from: baselineAt,
            to: tokiTestISODate("2026-04-11T00:00:00Z"))

        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events.first?.counters, .zero)
        XCTAssertEqual(events.first?.cost ?? -1, 1.25, accuracy: 0.000_001)
    }

    func test_hermesUsageLedger_persistsUndatedInitialCostOnlyCarryover() async throws {
        let tempDir = try makeHermesTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let ledgerURL = tempDir.appendingPathComponent("hermes-usage-ledger.json")
        let ledger = HermesUsageLedger(fileURL: ledgerURL)

        try await ledger.refresh(
            observations: [hermesCostOnlyObservation(
                sessionID: "undated-cost-only",
                startedAt: tokiTestISODate("2026-04-09T08:00:00Z"),
                cost: 0.75)],
            observedAt: tokiTestISODate("2026-04-10T10:00:00Z"))
        let restartedLedger = HermesUsageLedger(fileURL: ledgerURL)
        let status = try await restartedLedger.status()
        let events = try await restartedLedger.events(
            from: tokiTestISODate("2026-04-09T00:00:00Z"),
            to: tokiTestISODate("2026-04-11T00:00:00Z"))

        XCTAssertEqual(status.unattributedSessionCount, 1)
        XCTAssertEqual(status.unattributedTokens, 0)
        XCTAssertTrue(events.isEmpty)
    }

    func test_hermesUsageLedger_recordsIncrementalCostOnlyModelUpdate() async throws {
        let tempDir = try makeHermesTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let ledger = HermesUsageLedger(
            fileURL: tempDir.appendingPathComponent("hermes-usage-ledger.json"))
        let startedAt = tokiTestISODate("2026-04-09T08:00:00Z")
        try await ledger.refresh(
            observations: [hermesReportedModelObservation(
                startedAt: startedAt,
                cost: 1)],
            observedAt: tokiTestISODate("2026-04-09T09:00:00Z"))

        try await ledger.refresh(
            observations: [hermesReportedModelObservation(
                startedAt: startedAt,
                cost: 2)],
            observedAt: tokiTestISODate("2026-04-10T10:00:00Z"))
        let events = try await ledger.events(
            from: tokiTestISODate("2026-04-10T00:00:00Z"),
            to: tokiTestISODate("2026-04-11T00:00:00Z"))

        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events.first?.model, "reported-cost-model")
        XCTAssertEqual(events.first?.counters, .zero)
        XCTAssertEqual(events.first?.cost ?? -1, 1, accuracy: 0.000_001)
    }
}

private struct HermesUsageLedgerV1Fixture: Encodable {
    let schemaVersion: Int
    let identifierKey: String
    let baselines: [String: HermesUsageLedgerV1BaselineFixture]
    let events: [HermesUsageLedgerV1EventFixture]
}

private struct HermesUsageLedgerV1BaselineFixture: Encodable {
    let startedAt: Date
    let lastActivityAt: Date
    let lastObservedAt: Date
    let model: String?
    let counters: HermesTokenCounters
    let cost: Double
    let projectName: String?
    let attributionQuality: AttributionQuality
}

private struct HermesUsageLedgerV1EventFixture: Encodable {
    let sessionIdentifier: String
    let timestamp: Date
    let model: String?
    let counters: HermesTokenCounters
    let cost: Double
    let projectName: String?
    let attributionQuality: AttributionQuality
}

private struct LongRunningHermesFixture {
    let tempDirectory: URL
    let databaseURL: URL
    let ledgerURL: URL
    let ledger: HermesUsageLedger
}

private func makeLongRunningHermesFixture() throws -> LongRunningHermesFixture {
    let tempDirectory = try makeHermesTemporaryDirectory()
    let databaseURL = tempDirectory.appendingPathComponent("state.db")
    let ledgerURL = tempDirectory.appendingPathComponent("hermes-usage-ledger.json")
    try createHermesStateDB(
        at: databaseURL,
        rows: [
            HermesSessionFixture(
                id: "long-running-session",
                startedAt: "2026-04-09T08:00:00Z",
                model: "gpt-5.5",
                inputTokens: 100,
                outputTokens: 20,
                cacheReadTokens: 30,
                cacheWriteTokens: 4,
                reasoningTokens: 6,
                cwd: "/srv/private/project",
                gitRepoRoot: nil,
                estimatedCost: 0,
                actualCost: nil),
        ])
    try insertHermesMessage(
        databaseURL: databaseURL,
        sessionID: "long-running-session",
        timestamp: tokiTestISODate("2026-04-09T09:00:00Z"))
    return LongRunningHermesFixture(
        tempDirectory: tempDirectory,
        databaseURL: databaseURL,
        ledgerURL: ledgerURL,
        ledger: HermesUsageLedger(fileURL: ledgerURL))
}

private func recordLongRunningHermesIncrement(in fixture: LongRunningHermesFixture) throws -> Date {
    try updateHermesSession(
        databaseURL: fixture.databaseURL,
        id: "long-running-session",
        model: "gpt-5.5",
        inputTokens: 160,
        outputTokens: 30,
        cacheReadTokens: 50,
        cacheWriteTokens: 5,
        reasoningTokens: 10)
    let latestActivity = tokiTestISODate("2026-04-10T09:30:00Z")
    try insertHermesMessage(
        databaseURL: fixture.databaseURL,
        sessionID: "long-running-session",
        timestamp: latestActivity)
    return latestActivity
}

private func assertHermesLedgerPrivacy(at ledgerURL: URL) throws {
    let ledgerText = try String(contentsOf: ledgerURL, encoding: .utf8)
    XCTAssertFalse(ledgerText.contains("long-running-session"))
    XCTAssertFalse(ledgerText.contains("/srv/private/project"))
    let ledgerPermissions = try XCTUnwrap(
        FileManager.default.attributesOfItem(atPath: ledgerURL.path)[.posixPermissions] as? NSNumber)
    XCTAssertEqual(ledgerPermissions.intValue & 0o077, 0)
}

private func hermesInputCounters(_ inputTokens: Int) -> HermesTokenCounters {
    HermesTokenCounters(
        inputTokens: inputTokens,
        outputTokens: 0,
        cacheReadTokens: 0,
        cacheWriteTokens: 0,
        reasoningTokens: 0)
}

private func hermesLegacyV3Observation(
    startedAt: Date,
    modelCounters: [String: HermesTokenCounters],
    modelPricingCounters: [String: HermesTokenCounters]) -> HermesSessionObservation {
    let counters = modelCounters.values.reduce(HermesTokenCounters.zero) {
        $0.adding($1)
    }
    return HermesSessionObservation(
        sessionID: "legacy-v3-model-session",
        startedAt: startedAt,
        earliestActivityAt: nil,
        latestActivityAt: nil,
        model: nil,
        counters: counters,
        modelCounters: modelCounters,
        cost: 0,
        costIsDerivedFromModelPricing: true,
        modelPricingCounters: modelPricingCounters,
        projectName: nil,
        attributionQuality: .unknown)
}

private func removeHermesModelCountersFromBaselines(at ledgerURL: URL) throws {
    guard var document = try JSONSerialization.jsonObject(
        with: Data(contentsOf: ledgerURL)) as? [String: Any],
        var baselines = document["baselines"] as? [String: Any],
        !baselines.isEmpty else {
        throw NSError(domain: "HermesUsageLedgerTests", code: 1)
    }
    for (identifier, value) in baselines {
        guard var baseline = value as? [String: Any] else {
            throw NSError(domain: "HermesUsageLedgerTests", code: 2)
        }
        baseline.removeValue(forKey: "modelCounters")
        baselines[identifier] = baseline
    }
    document["baselines"] = baselines
    let data = try JSONSerialization.data(withJSONObject: document, options: [.sortedKeys])
    try writePrivateHermesTestData(data, to: ledgerURL)
}

private func hermesCostOnlyObservation(
    sessionID: String,
    startedAt: Date,
    activityAt: Date? = nil,
    cost: Double) -> HermesSessionObservation {
    HermesSessionObservation(
        sessionID: sessionID,
        startedAt: startedAt,
        earliestActivityAt: activityAt,
        latestActivityAt: activityAt,
        model: "cost-only-model",
        counters: .zero,
        cost: cost,
        projectName: nil,
        attributionQuality: .unknown)
}

private func hermesReportedModelObservation(
    startedAt: Date,
    cost: Double) -> HermesSessionObservation {
    let counters = hermesInputCounters(100)
    return HermesSessionObservation(
        sessionID: "reported-cost-session",
        startedAt: startedAt,
        earliestActivityAt: nil,
        latestActivityAt: nil,
        model: "reported-cost-model",
        counters: counters,
        modelCounters: ["reported-cost-model": counters],
        cost: cost,
        reportedCost: cost,
        modelReportedCosts: ["reported-cost-model": cost],
        modelPricingCounters: [:],
        projectName: nil,
        attributionQuality: .unknown)
}
