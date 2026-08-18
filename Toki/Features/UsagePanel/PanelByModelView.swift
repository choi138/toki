import SwiftUI

private let skeletonRowWidths: [CGFloat] = [88, 72, 96, 64, 80]

func panelModelTokenShare(modelTokens: Int, reportTotalTokens: Int) -> Double {
    guard modelTokens > 0, reportTotalTokens > 0 else { return 0 }
    return min(1, Double(modelTokens) / Double(reportTotalTokens))
}

struct PanelModelOption: Identifiable, Equatable {
    let id: String
    let isContextOnly: Bool
}

func panelModelOptions(
    modelReports: [UsageModelReport],
    contextOnlyModels: [ContextOnlyModelStat]) -> [PanelModelOption] {
    var seenModelIDs = Set<String>()
    var options = modelReports.compactMap { report -> PanelModelOption? in
        guard seenModelIDs.insert(report.modelID).inserted else { return nil }
        return PanelModelOption(id: report.modelID, isContextOnly: false)
    }

    options.append(contentsOf: contextOnlyModels.compactMap { stat -> PanelModelOption? in
        guard seenModelIDs.insert(stat.model).inserted else { return nil }
        return PanelModelOption(id: stat.model, isContextOnly: true)
    })
    return options
}

func panelFilteredModelReports(
    _ reports: [UsageModelReport],
    selectedModelID: String?) -> [UsageModelReport] {
    guard let selectedModelID else { return reports }
    return reports.filter { $0.modelID == selectedModelID }
}

func panelFilteredContextOnlyModels(
    _ models: [ContextOnlyModelStat],
    selectedModelID: String?) -> [ContextOnlyModelStat] {
    guard let selectedModelID else { return models }
    return models.filter { $0.model == selectedModelID }
}

func panelModelSelectionIsUnavailable(
    selectedModelID: String?,
    options: [PanelModelOption]) -> Bool {
    guard let selectedModelID else { return false }
    return !options.contains { $0.id == selectedModelID }
}

struct PanelByModelView: View {
    let usage: UsageData
    let modelReports: [UsageModelReport]
    @Binding var selectedModelID: String?
    let scopeTitle: String
    let isLoading: Bool
    @State private var presentedModelID: String?

