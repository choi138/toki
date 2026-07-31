// swiftlint:disable file_length
import TokiUsageCore
import XCTest
@testable import TokiUsageReaders

final class HermesPricingRefreshTests: XCTestCase {
    func test_hermesReader_pricesOnlyTokenDeltaAfterSupplementRateChanges() async throws {
        let tempDir = try makeHermesTemporaryDirectory()
        defer {
            ModelPricingSupplement.install([:])
            try? FileManager.default.removeItem(at: tempDir)
        }
        let model = "remote-hermes-model"
        let initialPrice = ModelPrice(
            inputPerMillion: 1,
            outputPerMillion: 1,
            cacheReadPerMillion: 1,
            cacheWritePerMillion: 1)
        let updatedPrice = ModelPrice(
            inputPerMillion: 10,
            outputPerMillion: 10,
            cacheReadPerMillion: 10,
            cacheWritePerMillion: 10)
        ModelPricingSupplement.install([model: initialPrice])

        let dbURL = tempDir.appendingPathComponent("state.db")
        let ledgerURL = tempDir.appendingPathComponent("hermes-usage-ledger.json")
        try createHermesPricingRefreshDatabase(at: dbURL, model: model)
        let ledger = HermesUsageLedger(fileURL: ledgerURL)
        try await ledger.refresh(
            observations: [],
            observedAt: tokiTestISODate("2026-04-09T09:00:00Z"))
        let initialReader = HermesReader(
            dbPathOverride: dbURL.path,
            usageLedger: ledger,
            now: { tokiTestISODate("2026-04-09T10:00:00Z") })
        let initialUsage = try await initialReader.readUsage(
            from: tokiTestISODate("2026-04-09T00:00:00Z"),
            to: tokiTestISODate("2026-04-10T00:00:00Z"))
        XCTAssertEqual(initialUsage.totalTokens, 0)

        let priceChange = tokiTestISODate("2026-04-10T09:00:00Z")
        ModelPricingSupplement.install(priceHistories: [
            model: [
                ModelPricingSupplement.PriceVersion(
                    effectiveFrom: .distantPast,
                    price: initialPrice),
                ModelPricingSupplement.PriceVersion(
                    effectiveFrom: priceChange,
                    price: updatedPrice),
            ],
        ])
        try updateHermesModelUsage(
            databaseURL: dbURL,
            sessionID: "remote-priced-session",
            task: "approval",
            inputTokens: 160)

        let updatedReader = HermesReader(
            dbPathOverride: dbURL.path,
            usageLedger: HermesUsageLedger(fileURL: ledgerURL),
            now: { tokiTestISODate("2026-04-10T10:00:00Z") })
        let increment = try await updatedReader.readUsage(
            from: tokiTestISODate("2026-04-10T00:00:00Z"),
            to: tokiTestISODate("2026-04-11T00:00:00Z"))

        XCTAssertEqual(increment.inputTokens, 60)
        XCTAssertEqual(increment.totalTokens, 60)
        XCTAssertEqual(
            increment.cost,
            updatedPrice.cost(input: 60, output: 0, cacheRead: 0, cacheWrite: 0),
            accuracy: 0.000001)
    }
}

extension HermesPricingRefreshTests {
    func test_hermesReader_pricesSessionOnlyIncrementAtLatestActivityAfterRateChange() async throws {
        let tempDir = try makeHermesTemporaryDirectory()
        defer {
            ModelPricingSupplement.install([:])
            try? FileManager.default.removeItem(at: tempDir)
        }
        let model = "session-only-pricing-model"
        let initialPrice = uniformHermesModelPrice(perMillion: 1)
        let updatedPrice = uniformHermesModelPrice(perMillion: 10)
        ModelPricingSupplement.install(priceHistories: [
            model: [
                ModelPricingSupplement.PriceVersion(
                    effectiveFrom: .distantPast,
                    price: initialPrice),
                ModelPricingSupplement.PriceVersion(
                    effectiveFrom: tokiTestISODate("2026-04-10T10:00:00Z"),
                    price: updatedPrice),
            ],
        ])

        let dbURL = tempDir.appendingPathComponent("state.db")
        let ledgerURL = tempDir.appendingPathComponent("hermes-usage-ledger.json")
        try createHermesStateDB(
            at: dbURL,
            rows: [HermesSessionFixture(
                id: "session-only-pricing",
                startedAt: "2026-04-10T09:00:00Z",
                model: model,
                inputTokens: 100,
                outputTokens: 0,
                cacheReadTokens: 0,
                cacheWriteTokens: 0,
                reasoningTokens: 0,
                cwd: nil,
                gitRepoRoot: nil,
                estimatedCost: 0,
                actualCost: 0)])
        let ledger = HermesUsageLedger(fileURL: ledgerURL)
        try await ledger.refresh(
            observations: [],
            observedAt: tokiTestISODate("2026-04-10T08:00:00Z"))

        let initialUsage = try await HermesReader(
            dbPathOverride: dbURL.path,
            usageLedger: ledger,
            now: { tokiTestISODate("2026-04-10T09:30:00Z") })
            .readUsage(
                from: tokiTestISODate("2026-04-10T00:00:00Z"),
                to: tokiTestISODate("2026-04-10T10:00:00Z"))
        XCTAssertEqual(
            initialUsage.cost,
            initialPrice.cost(input: 100, output: 0, cacheRead: 0, cacheWrite: 0),
            accuracy: 0.000001)

        try updateHermesSession(
            databaseURL: dbURL,
            id: "session-only-pricing",
            model: model,
            inputTokens: 160)
        let latestActivity = tokiTestISODate("2026-04-10T10:30:00Z")
        try insertHermesMessage(
            databaseURL: dbURL,
            sessionID: "session-only-pricing",
            timestamp: latestActivity)

        let increment = try await HermesReader(
            dbPathOverride: dbURL.path,
            usageLedger: HermesUsageLedger(fileURL: ledgerURL),
            now: { tokiTestISODate("2026-04-10T11:00:00Z") })
            .readUsage(
                from: tokiTestISODate("2026-04-10T10:00:00Z"),
                to: tokiTestISODate("2026-04-10T12:00:00Z"))

        XCTAssertEqual(increment.inputTokens, 60)
        XCTAssertEqual(
            increment.cost,
            updatedPrice.cost(input: 60, output: 0, cacheRead: 0, cacheWrite: 0),
            accuracy: 0.000001)
        XCTAssertEqual(increment.tokenEvents.map(\.timestamp), [latestActivity])
    }

