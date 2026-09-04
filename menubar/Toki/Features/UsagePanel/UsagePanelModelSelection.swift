import Foundation

extension UsagePanelViewModel {
    var usageData: UsageData {
        guard case let .model(modelID) = selectedModelScope else {
            return baseUsageData
        }
        return modelScopedUsageData(
            modelID: modelID,
            modelReports: baseModelReports,
            fallback: baseUsageData)
    }

    var availableModelReports: [UsageModelReport] {
        baseModelReports.values.sorted(by: modelReportSort)
    }

    var modelCatalogUsageData: UsageData {
        baseUsageData
    }

    var selectedModelID: String? {
        selectedModelScope.modelID
    }

    var selectedModelTitle: String? {
        selectedModelID.map(panelModelDisplayName)
    }

    var currentScopeTitle: String {
        guard let selectedModelTitle else { return usageScopeTitle }
        return "\(usageScopeTitle) · \(selectedModelTitle)"
    }

    var isModelFilterActive: Bool {
        selectedModelID != nil
    }

    private var baseUsageData: UsageData {
        switch selectedUsageScope {
        case .all:
            selectedPresentationUsageResult.usageData
        case let .origin(originID):
            selectedPresentationUsageResult.originReports.first { $0.id == originID }?.usageData
                ?? selectedPresentationUsageResult.usageData
        }
    }

    private var baseModelReports: [String: UsageModelReport] {
        switch selectedUsageScope {
        case .all:
            selectedPresentationUsageResult.modelReports
        case let .origin(originID):
            selectedPresentationUsageResult.originReports.first { $0.id == originID }?.modelReports
                ?? selectedPresentationUsageResult.modelReports
        }
    }

    var originReports: [UsageOriginReport] {
        guard case let .model(modelID) = selectedModelScope else {
            return selectedPresentationUsageResult.originReports
        }
        return selectedPresentationUsageResult.originReports.map { report in
            UsageOriginReport(
                origin: report.origin,
                usageData: modelScopedUsageData(
                    modelID: modelID,
                    modelReports: report.modelReports,
                    fallback: report.usageData),
                modelReports: report.modelReports)
        }
    }

    var selectedUsageOrigin: UsageOrigin? {
        guard case let .origin(originID) = selectedUsageScope else { return nil }
        return selectedPresentationUsageResult.originReports.first { $0.id == originID }?.origin
    }

    var usageScopeTitle: String {
        selectedUsageOrigin?.name ?? "All Devices"
    }

    var isLoading: Bool {
        presentationSnapshot.isLoading
    }

    var isRefreshing: Bool {
        presentationSnapshot.isRefreshing
    }

    var lastFetchedAt: Date? {
        selectedPresentationFetchedAt
    }

    var yesterdayTotalTokens: Int? {
        presentationSnapshot.yesterdayTotalTokens
    }

    var failedReaderNames: [String] {
        panelReaderFailureNames(readerStatuses, for: selectedUsageScope)
    }

    var readerStatuses: [ReaderStatus] {
        presentationSnapshot.readerStatuses
    }

    var periodTokenTotals: [TokenTotalSummary] {
        presentationSnapshot.periodTokenTotals
    }

    var isLoadingPeriodTokenTotals: Bool {
        presentationSnapshot.isLoadingPeriodTokenTotals
    }
}

private func modelReportSort(_ lhs: UsageModelReport, _ rhs: UsageModelReport) -> Bool {
    if lhs.summary.activeSeconds != rhs.summary.activeSeconds {
        return lhs.summary.activeSeconds > rhs.summary.activeSeconds
    }
    if lhs.summary.totalTokens != rhs.summary.totalTokens {
        return lhs.summary.totalTokens > rhs.summary.totalTokens
    }
    if lhs.summary.cost != rhs.summary.cost {
        return lhs.summary.cost > rhs.summary.cost
    }
    return lhs.summary.displayModelID < rhs.summary.displayModelID
}

private func modelScopedUsageData(
    modelID: String,
    modelReports: [String: UsageModelReport],
    fallback: UsageData) -> UsageData {
    modelReports[modelID]?.usageData
        ?? UsageData(
            date: fallback.date,
            endDate: fallback.endDate,
            inputTokens: 0,
            outputTokens: 0,
            cacheReadTokens: 0,
            cacheWriteTokens: 0,
            reasoningTokens: 0,
            cost: 0,
            activeSeconds: 0,
            perModel: [],
            filteredModelID: modelID)
}
