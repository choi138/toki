import Foundation
import TokiUsageCore

#if os(Linux)
    import CSQLite
#else
    import SQLite3
#endif

struct HermesSessionUsageRow {
    let sessionID: String
    let startedAt: Date
    let earliestActivityAt: Date?
    let latestActivityAt: Date?
    let model: String?
    let inputTokens: Int
    let outputTokens: Int
    let cacheReadTokens: Int
    let cacheWriteTokens: Int
    let reasoningTokens: Int
    let cost: Double
    let costIsDerivedFromModelPricing: Bool
    let modelPricingTimestamp: Date?
    let projectName: String?
    let attributionQuality: AttributionQuality

    init(statement: OpaquePointer) {
        sessionID = hermesSQLiteText(statement, at: 0).nilIfBlank ?? "hermes"
        startedAt = Date(timeIntervalSince1970: sqlite3_column_double(statement, 1))
        model = normalizedModelID(hermesSQLiteText(statement, at: 2))
        let cwd = hermesSQLiteText(statement, at: 3).nilIfBlank
        let gitRepoRoot = hermesSQLiteText(statement, at: 4).nilIfBlank
        inputTokens = max(0, Int(sqlite3_column_int64(statement, 5)))
        outputTokens = max(0, Int(sqlite3_column_int64(statement, 6)))
        cacheReadTokens = max(0, Int(sqlite3_column_int64(statement, 7)))
        cacheWriteTokens = max(0, Int(sqlite3_column_int64(statement, 8)))
        reasoningTokens = max(0, Int(sqlite3_column_int64(statement, 9)))

        let estimatedCost = max(0, sqlite3_column_double(statement, 10))
        let actualCost = max(0, sqlite3_column_double(statement, 11))
        let resolvedCost = hermesUsageCost(
            model: model,
            counters: HermesTokenCounters(
                inputTokens: inputTokens,
                outputTokens: outputTokens,
                cacheReadTokens: cacheReadTokens,
                cacheWriteTokens: cacheWriteTokens,
                reasoningTokens: reasoningTokens),
            estimatedCost: estimatedCost,
            actualCost: actualCost,
            timestamp: startedAt)
        cost = resolvedCost.value
        costIsDerivedFromModelPricing = resolvedCost.isDerivedFromModelPricing
        modelPricingTimestamp = resolvedCost.modelPricingTimestamp

        if sqlite3_column_type(statement, 12) == SQLITE_NULL {
            earliestActivityAt = nil
        } else {
            earliestActivityAt = Date(timeIntervalSince1970: sqlite3_column_double(statement, 12))
        }
        if sqlite3_column_type(statement, 13) == SQLITE_NULL {
            latestActivityAt = nil
        } else {
            latestActivityAt = Date(timeIntervalSince1970: sqlite3_column_double(statement, 13))
        }
        let attribution = UsageAttribution(
            projectPath: cwd ?? gitRepoRoot,
            quality: cwd == nil && gitRepoRoot != nil ? .inferred : .exact)
        projectName = attribution.projectName
        attributionQuality = attribution.quality
    }

    var observation: HermesSessionObservation {
        HermesSessionObservation(
            sessionID: sessionID,
            startedAt: startedAt,
            earliestActivityAt: earliestActivityAt,
            latestActivityAt: latestActivityAt,
            model: model,
            counters: HermesTokenCounters(
                inputTokens: inputTokens,
                outputTokens: outputTokens,
                cacheReadTokens: cacheReadTokens,
                cacheWriteTokens: cacheWriteTokens,
                reasoningTokens: reasoningTokens),
            cost: cost,
            costIsDerivedFromModelPricing: costIsDerivedFromModelPricing,
            modelPricingTimestamp: modelPricingTimestamp,
            projectName: projectName,
            attributionQuality: attributionQuality)
    }
}

func hermesSQLiteText(_ statement: OpaquePointer?, at index: Int32) -> String {
    sqlite3_column_text(statement, index).map { String(cString: $0) } ?? ""
}

private extension String {
    var nilIfBlank: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