    func test_hermesReader_pricesMultiModelTokenDeltasAfterRateChanges() async throws {
        let tempDir = try makeHermesTemporaryDirectory()
        defer {
            ModelPricingSupplement.install([:])
            try? FileManager.default.removeItem(at: tempDir)
        }
        let firstModel = "remote-hermes-model-a"
        let secondModel = "remote-hermes-model-b"
        let initialFirstPrice = uniformHermesModelPrice(perMillion: 1)
        let initialSecondPrice = uniformHermesModelPrice(perMillion: 2)
        let updatedFirstPrice = uniformHermesModelPrice(perMillion: 10)
        let updatedSecondPrice = uniformHermesModelPrice(perMillion: 20)
        ModelPricingSupplement.install([
            firstModel: initialFirstPrice,
            secondModel: initialSecondPrice,
        ])

        let dbURL = tempDir.appendingPathComponent("state.db")
        let ledgerURL = tempDir.appendingPathComponent("hermes-usage-ledger.json")
        try createMultiModelHermesPricingDatabase(
            at: dbURL,
            firstModel: firstModel,
            secondModel: secondModel)
        let ledger = HermesUsageLedger(fileURL: ledgerURL)
        try await ledger.refresh(
            observations: [],
            observedAt: tokiTestISODate("2026-04-09T09:00:00Z"))
        let initialUsage = try await HermesReader(
            dbPathOverride: dbURL.path,
            usageLedger: ledger,
            now: { tokiTestISODate("2026-04-09T10:00:00Z") })
            .readUsage(
                from: tokiTestISODate("2026-04-09T00:00:00Z"),
                to: tokiTestISODate("2026-04-10T00:00:00Z"))
        XCTAssertEqual(initialUsage.totalTokens, 0)

        let priceChange = tokiTestISODate("2026-04-10T09:00:00Z")
        ModelPricingSupplement.install(priceHistories: [
            firstModel: [
                ModelPricingSupplement.PriceVersion(
                    effectiveFrom: .distantPast,
                    price: initialFirstPrice),
                ModelPricingSupplement.PriceVersion(
                    effectiveFrom: priceChange,
                    price: updatedFirstPrice),
            ],
            secondModel: [
                ModelPricingSupplement.PriceVersion(
                    effectiveFrom: .distantPast,
                    price: initialSecondPrice),
                ModelPricingSupplement.PriceVersion(
                    effectiveFrom: priceChange,
                    price: updatedSecondPrice),
            ],
        ])
        try updateHermesModelUsage(
            databaseURL: dbURL,
            sessionID: "multi-model-session",
            task: "approval-a",
            inputTokens: 160)
        try updateHermesModelUsage(
            databaseURL: dbURL,
            sessionID: "multi-model-session",
            task: "approval-b",
            inputTokens: 140)

        let increment = try await HermesReader(
            dbPathOverride: dbURL.path,
            usageLedger: HermesUsageLedger(fileURL: ledgerURL),
            now: { tokiTestISODate("2026-04-10T10:00:00Z") })
            .readUsage(
                from: tokiTestISODate("2026-04-10T00:00:00Z"),
                to: tokiTestISODate("2026-04-11T00:00:00Z"))

        let expectedCost =
            updatedFirstPrice.cost(input: 60, output: 0, cacheRead: 0, cacheWrite: 0)
                + updatedSecondPrice.cost(input: 40, output: 0, cacheRead: 0, cacheWrite: 0)
        XCTAssertEqual(increment.inputTokens, 100)
        XCTAssertEqual(increment.totalTokens, 100)
        XCTAssertEqual(increment.cost, expectedCost, accuracy: 0.000001)
        XCTAssertEqual(increment.perModel[firstModel]?.totalTokens, 60)
        XCTAssertEqual(increment.perModel[secondModel]?.totalTokens, 40)
        XCTAssertEqual(
            hermesEventTokenTotalsByModel(in: increment.tokenEvents),
            [firstModel: 60, secondModel: 40])
    }
}