    var body: some View {
        VStack(spacing: 0) {
            PanelModelPickerView(
                options: modelOptions,
                selectedModelID: $selectedModelID,
                isSelectionUnavailable: selectedModelIsUnavailable)
            panelDivider

            if isLoading, modelOptions.isEmpty {
                VStack(spacing: 0) {
                    ForEach(Array(skeletonRowWidths.enumerated()), id: \.offset) { _, width in
                        skeletonModelRow(labelWidth: width)
                    }
                }
                .padding(.vertical, 6)
            } else if selectedModelIsUnavailable {
                unavailableSelectionNotice
            } else if filteredModelReports.isEmpty, filteredContextOnlyModels.isEmpty {
                Text("No model-attributed usage")
                    .font(.system(size: 12))
                    .foregroundColor(Color.white.opacity(0.3))
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, 24)
            } else {
                VStack(spacing: 0) {
                    if !filteredModelReports.isEmpty {
                        PanelSectionCaption(title: "Model Usage")

                        ForEach(filteredModelReports, id: \.modelID) { report in
                            Button {
                                presentModelDetail(modelID: report.modelID)
                            } label: {
                                ModelStatRowView(
                                    stat: report.summary,
                                    share: tokenShare(for: report.summary),
                                    disclosesDetails: true)
                                    .equatable()
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(PanelModelDetailRowButtonStyle())
                            .accessibilityLabel(Text(modelDetailAccessibilityLabel(for: report)))
                            .accessibilityHint(Text("Show where this model was used"))
                        }
                    }

                    if !filteredContextOnlyModels.isEmpty {
                        PanelSectionCaption(title: "Context Only")

                        ForEach(filteredContextOnlyModels, id: \.id) { stat in
                            Button {
                                presentModelDetail(modelID: stat.model)
                            } label: {
                                ContextOnlyModelStatRowView(
                                    stat: stat,
                                    disclosesDetails: true)
                                    .equatable()
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(PanelModelDetailRowButtonStyle())
                            .accessibilityLabel(Text(contextDetailAccessibilityLabel(for: stat)))
                            .accessibilityHint(Text("Show this model's context-only details"))
                        }

                        Text("Excluded from Total Tokens. Cursor stores context-window size for these rows.")
                            .font(.system(size: 10))
                            .foregroundColor(Color.white.opacity(0.28))
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(.horizontal, 16)
                            .padding(.top, 6)
                            .padding(.bottom, 8)
                    }
                }
                .padding(.vertical, 6)
            }
        }
        .sheet(item: presentedModelDetailBinding) { presentation in
            PanelModelDetailView(presentation: presentation)
        }
    }

    private var modelOptions: [PanelModelOption] {
        panelModelOptions(
            modelReports: modelReports,
            contextOnlyModels: usage.contextOnlyModels)
    }

    private var filteredModelReports: [UsageModelReport] {
        panelFilteredModelReports(modelReports, selectedModelID: selectedModelID)
    }

    private var filteredContextOnlyModels: [ContextOnlyModelStat] {
        panelFilteredContextOnlyModels(usage.contextOnlyModels, selectedModelID: selectedModelID)
    }

    private func tokenShare(for stat: ModelStat) -> Double {
        panelModelTokenShare(
            modelTokens: stat.totalTokens,
            reportTotalTokens: usage.totalTokens)
    }

    private var selectedModelIsUnavailable: Bool {
        panelModelSelectionIsUnavailable(
            selectedModelID: selectedModelID,
            options: modelOptions)
    }

    /// Derives the presented detail from the latest inputs on every update so a refresh cannot
    /// leave an open sheet showing obsolete totals, and dismisses it once the model leaves scope.
    private var presentedModelDetail: PanelModelDetailPresentation? {
        presentedModelID.flatMap { modelID in
            panelModelDetailPresentation(
                modelID: modelID,
                scopeTitle: scopeTitle,
                fallbackStartDate: usage.date,
                fallbackEndDate: usage.endDate,
                modelReports: modelReports,
                contextOnlyModels: usage.contextOnlyModels)
        }
    }

    private var presentedModelDetailBinding: Binding<PanelModelDetailPresentation?> {
        Binding(
            get: { presentedModelDetail },
            set: { presentation in
                if presentation == nil {
                    presentedModelID = nil
                }
            })
    }

    private func presentModelDetail(modelID: String) {
        presentedModelID = modelID
    }

    private func modelDetailAccessibilityLabel(for report: UsageModelReport) -> String {
        "\(panelModelDisplayName(report.modelID)), "
            + "\(report.summary.totalTokens) tokens, \(report.summary.panelCostSummary)"
    }

    private func contextDetailAccessibilityLabel(for stat: ContextOnlyModelStat) -> String {
        "\(panelModelDisplayName(stat.model)), \(stat.source), "
            + "\(stat.contextTokens) context tokens, excluded from totals"
    }

    private var unavailableSelectionNotice: some View {
        HStack(spacing: 7) {
            Image(systemName: "exclamationmark.circle")
                .font(.system(size: 10, weight: .semibold))
                .foregroundColor(Color.white.opacity(0.36))
            Text("No \(panelModelDisplayName(selectedModelID ?? "")) usage for \(scopeTitle) in this period.")
                .font(.system(size: 10, weight: .medium))
                .foregroundColor(Color.white.opacity(0.42))
                .fixedSize(horizontal: false, vertical: true)
                .layoutPriority(1)
            Spacer(minLength: 4)
            Button("Show All") {
                selectedModelID = nil
            }
            .buttonStyle(.plain)
            .font(.system(size: 10, weight: .semibold))
            .foregroundColor(Color.white.opacity(0.68))
            .accessibilityLabel(Text("Show all models"))
            .accessibilityHint(Text("Clear the unavailable model selection"))
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 7)
        .background(Color.white.opacity(0.035))
    }

    private var panelDivider: some View {
        Rectangle()
            .fill(Color.white.opacity(0.07))
            .frame(height: 0.5)
    }

    private func skeletonModelRow(labelWidth: CGFloat) -> some View {
        HStack(alignment: .center, spacing: 6) {
            Circle()
                .fill(Color.white.opacity(0.08))
                .frame(width: 5, height: 5)
            VStack(alignment: .leading, spacing: 4) {
                SkeletonBar(width: labelWidth, height: 10)
                SkeletonBar(width: max(52, labelWidth - 16), height: 8)
            }
            Spacer()
            SkeletonBar(width: 36, height: 10)
            SkeletonBar(width: 32, height: 10)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 7)
    }
}

private struct PanelModelDetailRowButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .frame(maxWidth: .infinity)
            .background(Color.white.opacity(configuration.isPressed ? 0.045 : 0))
    }
}

