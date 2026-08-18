import Foundation
import SwiftUI

enum PanelModelTokenKind: String, Identifiable {
    case input
    case output
    case cacheRead
    case cacheWrite
    case reasoning
    case unclassified

    var id: String {
        rawValue
    }

    var title: String {
        switch self {
        case .input:
            "Input"
        case .output:
            "Output"
        case .cacheRead:
            "Cache read"
        case .cacheWrite:
            "Cache write"
        case .reasoning:
            "Reasoning"
        case .unclassified:
            "Unclassified"
        }
    }
}

struct PanelModelTokenComponent: Identifiable, Equatable {
    let kind: PanelModelTokenKind
    let tokens: Int

    var id: PanelModelTokenKind {
        kind
    }
}

enum PanelModelHourlyAvailability: Equatable {
    /// Hourly bucketing ran for this range, so an empty bucket list means no recorded activity.
    case available
    /// The range needs more hourly buckets than the report builder produces.
    case unsupportedRange
}

struct PanelModelDetailPresentation: Identifiable, Equatable {
    let modelID: String
    let scopeTitle: String
    let startDate: Date
    let endDate: Date
    let report: UsageModelReport?
    let contextOnlyStats: [ContextOnlyModelStat]
    let projects: [ProjectUsageStat]
    let sources: [SourceStat]
    let sessions: [SessionUsageStat]
    let activeBuckets: [UsageTimeBucket]
    let hourlyAvailability: PanelModelHourlyAvailability
    let tokenComponents: [PanelModelTokenComponent]

    var id: String {
        modelID
    }

    var isContextOnly: Bool {
        report == nil
    }

    /// Last instant included by the report's half-open `[startDate, endDate)` range,
    /// so date formatting does not display the exclusive upper bound as an included day.
    var displayEndDate: Date {
        panelModelDetailDisplayEndDate(startDate: startDate, endDate: endDate)
    }

    var hasIncompleteAttribution: Bool {
        report?.usageData.isModelAttributionComplete == false
    }
}

/// Converts an exclusive range upper bound into the last instant the range includes.
///
/// Usage requests model ranges as `[startDate, endDate)`, so a single-day selection ends at the
/// following midnight. Formatting that bound directly reports one extra calendar day.
func panelModelDetailDisplayEndDate(startDate: Date, endDate: Date) -> Date {
    guard endDate > startDate else { return startDate }
    return max(startDate, endDate.addingTimeInterval(-1))
}

func panelModelDetailPresentation(
    modelID: String,
    scopeTitle: String,
    fallbackStartDate: Date,
    fallbackEndDate: Date,
    modelReports: [UsageModelReport],
    contextOnlyModels: [ContextOnlyModelStat]) -> PanelModelDetailPresentation? {
    let report = modelReports.first { $0.modelID == modelID }
    let matchingContextStats = contextOnlyModels.filter { $0.model == modelID }
    guard report != nil || !matchingContextStats.isEmpty else { return nil }

    let usage = report?.usageData
    return PanelModelDetailPresentation(
        modelID: modelID,
        scopeTitle: scopeTitle,
        startDate: usage?.date ?? fallbackStartDate,
        endDate: usage?.endDate ?? fallbackEndDate,
        report: report,
        contextOnlyStats: matchingContextStats
            .filter { $0.contextTokens > 0 }
            .sorted(by: panelContextOnlyDetailSort),
        projects: (usage?.projectStats ?? [])
            .filter { $0.totalTokens > 0 || $0.cost > 0 || $0.sessionCount > 0 }
            .sorted(by: panelProjectDetailSort),
        sources: (usage?.sourceStats ?? [])
            .filter { $0.totalTokens > 0 || $0.cost > 0 || $0.reportedSeconds > 0 }
            .sorted(by: panelSourceDetailSort),
        sessions: (usage?.sessionStats ?? [])
            .filter { $0.totalTokens > 0 || $0.cost > 0 }
            .sorted(by: panelSessionDetailSort),
        activeBuckets: (usage?.timeBuckets ?? [])
            .filter { $0.totalTokens > 0 || $0.cost > 0 }
            .sorted(by: panelTimeBucketDetailSort),
        hourlyAvailability: UsageReportBuilder.supportsHourlyBuckets(
            from: usage?.date ?? fallbackStartDate,
            to: usage?.endDate ?? fallbackEndDate)
            ? .available
            : .unsupportedRange,
        tokenComponents: panelModelTokenComponents(from: usage))
}

private func panelProjectDetailSort(_ lhs: ProjectUsageStat, _ rhs: ProjectUsageStat) -> Bool {
    if lhs.totalTokens != rhs.totalTokens {
        return lhs.totalTokens > rhs.totalTokens
    }
    if lhs.cost != rhs.cost {
        return lhs.cost > rhs.cost
    }
    if lhs.name != rhs.name {
        return lhs.name < rhs.name
    }
    return lhs.id < rhs.id
}

private func panelSourceDetailSort(_ lhs: SourceStat, _ rhs: SourceStat) -> Bool {
    if lhs.totalTokens != rhs.totalTokens {
        return lhs.totalTokens > rhs.totalTokens
    }
    if lhs.cost != rhs.cost {
        return lhs.cost > rhs.cost
    }
    return lhs.source < rhs.source
}

private func panelSessionDetailSort(_ lhs: SessionUsageStat, _ rhs: SessionUsageStat) -> Bool {
    if lhs.lastActivityAt != rhs.lastActivityAt {
        return lhs.lastActivityAt > rhs.lastActivityAt
    }
    if lhs.firstActivityAt != rhs.firstActivityAt {
        return lhs.firstActivityAt > rhs.firstActivityAt
    }
    return lhs.id < rhs.id
}

private func panelTimeBucketDetailSort(_ lhs: UsageTimeBucket, _ rhs: UsageTimeBucket) -> Bool {
    if lhs.totalTokens != rhs.totalTokens {
        return lhs.totalTokens > rhs.totalTokens
    }
    if lhs.cost != rhs.cost {
        return lhs.cost > rhs.cost
    }
    return lhs.startDate < rhs.startDate
}

private func panelContextOnlyDetailSort(
    _ lhs: ContextOnlyModelStat,
    _ rhs: ContextOnlyModelStat) -> Bool {
    if lhs.contextTokens != rhs.contextTokens {
        return lhs.contextTokens > rhs.contextTokens
    }
    if lhs.source != rhs.source {
        return lhs.source < rhs.source
    }
    return lhs.id < rhs.id
}

private func panelModelTokenComponents(from usage: UsageData?) -> [PanelModelTokenComponent] {
    guard let usage else { return [] }
    return [
        PanelModelTokenComponent(kind: .input, tokens: usage.inputTokens),
        PanelModelTokenComponent(kind: .output, tokens: usage.outputTokens),
        PanelModelTokenComponent(kind: .cacheRead, tokens: usage.cacheReadTokens),
        PanelModelTokenComponent(kind: .cacheWrite, tokens: usage.cacheWriteTokens),
        PanelModelTokenComponent(kind: .reasoning, tokens: usage.reasoningTokens),
        PanelModelTokenComponent(kind: .unclassified, tokens: usage.unclassifiedTokens),
    ]
    .filter { $0.tokens > 0 }
}