extension HermesPricingRefreshTests {
    // swiftlint:disable:next function_body_length
    func test_hermesReader_pricesOnlyDerivedPartOfMixedCostAfterRateChange() async throws {
        let tempDir = try makeHermesTemporaryDirectory()
        defer {
            ModelPricingSupplement.install([:])
            try? FileManager.default.removeItem(at: tempDir)
        }
        let reportedModel = "reported-hermes-model"
        let derivedModel = "derived-hermes-model"
        let reportedCatalogPrice = uniformHermesModelPrice(perMillion: 50)
        let initialPrice = uniformHermesModelPrice(perMillion: 1)
        let updatedPrice = uniformHermesModelPrice(perMillion: 10)
        ModelPricingSupplement.install([
            reportedModel: reportedCatalogPrice,
            derivedModel: initialPrice,
        ])

        let dbURL = tempDir.appendingPathComponent("state.db")
        let ledgerURL = tempDir.appendingPathComponent("hermes-usage-ledger.json")
        try createMixedCostHermesPricingDatabase(
            at: dbURL,
            reportedModel: reportedModel,
            derivedModel: derivedModel)
        let ledger = HermesUsageLedger(fileURL: ledgerURL)
        try await ledger.refresh(
            observations: [],
            observedAt: tokiTestISODate("2026-04-09T09:00:00Z"))
        let initialUsage = try await HermesReader(
            dbPathOverride: dbURL.path,
            usageLedger: ledger,
            now: { tokiTestISODate("2026-04-09T10:00:00Z") })
            .readUsage(
                from: tokiTestISODate("2026-04-09T00:00:00Z"),
                to: tokiTestISODate("2026-04-10T00:00:00Z"))
        XCTAssertEqual(initialUsage.totalTokens, 0)

        ModelPricingSupplement.install(priceHistories: [
            reportedModel: [
                ModelPricingSupplement.PriceVersion(
                    effectiveFrom: .distantPast,
                    price: reportedCatalogPrice),
            ],
            derivedModel: [
                ModelPricingSupplement.PriceVersion(
                    effectiveFrom: .distantPast,
                    price: initialPrice),
                ModelPricingSupplement.PriceVersion(
                    effectiveFrom: tokiTestISODate("2026-04-10T09:00:00Z"),
                    price: updatedPrice),
            ],
        ])
        try updateHermesModelUsage(
            databaseURL: dbURL,
            sessionID: "mixed-cost-session",
            task: "derived",
            inputTokens: 160)
        try updateHermesModelUsage(
            databaseURL: dbURL,
            sessionID: "mixed-cost-session",
            task: "reported",
            inputTokens: 160,
            actualCost: 1.6)

        let increment = try await HermesReader(
            dbPathOverride: dbURL.path,
            usageLedger: HermesUsageLedger(fileURL: ledgerURL),
            now: { tokiTestISODate("2026-04-10T10:00:00Z") })
            .readUsage(
                from: tokiTestISODate("2026-04-10T00:00:00Z"),
                to: tokiTestISODate("2026-04-11T00:00:00Z"))

        let expectedReportedCost = 0.6
        let expectedDerivedCost = updatedPrice.cost(
            input: 60,
            output: 0,
            cacheRead: 0,
            cacheWrite: 0)
        XCTAssertEqual(increment.inputTokens, 120)
        XCTAssertEqual(increment.totalTokens, 120)
        XCTAssertEqual(
            increment.cost,
            expectedReportedCost + expectedDerivedCost,
            accuracy: 0.000001)
        XCTAssertEqual(increment.perModel[reportedModel]?.totalTokens, 60)
        XCTAssertEqual(increment.perModel[derivedModel]?.totalTokens, 60)
        XCTAssertEqual(
            increment.perModel[reportedModel]?.cost ?? -1,
            expectedReportedCost,
            accuracy: 0.000001)
        XCTAssertEqual(
            increment.perModel[derivedModel]?.cost ?? -1,
            expectedDerivedCost,
            accuracy: 0.000001)
    }

    // swiftlint:disable:next function_body_length
    func test_hermesReader_preservesDerivedModelCostWhenReportedSessionTotalWins() async throws {
        let tempDir = try makeHermesTemporaryDirectory()
        defer {
            ModelPricingSupplement.install([:])
            try? FileManager.default.removeItem(at: tempDir)
        }
        let reportedModel = "reported-session-winner-model"
        let derivedModel = "derived-session-winner-model"
        let derivedPrice = uniformHermesModelPrice(perMillion: 10000)
        ModelPricingSupplement.install([derivedModel: derivedPrice])

        let dbURL = tempDir.appendingPathComponent("state.db")
        let ledgerURL = tempDir.appendingPathComponent("hermes-usage-ledger.json")
        try createHermesStateDB(
            at: dbURL,
            rows: [HermesSessionFixture(
                id: "session-total-wins",
                startedAt: "2026-04-10T09:00:00Z",
                model: nil,
                inputTokens: 200,
                outputTokens: 0,
                cacheReadTokens: 0,
                cacheWriteTokens: 0,
                reasoningTokens: 0,
                cwd: nil,
                gitRepoRoot: nil,
                estimatedCost: 0,
                actualCost: 12)])
        try insertHermesModelUsage(
            databaseURL: dbURL,
            rows: [
                HermesModelUsageFixture(
                    sessionID: "session-total-wins",
                    model: reportedModel,
                    task: "reported",
                    apiCallCount: 1,
                    inputTokens: 100,
                    outputTokens: 0,
                    cacheReadTokens: 0,
                    cacheWriteTokens: 0,
                    reasoningTokens: 0,
                    estimatedCost: 0,
                    actualCost: 10),
                HermesModelUsageFixture(
                    sessionID: "session-total-wins",
                    model: derivedModel,
                    task: "derived",
                    apiCallCount: 1,
                    inputTokens: 100,
                    outputTokens: 0,
                    cacheReadTokens: 0,
                    cacheWriteTokens: 0,
                    reasoningTokens: 0,
                    estimatedCost: 0,
                    actualCost: 0),
            ])
        let ledger = HermesUsageLedger(fileURL: ledgerURL)
        try await ledger.refresh(
            observations: [],
            observedAt: tokiTestISODate("2026-04-10T08:00:00Z"))

        let usage = try await HermesReader(
            dbPathOverride: dbURL.path,
            usageLedger: ledger,
            now: { tokiTestISODate("2026-04-10T10:00:00Z") })
            .readUsage(
                from: tokiTestISODate("2026-04-10T00:00:00Z"),
                to: tokiTestISODate("2026-04-11T00:00:00Z"))

        let expectedDerivedCost = derivedPrice.cost(
            input: 100,
            output: 0,
            cacheRead: 0,
            cacheWrite: 0)
        let costOnlyEvents = usage.tokenEvents.filter { $0.totalTokens == 0 }
        XCTAssertEqual(usage.inputTokens, 200)
        XCTAssertEqual(usage.cost, 12, accuracy: 0.000001)
        XCTAssertEqual(usage.perModel[reportedModel]?.cost ?? -1, 10, accuracy: 0.000001)
        XCTAssertEqual(
            usage.perModel[derivedModel]?.cost ?? -1,
            expectedDerivedCost,
            accuracy: 0.000001)
        XCTAssertEqual(
            usage.perModel[UsageModelGrouping.mixedOrUnattributedKey]?.totalTokens,
            0)
        XCTAssertEqual(
            usage.perModel[UsageModelGrouping.mixedOrUnattributedKey]?.cost ?? -1,
            1,
            accuracy: 0.000001)
        XCTAssertEqual(costOnlyEvents.count, 1)
        XCTAssertEqual(costOnlyEvents.first?.cost ?? -1, 1, accuracy: 0.000001)
        XCTAssertEqual(usage.tokenEvents.reduce(0) { $0 + $1.cost }, 12, accuracy: 0.000001)
    }

