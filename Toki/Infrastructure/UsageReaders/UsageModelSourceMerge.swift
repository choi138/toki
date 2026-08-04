import Foundation
import TokiUsageCore

/// Maps each origin's model usage onto `(model, source)` keys so the panel can show one
/// row per model and source. Remote origins are routed through the report builder first
/// because their source labels carry the device name.
func mergedModelSourceUsage(
    from slices: [UsageOriginSlice],
    startDate: Date,
    endDate: Date) -> [ModelSourceUsageKey: PerModelUsage] {
    var result: [ModelSourceUsageKey: PerModelUsage] = [:]

    for slice in slices {
        if slice.origin.kind == .remote {
            mergeRemoteModelUsage(
                slice.usage,
                source: fallbackSource(for: slice),
                startDate: startDate,
                endDate: endDate,
                into: &result)
            continue
        }

        var explicitlyMappedModels = Set<String>()
        for (key, usage) in slice.usage.perModelBySource {
            guard let modelID = key.modelID.trimmedNonEmpty,
                  let source = key.source.trimmedNonEmpty else {
                continue
            }
            explicitlyMappedModels.insert(modelID)
            accumulateModelUsage(
                usage,
                key: ModelSourceUsageKey(modelID: modelID, source: source),
                into: &result)
        }
        mergeLegacyPerModelUsage(
            slice.usage.perModel,
            source: fallbackSource(for: slice),
            excluding: explicitlyMappedModels,
            into: &result)
    }
    return result
}

private func mergeRemoteModelUsage(
    _ usage: RawTokenUsage,
    source fallbackSource: String,
    startDate: Date,
    endDate: Date,
    into result: inout [ModelSourceUsageKey: PerModelUsage]) {
    guard let fallbackSource = fallbackSource.trimmedNonEmpty else { return }

    for model in UsageReportBuilder.buildModelStats(
        from: usage,
        startDate: startDate,
        endDate: endDate) {
        guard let modelID = model.modelID.trimmedNonEmpty else { continue }
        let sources = Set(model.sources.compactMap(\.trimmedNonEmpty))
        let source = sources.count == 1
            ? sources.first ?? fallbackSource
            : fallbackSource
        accumulateModelUsage(
            PerModelUsage(
                totalTokens: model.totalTokens,
                cost: model.cost,
                activeSeconds: model.activeSeconds,
                wallClockSeconds: model.wallClockSeconds,
                sources: sources),
            key: ModelSourceUsageKey(modelID: modelID, source: source),
            into: &result)
    }
}

private func mergeLegacyPerModelUsage(
    _ modelUsage: [String: PerModelUsage],
    source fallbackSource: String,
    excluding sourceMappedModels: Set<String>,
    into result: inout [ModelSourceUsageKey: PerModelUsage]) {
    guard let fallbackSource = fallbackSource.trimmedNonEmpty else { return }

    for (rawModelID, usage) in modelUsage {
        guard let modelID = rawModelID.trimmedNonEmpty,
              !sourceMappedModels.contains(modelID) else {
            continue
        }
        let usageSources = Set(usage.sources.compactMap(\.trimmedNonEmpty))
        let source = usageSources.count == 1
            ? usageSources.first ?? fallbackSource
            : fallbackSource
        accumulateModelUsage(
            usage,
            key: ModelSourceUsageKey(modelID: modelID, source: source),
            into: &result)
    }
}

private func accumulateModelUsage(
    _ usage: PerModelUsage,
    key: ModelSourceUsageKey,
    into result: inout [ModelSourceUsageKey: PerModelUsage]) {
    var entry = result[key] ?? PerModelUsage()
    entry.totalTokens += usage.totalTokens
    entry.cost += usage.cost
    entry.activeSeconds += usage.activeSeconds
    entry.wallClockSeconds += usage.wallClockSeconds
    let usageSources = Set(usage.sources.compactMap(\.trimmedNonEmpty))
    if usageSources.isEmpty {
        entry.sources.insert(key.source)
    } else {
        entry.sources.formUnion(usageSources)
    }
    result[key] = entry
}