private struct PanelModelPickerView: View {
    let options: [PanelModelOption]
    @Binding var selectedModelID: String?
    let isSelectionUnavailable: Bool

    var body: some View {
        HStack(spacing: 8) {
            Text("MODEL")
                .font(.system(size: 9, weight: .semibold))
                .foregroundColor(Color.white.opacity(0.24))
                .tracking(1.2)
            Spacer(minLength: 8)
            Menu {
                modelButton(title: "All Models", modelID: nil)
                Divider()

                if isSelectionUnavailable, let selectedModelID {
                    Button {} label: {
                        Label(
                            "\(panelModelDisplayName(selectedModelID)) (Unavailable)",
                            systemImage: "exclamationmark.circle")
                    }
                    .disabled(true)
                    Divider()
                }

                if options.isEmpty {
                    Button("No models in this scope") {}
                        .disabled(true)
                } else {
                    ForEach(options) { option in
                        modelButton(
                            title: menuTitle(for: option),
                            modelID: option.id)
                    }
                }
            } label: {
                HStack(spacing: 6) {
                    if let selectedModelID {
                        Circle()
                            .fill(panelAccentColor(forModelID: selectedModelID).opacity(0.72))
                            .frame(width: 6, height: 6)
                    } else {
                        Image(systemName: "square.stack.3d.up")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundColor(Color.white.opacity(0.45))
                    }
                    Text(selectedTitle)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(Color.white.opacity(0.78))
                        .lineLimit(1)
                    Image(systemName: "chevron.down")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundColor(Color.white.opacity(0.3))
                }
                .padding(.horizontal, 9)
                .padding(.vertical, 5)
                .background(Color.white.opacity(0.06))
                .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
            }
            .menuStyle(.borderlessButton)
            .frame(maxWidth: 200, alignment: .trailing)
            .help(selectedModelID.map {
                panelModelRawIdentifier($0) ?? panelModelDisplayName($0)
            } ?? "Show all models")
            .accessibilityLabel(Text("Models shown"))
            .accessibilityValue(Text(selectedTitle))
            .accessibilityHint(Text("Choose which model to show in the Models tab"))
        }
        .padding(.horizontal, 16)
        .frame(height: 34)
    }

    private var selectedTitle: String {
        guard let selectedModelID else { return "All Models" }
        return panelModelDisplayName(selectedModelID)
    }

    private func menuTitle(for option: PanelModelOption) -> String {
        let title = panelModelDisplayName(option.id)
        return option.isContextOnly ? "\(title) · Context only" : title
    }

    private func modelButton(title: String, modelID: String?) -> some View {
        Button {
            selectedModelID = modelID
        } label: {
            HStack {
                Text(title)
                if selectedModelID == modelID {
                    Image(systemName: "checkmark")
                }
            }
        }
    }
}