    func test_hermesReader_preservesTokenDeltaWhenActualCostDropsBelowEstimate() async throws {
        let tempDir = try makeHermesTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let dbURL = tempDir.appendingPathComponent("state.db")
        let ledgerURL = tempDir.appendingPathComponent("hermes-usage-ledger.json")
        try createHermesStateDB(
            at: dbURL,
            rows: [
                HermesSessionFixture(
                    id: "reported-cost-session",
                    startedAt: "2026-04-09T08:00:00Z",
                    model: "gpt-5.5",
                    inputTokens: 100,
                    outputTokens: 0,
                    cacheReadTokens: 0,
                    cacheWriteTokens: 0,
                    reasoningTokens: 0,
                    cwd: nil,
                    gitRepoRoot: nil,
                    estimatedCost: 1,
                    actualCost: nil),
            ])
        let initialLedger = HermesUsageLedger(fileURL: ledgerURL)
        try await initialLedger.refresh(
            observations: [],
            observedAt: tokiTestISODate("2026-04-09T09:00:00Z"))
        let initialUsage = try await HermesReader(
            dbPathOverride: dbURL.path,
            usageLedger: initialLedger,
            now: { tokiTestISODate("2026-04-09T10:00:00Z") })
            .readUsage(
                from: tokiTestISODate("2026-04-09T00:00:00Z"),
                to: tokiTestISODate("2026-04-10T00:00:00Z"))
        XCTAssertEqual(initialUsage.totalTokens, 0)

        try updateHermesSessionReportedUsage(
            databaseURL: dbURL,
            id: "reported-cost-session",
            inputTokens: 160,
            estimatedCost: 1,
            actualCost: 0.8)
        let updatedLedger = HermesUsageLedger(fileURL: ledgerURL)
        let increment = try await HermesReader(
            dbPathOverride: dbURL.path,
            usageLedger: updatedLedger,
            now: { tokiTestISODate("2026-04-10T10:00:00Z") })
            .readUsage(
                from: tokiTestISODate("2026-04-10T00:00:00Z"),
                to: tokiTestISODate("2026-04-11T00:00:00Z"))
        let status = try await updatedLedger.status()

        XCTAssertEqual(increment.inputTokens, 60)
        XCTAssertEqual(increment.totalTokens, 60)
        XCTAssertEqual(increment.cost, 0, accuracy: 0.000001)
        XCTAssertEqual(status.unattributedTokens, 100)
    }

