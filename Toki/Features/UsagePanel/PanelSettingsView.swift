import ServiceManagement
import SwiftUI

struct PanelSettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var settings: UsagePanelSettings

    private let readerNames: [String]
    @State private var launchAtLoginEnabled = SMAppService.mainApp.status == .enabled
    @State private var launchAtLoginIsUpdating = false
    @State private var launchAtLoginError: String?

    init(settings: UsagePanelSettings, readerNames: [String] = UsagePanelSettings.defaultReaderNames) {
        self.settings = settings
        self.readerNames = readerNames
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            divider
            VStack(spacing: 14) {
                refreshPicker
                settingsSection("Readers") {
                    ForEach(readerNames, id: \.self) { name in
                        settingsToggle(
                            name,
                            isOn: Binding(
                                get: { settings.isReaderEnabled(name) },
                                set: { settings.setReader(name, isEnabled: $0) }))
                    }
                }
                settingsSection("Display") {
                    settingsToggle(
                        "Show zero rows",
                        isOn: Binding(
                            get: { settings.showsZeroSourceRows },
                            set: { settings.setShowsZeroSourceRows($0) }))
                    launchAtLoginToggle
                    if let launchAtLoginError {
                        Text(launchAtLoginError)
                            .font(.system(size: 10, weight: .medium))
                            .foregroundColor(Color(red: 1.0, green: 0.45, blue: 0.35).opacity(0.8))
                            .padding(.horizontal, 10)
                            .padding(.bottom, 7)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
        }
        .frame(width: 280)
        .background(Color(red: 0.09, green: 0.09, blue: 0.11))
        .preferredColorScheme(.dark)
        .onAppear {
            launchAtLoginEnabled = SMAppService.mainApp.status == .enabled
        }
    }

    private var header: some View {
        HStack {
            Text("Settings")
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(.white)
            Spacer()
            Button {
                dismiss()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(Color.white.opacity(0.42))
                    .frame(width: 18, height: 18)
                    .contentShape(Rectangle())
                    .accessibilityHidden(true)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text("Close settings"))
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private var refreshPicker: some View {
        settingsSection("Refresh") {
            Picker("Refresh", selection: $settings.refreshIntervalSeconds) {
                ForEach(UsagePanelSettings.refreshIntervalChoices, id: \.self) { seconds in
                    Text(refreshTitle(for: seconds)).tag(seconds)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
        }
    }

    private var launchAtLoginToggle: some View {
        settingsToggle(
            "Launch at Login",
            isOn: Binding(
                get: { launchAtLoginEnabled },
                set: { setLaunchAtLogin($0) }))
            .disabled(launchAtLoginIsUpdating)
            .opacity(launchAtLoginIsUpdating ? 0.5 : 1)
    }

    private var divider: some View {
        Rectangle()
            .fill(Color.white.opacity(0.07))
            .frame(height: 0.5)
    }

    private func settingsSection(
        _ title: String,
        @ViewBuilder content: () -> some View)
        -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title.uppercased())
                .font(.system(size: 10, weight: .semibold))
                .foregroundColor(Color.white.opacity(0.28))
            VStack(spacing: 0) {
                content()
            }
            .background(Color.white.opacity(0.04))
            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        }
    }

    private func settingsToggle(_ title: String, isOn: Binding<Bool>) -> some View {
        Toggle(isOn: isOn) {
            Text(title)
                .font(.system(size: 12))
                .foregroundColor(Color.white.opacity(0.74))
        }
        .toggleStyle(.switch)
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
    }

    private func refreshTitle(for seconds: Int) -> String {
        if seconds < 60 {
            return "\(seconds)s"
        }
        return "\(seconds / 60)m"
    }

    private func setLaunchAtLogin(_ isEnabled: Bool) {
        guard launchAtLoginEnabled != isEnabled, !launchAtLoginIsUpdating else { return }
        launchAtLoginIsUpdating = true
        launchAtLoginError = nil

        Task {
            let result = await Task.detached(priority: .userInitiated) {
                do {
                    if isEnabled {
                        try SMAppService.mainApp.register()
                    } else {
                        try SMAppService.mainApp.unregister()
                    }
                    return Result<Void, Error>.success(())
                } catch {
                    return .failure(error)
                }
            }.value

            if case let .failure(error) = result {
                launchAtLoginError = error.localizedDescription
                NSLog("Launch at Login update failed: \(error.localizedDescription)")
            }
            launchAtLoginEnabled = SMAppService.mainApp.status == .enabled
            launchAtLoginIsUpdating = false
        }
    }
}
