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