    // swiftlint:disable:next function_body_length
    func test_hermesReader_rebaselinesLegacyV3CostBeforeMultiModelDelta() async throws {
        let tempDir = try makeHermesTemporaryDirectory()
        defer {
            ModelPricingSupplement.install([:])
            try? FileManager.default.removeItem(at: tempDir)
        }
        let firstModel = "legacy-hermes-model-a"
        let secondModel = "legacy-hermes-model-b"
        let initialFirstPrice = uniformHermesModelPrice(perMillion: 1)
        let initialSecondPrice = uniformHermesModelPrice(perMillion: 2)
        let updatedFirstPrice = uniformHermesModelPrice(perMillion: 10)
        let updatedSecondPrice = uniformHermesModelPrice(perMillion: 20)
        ModelPricingSupplement.install([
            firstModel: initialFirstPrice,
            secondModel: initialSecondPrice,
        ])

        let dbURL = tempDir.appendingPathComponent("state.db")
        let ledgerURL = tempDir.appendingPathComponent("hermes-usage-ledger.json")
        try createMultiModelHermesPricingDatabase(
            at: dbURL,
            firstModel: firstModel,
            secondModel: secondModel)
        let initialLedger = HermesUsageLedger(fileURL: ledgerURL)
        try await initialLedger.refresh(
            observations: [],
            observedAt: tokiTestISODate("2026-04-09T09:00:00Z"))
        let initialUsage = try await HermesReader(
            dbPathOverride: dbURL.path,
            usageLedger: initialLedger,
            now: { tokiTestISODate("2026-04-09T10:00:00Z") })
            .readUsage(
                from: tokiTestISODate("2026-04-09T00:00:00Z"),
                to: tokiTestISODate("2026-04-10T00:00:00Z"))
        XCTAssertEqual(initialUsage.totalTokens, 0)
        try removeHermesCostBreakdownFromBaselines(at: ledgerURL)

        ModelPricingSupplement.install(priceHistories: [
            firstModel: [
                ModelPricingSupplement.PriceVersion(
                    effectiveFrom: .distantPast,
                    price: initialFirstPrice),
                ModelPricingSupplement.PriceVersion(
                    effectiveFrom: tokiTestISODate("2026-04-10T09:00:00Z"),
                    price: updatedFirstPrice),
            ],
            secondModel: [
                ModelPricingSupplement.PriceVersion(
                    effectiveFrom: .distantPast,
                    price: initialSecondPrice),
                ModelPricingSupplement.PriceVersion(
                    effectiveFrom: tokiTestISODate("2026-04-10T09:00:00Z"),
                    price: updatedSecondPrice),
            ],
        ])
        try updateHermesModelUsage(
            databaseURL: dbURL,
            sessionID: "multi-model-session",
            task: "approval-a",
            inputTokens: 160)
        try updateHermesModelUsage(
            databaseURL: dbURL,
            sessionID: "multi-model-session",
            task: "approval-b",
            inputTokens: 140)

        let rebasedLedger = HermesUsageLedger(fileURL: ledgerURL)
        let rebasedUsage = try await HermesReader(
            dbPathOverride: dbURL.path,
            usageLedger: rebasedLedger,
            now: { tokiTestISODate("2026-04-10T10:00:00Z") })
            .readUsage(
                from: tokiTestISODate("2026-04-10T00:00:00Z"),
                to: tokiTestISODate("2026-04-11T00:00:00Z"))
        let rebasedStatus = try await rebasedLedger.status()
        let rebasedEvents = try await rebasedLedger.events(
            from: tokiTestISODate("2026-04-10T00:00:00Z"),
            to: tokiTestISODate("2026-04-11T00:00:00Z"))

        XCTAssertEqual(rebasedUsage.totalTokens, 0)
        XCTAssertEqual(rebasedUsage.cost, 0)
        XCTAssertTrue(rebasedEvents.isEmpty)
        XCTAssertEqual(rebasedStatus.unattributedSessionCount, 1)
        XCTAssertEqual(rebasedStatus.unattributedTokens, 300)
        let upgradedBaseline = try persistedHermesBaseline(at: ledgerURL)
        XCTAssertEqual((upgradedBaseline["reportedCost"] as? NSNumber)?.doubleValue, 0)
        XCTAssertEqual(
            (upgradedBaseline["modelPricingCounters"] as? [String: Any])?.count,
            2)

        try updateHermesModelUsage(
            databaseURL: dbURL,
            sessionID: "multi-model-session",
            task: "approval-a",
            inputTokens: 170)
        try updateHermesModelUsage(
            databaseURL: dbURL,
            sessionID: "multi-model-session",
            task: "approval-b",
            inputTokens: 150)
        let resumedUsage = try await HermesReader(
            dbPathOverride: dbURL.path,
            usageLedger: HermesUsageLedger(fileURL: ledgerURL),
            now: { tokiTestISODate("2026-04-10T11:00:00Z") })
            .readUsage(
                from: tokiTestISODate("2026-04-10T00:00:00Z"),
                to: tokiTestISODate("2026-04-11T00:00:00Z"))

        let expectedCost =
            updatedFirstPrice.cost(input: 10, output: 0, cacheRead: 0, cacheWrite: 0)
                + updatedSecondPrice.cost(input: 10, output: 0, cacheRead: 0, cacheWrite: 0)
        XCTAssertEqual(resumedUsage.inputTokens, 20)
        XCTAssertEqual(resumedUsage.totalTokens, 20)
        XCTAssertEqual(resumedUsage.cost, expectedCost, accuracy: 0.000001)
    }
}

extension HermesPricingRefreshTests {
    // swiftlint:disable:next function_body_length
    func test_hermesReader_allocatesInitialDerivedCostsAtModelUsagePricingInstant() async throws {
        let tempDir = try makeHermesTemporaryDirectory()
        defer {
            ModelPricingSupplement.install([:])
            try? FileManager.default.removeItem(at: tempDir)
        }
        let firstModel = "dated-hermes-model-a"
        let secondModel = "dated-hermes-model-b"
        let initialFirstPrice = uniformHermesModelPrice(perMillion: 1)
        let updatedFirstPrice = uniformHermesModelPrice(perMillion: 10)
        let secondPrice = uniformHermesModelPrice(perMillion: 2)
        ModelPricingSupplement.install(priceHistories: [
            firstModel: [
                ModelPricingSupplement.PriceVersion(
                    effectiveFrom: .distantPast,
                    price: initialFirstPrice),
                ModelPricingSupplement.PriceVersion(
                    effectiveFrom: tokiTestISODate("2026-04-10T10:00:00Z"),
                    price: updatedFirstPrice),
            ],
            secondModel: [
                ModelPricingSupplement.PriceVersion(
                    effectiveFrom: .distantPast,
                    price: secondPrice),
            ],
        ])

        let dbURL = tempDir.appendingPathComponent("state.db")
        let ledgerURL = tempDir.appendingPathComponent("hermes-usage-ledger.json")
        try createHermesStateDB(
            at: dbURL,
            rows: [HermesSessionFixture(
                id: "dated-mixed-session",
                startedAt: "2026-04-10T08:30:00Z",
                model: nil,
                inputTokens: 0,
                outputTokens: 0,
                cacheReadTokens: 0,
                cacheWriteTokens: 0,
                reasoningTokens: 0,
                cwd: nil,
                gitRepoRoot: nil,
                estimatedCost: 0,
                actualCost: nil)])
        try insertHermesMessage(
            databaseURL: dbURL,
            sessionID: "dated-mixed-session",
            timestamp: tokiTestISODate("2026-04-10T09:00:00Z"))
        try insertHermesModelUsage(
            databaseURL: dbURL,
            rows: [
                HermesModelUsageFixture(
                    sessionID: "dated-mixed-session",
                    model: firstModel,
                    task: "first",
                    apiCallCount: 1,
                    inputTokens: 100,
                    outputTokens: 0,
                    cacheReadTokens: 0,
                    cacheWriteTokens: 0,
                    reasoningTokens: 0,
                    estimatedCost: 0,
                    actualCost: 0),
                HermesModelUsageFixture(
                    sessionID: "dated-mixed-session",
                    model: secondModel,
                    task: "second",
                    apiCallCount: 1,
                    inputTokens: 100,
                    outputTokens: 0,
                    cacheReadTokens: 0,
                    cacheWriteTokens: 0,
                    reasoningTokens: 0,
                    estimatedCost: 0,
                    actualCost: 0),
            ])
        let ledger = HermesUsageLedger(fileURL: ledgerURL)
        try await ledger.refresh(
            observations: [],
            observedAt: tokiTestISODate("2026-04-10T08:00:00Z"))

        let usage = try await HermesReader(
            dbPathOverride: dbURL.path,
            usageLedger: ledger,
            now: { tokiTestISODate("2026-04-10T11:00:00Z") })
            .readUsage(
                from: tokiTestISODate("2026-04-10T00:00:00Z"),
                to: tokiTestISODate("2026-04-11T00:00:00Z"))

        XCTAssertEqual(
            usage.perModel[firstModel]?.cost ?? -1,
            updatedFirstPrice.cost(input: 100, output: 0, cacheRead: 0, cacheWrite: 0),
            accuracy: 0.000001)
        XCTAssertEqual(
            usage.perModel[secondModel]?.cost ?? -1,
            secondPrice.cost(input: 100, output: 0, cacheRead: 0, cacheWrite: 0),
            accuracy: 0.000001)
        XCTAssertEqual(Set(usage.tokenEvents.map(\.timestamp)), [
            tokiTestISODate("2026-04-10T09:00:00Z"),
        ])
        XCTAssertEqual(usage.activityEvents.count, 1)
        XCTAssertEqual(
            usage.activityEvents.first?.key,
            UsageModelGrouping.mixedOrUnattributedKey)
        XCTAssertEqual(
            usage.perModel[UsageModelGrouping.mixedOrUnattributedKey]?.activeSeconds ?? -1,
            30,
            accuracy: 0.001)
        XCTAssertEqual(usage.activeSeconds, 30, accuracy: 0.001)
    }

    // swiftlint:disable:next function_body_length
    func test_hermesReader_preservesReportedCostByModelAcrossRestart() async throws {
        let tempDir = try makeHermesTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let expensiveModel = "reported-expensive-model"
        let cheapModel = "reported-cheap-model"
        let dbURL = tempDir.appendingPathComponent("state.db")
        let ledgerURL = tempDir.appendingPathComponent("hermes-usage-ledger.json")
        try createHermesStateDB(
            at: dbURL,
            rows: [HermesSessionFixture(
                id: "reported-mixed-session",
                startedAt: "2026-04-10T09:00:00Z",
                model: nil,
                inputTokens: 250,
                outputTokens: 0,
                cacheReadTokens: 0,
                cacheWriteTokens: 0,
                reasoningTokens: 0,
                cwd: nil,
                gitRepoRoot: nil,
                estimatedCost: 0,
                actualCost: 12)])
        try insertHermesModelUsage(
            databaseURL: dbURL,
            rows: [
                HermesModelUsageFixture(
                    sessionID: "reported-mixed-session",
                    model: expensiveModel,
                    task: "expensive",
                    apiCallCount: 1,
                    inputTokens: 100,
                    outputTokens: 0,
                    cacheReadTokens: 0,
                    cacheWriteTokens: 0,
                    reasoningTokens: 0,
                    estimatedCost: 0,
                    actualCost: 10),
                HermesModelUsageFixture(
                    sessionID: "reported-mixed-session",
                    model: cheapModel,
                    task: "cheap",
                    apiCallCount: 1,
                    inputTokens: 100,
                    outputTokens: 0,
                    cacheReadTokens: 0,
                    cacheWriteTokens: 0,
                    reasoningTokens: 0,
                    estimatedCost: 0,
                    actualCost: 1),
            ])
        let ledger = HermesUsageLedger(fileURL: ledgerURL)
        try await ledger.refresh(
            observations: [],
            observedAt: tokiTestISODate("2026-04-10T08:00:00Z"))
        let initialUsage = try await HermesReader(
            dbPathOverride: dbURL.path,
            usageLedger: ledger,
            now: { tokiTestISODate("2026-04-10T10:00:00Z") })
            .readUsage(
                from: tokiTestISODate("2026-04-10T00:00:00Z"),
                to: tokiTestISODate("2026-04-10T10:30:00Z"))
        XCTAssertEqual(initialUsage.inputTokens, 250)
        XCTAssertEqual(initialUsage.cost, 12, accuracy: 0.000001)
        XCTAssertEqual(initialUsage.perModel[expensiveModel]?.cost ?? -1, 10, accuracy: 0.000001)
        XCTAssertEqual(initialUsage.perModel[cheapModel]?.cost ?? -1, 1, accuracy: 0.000001)
        XCTAssertEqual(
            initialUsage.perModel[UsageModelGrouping.mixedOrUnattributedKey]?.totalTokens,
            50)
        XCTAssertEqual(
            initialUsage.perModel[UsageModelGrouping.mixedOrUnattributedKey]?.cost ?? -1,
            1,
            accuracy: 0.000001)
        XCTAssertEqual(initialUsage.activityEvents.count, 1)
        XCTAssertEqual(
            initialUsage.activityEvents.first?.key,
            UsageModelGrouping.mixedOrUnattributedKey)

        try updateHermesModelUsage(
            databaseURL: dbURL,
            sessionID: "reported-mixed-session",
            task: "expensive",
            inputTokens: 200,
            actualCost: 20)
        try updateHermesModelUsage(
            databaseURL: dbURL,
            sessionID: "reported-mixed-session",
            task: "cheap",
            inputTokens: 200,
            actualCost: 2)
        try updateHermesSessionReportedUsage(
            databaseURL: dbURL,
            id: "reported-mixed-session",
            inputTokens: 450,
            estimatedCost: 0,
            actualCost: 24)
        let increment = try await HermesReader(
            dbPathOverride: dbURL.path,
            usageLedger: HermesUsageLedger(fileURL: ledgerURL),
            now: { tokiTestISODate("2026-04-10T11:00:00Z") })
            .readUsage(
                from: tokiTestISODate("2026-04-10T10:30:00Z"),
                to: tokiTestISODate("2026-04-10T12:00:00Z"))

        XCTAssertEqual(increment.inputTokens, 200)
        XCTAssertEqual(increment.cost, 12, accuracy: 0.000001)
        XCTAssertEqual(increment.perModel[expensiveModel]?.totalTokens, 100)
        XCTAssertEqual(increment.perModel[cheapModel]?.totalTokens, 100)
        XCTAssertEqual(increment.perModel[expensiveModel]?.cost ?? -1, 10, accuracy: 0.000001)
        XCTAssertEqual(increment.perModel[cheapModel]?.cost ?? -1, 1, accuracy: 0.000001)
        XCTAssertEqual(
            increment.perModel[UsageModelGrouping.mixedOrUnattributedKey]?.totalTokens,
            0)
        XCTAssertEqual(
            increment.perModel[UsageModelGrouping.mixedOrUnattributedKey]?.cost ?? -1,
            1,
            accuracy: 0.000001)
        XCTAssertEqual(
            increment.perModel[UsageModelGrouping.mixedOrUnattributedKey]?.activeSeconds ?? -1,
            30,
            accuracy: 0.001)
        XCTAssertEqual(increment.activityEvents.count, 1)
        XCTAssertEqual(
            increment.activityEvents.first?.key,
            UsageModelGrouping.mixedOrUnattributedKey)
    }
}

extension HermesPricingRefreshTests {
    func test_resolverRetainsReportedModelCostsWhenDerivedSessionTotalWins() throws {
        let timestamp = tokiTestISODate("2026-04-10T10:00:00Z")
        let expensiveModel = "reported-detail-expensive"
        let cheapModel = "reported-detail-cheap"
        let expensiveCounters = HermesTokenCounters(
            inputTokens: 100,
            outputTokens: 0,
            cacheReadTokens: 0,
            cacheWriteTokens: 0,
            reasoningTokens: 0)
        let cheapCounters = HermesTokenCounters(
            inputTokens: 100,
            outputTokens: 0,
            cacheReadTokens: 0,
            cacheWriteTokens: 0,
            reasoningTokens: 0)
        let sessionCounters = expensiveCounters.adding(cheapCounters)
        let session = HermesSessionObservation(
            sessionID: "derived-session-total-wins",
            startedAt: timestamp,
            earliestActivityAt: timestamp,
            latestActivityAt: timestamp,
            model: nil,
            counters: sessionCounters,
            cost: 20,
            costIsDerivedFromModelPricing: true,
            modelPricingTimestamp: timestamp,
            projectName: nil,
            attributionQuality: .exact)
        let resolved = try HermesUsageResolver.resolve(
            session: session,
            modelUsage: [
                HermesSessionModelUsage(
                    model: expensiveModel,
                    counters: expensiveCounters,
                    cost: 10,
                    costIsDerivedFromModelPricing: false,
                    modelPricingTimestamp: nil),
                HermesSessionModelUsage(
                    model: cheapModel,
                    counters: cheapCounters,
                    cost: 1,
                    costIsDerivedFromModelPricing: false,
                    modelPricingTimestamp: nil),
            ])

        let events = hermesUsageEvents(
            identifier: "derived-session-total-wins",
            timestamp: timestamp,
            observation: resolved,
            previousModelCounters: [:],
            previousReportedCost: 0,
            previousModelReportedCosts: [:],
            previousModelPricingCounters: [:],
            counters: resolved.counters,
            cost: resolved.cost,
            pricingTimestamp: timestamp)

        XCTAssertEqual(resolved.cost, 20, accuracy: 0.000001)
        XCTAssertEqual(resolved.reportedCost ?? -1, 20, accuracy: 0.000001)
        XCTAssertEqual(resolved.modelReportedCosts?[expensiveModel] ?? -1, 10, accuracy: 0.000001)
        XCTAssertEqual(resolved.modelReportedCosts?[cheapModel] ?? -1, 1, accuracy: 0.000001)
        XCTAssertEqual(events.first { $0.model == expensiveModel }?.cost ?? -1, 10, accuracy: 0.000001)
        XCTAssertEqual(events.first { $0.model == cheapModel }?.cost ?? -1, 1, accuracy: 0.000001)
        XCTAssertEqual(events.first { $0.model == nil }?.cost ?? -1, 9, accuracy: 0.000001)
    }

    func test_resolverRetainsDetailedPricingWhenReportedSessionTotalTies() throws {
        let timestamp = tokiTestISODate("2026-04-10T10:00:00Z")
        let expensiveModel = "derived-detail-expensive"
        let cheapModel = "derived-detail-cheap"
        defer { ModelPricingSupplement.install([:]) }
        ModelPricingSupplement.install([
            expensiveModel: uniformHermesModelPrice(perMillion: 10),
            cheapModel: uniformHermesModelPrice(perMillion: 1),
        ])
        let expensiveCounters = HermesTokenCounters(
            inputTokens: 1_000_000,
            outputTokens: 0,
            cacheReadTokens: 0,
            cacheWriteTokens: 0,
            reasoningTokens: 0)
        let cheapCounters = HermesTokenCounters(
            inputTokens: 1_000_000,
            outputTokens: 0,
            cacheReadTokens: 0,
            cacheWriteTokens: 0,
            reasoningTokens: 0)
        let session = HermesSessionObservation(
            sessionID: "reported-session-total-ties",
            startedAt: timestamp,
            earliestActivityAt: timestamp,
            latestActivityAt: timestamp,
            model: nil,
            counters: expensiveCounters.adding(cheapCounters),
            cost: 11,
            projectName: nil,
            attributionQuality: .exact)
        let resolved = try HermesUsageResolver.resolve(
            session: session,
            modelUsage: [
                HermesSessionModelUsage(
                    model: expensiveModel,
                    counters: expensiveCounters,
                    cost: 10,
                    costIsDerivedFromModelPricing: true,
                    modelPricingTimestamp: timestamp),
                HermesSessionModelUsage(
                    model: cheapModel,
                    counters: cheapCounters,
                    cost: 1,
                    costIsDerivedFromModelPricing: true,
                    modelPricingTimestamp: timestamp),
            ])

        let events = hermesUsageEvents(
            identifier: "reported-session-total-ties",
            timestamp: timestamp,
            observation: resolved,
            previousModelCounters: [:],
            previousReportedCost: 0,
            previousModelReportedCosts: [:],
            previousModelPricingCounters: [:],
            counters: resolved.counters,
            cost: resolved.cost,
            pricingTimestamp: timestamp)

        XCTAssertEqual(resolved.cost, 11, accuracy: 0.000001)
        XCTAssertEqual(resolved.reportedCost ?? -1, 0, accuracy: 0.000001)
        XCTAssertEqual(resolved.modelPricingCounters?.count, 2)
        XCTAssertEqual(events.first { $0.model == expensiveModel }?.cost ?? -1, 10, accuracy: 0.000001)
        XCTAssertEqual(events.first { $0.model == cheapModel }?.cost ?? -1, 1, accuracy: 0.000001)
        XCTAssertNil(events.first { $0.model == nil })
    }
}

private func uniformHermesModelPrice(perMillion: Double) -> ModelPrice {
    ModelPrice(
        inputPerMillion: perMillion,
        outputPerMillion: perMillion,
        cacheReadPerMillion: perMillion,
        cacheWritePerMillion: perMillion)
}

private func hermesEventTokenTotalsByModel(
    in events: [TokenUsageEvent]) -> [String: Int] {
    events.reduce(into: [String: Int]()) { result, event in
        guard let model = event.model else { return }
        result[model, default: 0] += event.totalTokens
    }
}

private func createHermesPricingRefreshDatabase(
    at databaseURL: URL,
    model: String) throws {
    try createHermesStateDB(
        at: databaseURL,
        rows: [
            HermesSessionFixture(
                id: "remote-priced-session",
                startedAt: "2026-04-09T08:00:00Z",
                model: model,
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
        databaseURL: databaseURL,
        rows: [
            HermesModelUsageFixture(
                sessionID: "remote-priced-session",
                model: model,
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
}

private func createMultiModelHermesPricingDatabase(
    at databaseURL: URL,
    firstModel: String,
    secondModel: String) throws {
    try createHermesStateDB(
        at: databaseURL,
        rows: [
            HermesSessionFixture(
                id: "multi-model-session",
                startedAt: "2026-04-09T08:00:00Z",
                model: nil,
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
        databaseURL: databaseURL,
        rows: [
            HermesModelUsageFixture(
                sessionID: "multi-model-session",
                model: firstModel,
                task: "approval-a",
                apiCallCount: 1,
                inputTokens: 100,
                outputTokens: 0,
                cacheReadTokens: 0,
                cacheWriteTokens: 0,
                reasoningTokens: 0,
                estimatedCost: 0,
                actualCost: 0),
            HermesModelUsageFixture(
                sessionID: "multi-model-session",
                model: secondModel,
                task: "approval-b",
                apiCallCount: 1,
                inputTokens: 100,
                outputTokens: 0,
                cacheReadTokens: 0,
                cacheWriteTokens: 0,
                reasoningTokens: 0,
                estimatedCost: 0,
                actualCost: 0),
        ])
}

private func createMixedCostHermesPricingDatabase(
    at databaseURL: URL,
    reportedModel: String,
    derivedModel: String) throws {
    try createHermesStateDB(
        at: databaseURL,
        rows: [
            HermesSessionFixture(
                id: "mixed-cost-session",
                startedAt: "2026-04-09T08:00:00Z",
                model: nil,
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
        databaseURL: databaseURL,
        rows: [
            HermesModelUsageFixture(
                sessionID: "mixed-cost-session",
                model: reportedModel,
                task: "reported",
                apiCallCount: 1,
                inputTokens: 100,
                outputTokens: 0,
                cacheReadTokens: 0,
                cacheWriteTokens: 0,
                reasoningTokens: 0,
                estimatedCost: 0,
                actualCost: 1),
            HermesModelUsageFixture(
                sessionID: "mixed-cost-session",
                model: derivedModel,
                task: "derived",
                apiCallCount: 1,
                inputTokens: 100,
                outputTokens: 0,
                cacheReadTokens: 0,
                cacheWriteTokens: 0,
                reasoningTokens: 0,
                estimatedCost: 0,
                actualCost: 0),
        ])
}

func removeHermesCostBreakdownFromBaselines(at ledgerURL: URL) throws {
    guard var document = try JSONSerialization.jsonObject(
        with: Data(contentsOf: ledgerURL)) as? [String: Any],
        var baselines = document["baselines"] as? [String: Any],
        !baselines.isEmpty else {
        throw NSError(domain: "HermesPricingRefreshTests", code: 1)
    }
    for (identifier, value) in baselines {
        guard var baseline = value as? [String: Any] else {
            throw NSError(domain: "HermesPricingRefreshTests", code: 2)
        }
        baseline.removeValue(forKey: "reportedCost")
        baseline.removeValue(forKey: "modelReportedCosts")
        baseline.removeValue(forKey: "modelPricingCounters")
        baselines[identifier] = baseline
    }
    document["baselines"] = baselines
    let data = try JSONSerialization.data(withJSONObject: document, options: [.sortedKeys])
    try writePrivateHermesTestData(data, to: ledgerURL)
}

private func persistedHermesBaseline(at ledgerURL: URL) throws -> [String: Any] {
    guard let document = try JSONSerialization.jsonObject(
        with: Data(contentsOf: ledgerURL)) as? [String: Any],
        let baselines = document["baselines"] as? [String: Any],
        let baseline = baselines.values.first as? [String: Any] else {
        throw NSError(domain: "HermesPricingRefreshTests", code: 3)
    }
    return baseline
}
